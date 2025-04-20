#!/bin/bash

set -euo pipefail

einfo() {
    echo "[INFO] $*"
}

# Install dependencies (optional, remove if already installed)
apt-get update
apt-get install -y debootstrap qemu-utils parted e2fsprogs dosfstools grub-pc-bin grub-common

IMAGE_FILE="debian.img"
IMAGE_SIZE="2G"
MOUNT_DIR="/mnt/debian"
DEBIAN_VERSION="bookworm"
MIRROR="http://deb.debian.org/debian"

# Step 1: Create image
einfo "Creating raw image"
qemu-img create "$IMAGE_FILE" "$IMAGE_SIZE"

# Step 2: Partition image
einfo "Partitioning image"
parted --script "$IMAGE_FILE" mklabel msdos
parted --script "$IMAGE_FILE" mkpart primary ext4 1MiB 100%

# Step 3: Setup loop device
LOOP_DEV=$(losetup --find --show --partscan "$IMAGE_FILE")
PART_DEV="${LOOP_DEV}p1"

# Wait for partition to be ready
sleep 2

# Step 4: Format partition
einfo "Formatting $PART_DEV"
mkfs.ext4 "$PART_DEV"

# Step 5: Mount the partition
mkdir -p "$MOUNT_DIR"
mount "$PART_DEV" "$MOUNT_DIR"

# Step 6: Bootstrap minimal Debian
einfo "Bootstrapping Debian ($DEBIAN_VERSION)"
debootstrap --arch amd64 "$DEBIAN_VERSION" "$MOUNT_DIR" "$MIRROR"

# Step 7: Basic config
echo "debianvm" > "$MOUNT_DIR/etc/hostname"
echo "root:root" | chroot "$MOUNT_DIR" chpasswd
echo "ttyS0" >> "$MOUNT_DIR/etc/securetty"

# Step 8: Prepare for chroot
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /sys "$MOUNT_DIR/sys"
mount --bind /proc "$MOUNT_DIR/proc"

# Step 9: Install kernel and GRUB
einfo "Installing kernel and GRUB"
chroot "$MOUNT_DIR" apt-get update
chroot "$MOUNT_DIR" apt-get install -y linux-image-amd64 grub-pc

# Install GRUB to loop device
einfo "Installing GRUB to $LOOP_DEV"
chroot "$MOUNT_DIR" grub-install --target=i386-pc --recheck "$LOOP_DEV"
chroot "$MOUNT_DIR" update-grub

# Step 10: Cleanup
umount "$MOUNT_DIR/dev" "$MOUNT_DIR/sys" "$MOUNT_DIR/proc"
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"

# Step 11: Boot the image
einfo "Booting image with QEMU"
qemu-system-x86_64 \
    -drive file="$IMAGE_FILE",format=raw,if=virtio \
    -nographic -serial mon:stdio \
    -m 512 \
    -enable-kvm
