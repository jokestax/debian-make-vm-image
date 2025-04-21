#!/bin/bash

set -euo pipefail

einfo() {
    echo "[INFO] $*"
}

export K3S_IMAGE_NAME=1.31.6+k3s1

export K3S_BINARY_NAME=v$(echo $K3S_IMAGE_NAME | sed 's/-/+/g')

export K3S_IMAGE_URL=https://github.com/k3s-io/k3s/releases/download/${K3S_BINARY_NAME}/k3s

# Install dependencies (optional, remove if already installed)

apt-get update

apt-get install -y debootstrap qemu-system-x86 qemu-utils parted e2fsprogs dosfstools grub-pc-bin grub-common udev


IMAGE_FILE="debian.img"

IMAGE_SIZE="6G"

MOUNT_DIR="/mnt/debian"

DEBIAN_VERSION="bookworm"

MIRROR="http://deb.debian.org/debian"

mkdir workdir
cd workdir

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

ROOT_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p1")

echo "UUID=$ROOT_UUID / ext4 defaults 0 1" > "$MOUNT_DIR/etc/fstab"

cat > "$MOUNT_DIR/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet dhcp
EOF

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

echo "deb http://deb.debian.org/debian stable main contrib non-free non-free-firmware" > "$MOUNT_DIR/etc/apt/sources.list"

chroot "$MOUNT_DIR" apt-get update

chroot "$MOUNT_DIR" /bin/bash <<OUTER
    # Ensure essential environment variables are set
    if [[ -z "${K3S_IMAGE_NAME}" ]]; then
    echo "k3s image variable not set"
    exit 1
    fi

    if [[ -z "${K3S_IMAGE_URL}" ]]; then
    echo "k3s url variable not set"
    exit 1
    fi

    # Update system and install core packages
    apt-get update
    apt-get install -y \
        bash \
        cloud-init \
        curl \
        htop \
        sudo \
        wget \
        nfs-common \
        open-iscsi \
        linux-headers-generic \
        conntrack \
        dbus \
        iptables \
        logrotate \
        tar \
        vim \
        udev \
        e2fsprogs \
        xfsprogs \
        util-linux \
        isc-dhcp-client \
        openssh-server \
        openssh-client \
        chrony \
        cgroup-tools \
        gnupg \
        ca-certificates \
        systemd

    # Enable dbus and udev services
    # systemctl start dbus
    # systemctl start udev
    mkdir -p /opt/cni/bin
    curl -L "https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-amd64-v1.5.1.tgz" | tar -C /opt/cni/bin -xz

    cat > /etc/logrotate.d/k3s <<LOGROTATE_EOF
/var/log/k3s.log {
    missingok
    nocreate
    size 50M
    rotate 4
}
LOGROTATE_EOF

    # Enable cloud-init services
    systemctl enable cloud-init

    # Setup OpenSSH Config
    sed -i 's/#UsePAM yes/UsePAM yes/g' /etc/ssh/sshd_config
    sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/g' /etc/ssh/sshd_config
    touch /etc/pam.d/sshd
    cat > /etc/pam.d/sshd <<PAM_EOF
auth      include   system-login
account   include   system-login
password  include   system-login
session   include   system-login
PAM_EOF

    systemctl enable ssh

    # SSH Root Access and Password Authentication
    echo 'ssh_pwauth: true' > /etc/cloud/cloud.cfg.d/50_remote_access.cfg
    echo 'ssh_deletekeys: true' >> /etc/cloud/cloud.cfg.d/50_remote_access.cfg
    echo 'disable_root: false' >> /etc/cloud/cloud.cfg.d/50_remote_access.cfg
    sed -i 's/PermitRootLogin .*/PermitRootLogin yes/g' /etc/ssh/sshd_config

    # Setup cgroups v2
    echo "cgroup2 /sys/fs/cgroup cgroup2 defaults 0 0" >> /etc/fstab
    cat > /etc/cgconfig.conf <<CGROUP_EOF
mount {
cpuacct = /cgroup/cpuacct;
memory = /cgroup/memory;
devices = /cgroup/devices;
freezer = /cgroup/freezer;
net_cls = /cgroup/net_cls;
blkio = /cgroup/blkio;
cpuset = /cgroup/cpuset;
cpu = /cgroup/cpu;
}
CGROUP_EOF

    # Kernel parameters for cgroups
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory\"" >> /etc/default/grub
    update-grub

    # Install k3s
    echo "Installing k3s ${K3S_IMAGE_NAME}"
    curl -L ${K3S_IMAGE_URL} -o /usr/local/bin/k3s
    chmod +x /usr/local/bin/k3s

    # Setup k3s systemd service
    cat > /etc/systemd/system/k3s.service <<K3S_EOF
[Unit]
Description=K3s
After=network.target

[Service]
ExecStart=/usr/local/bin/k3s server --kubelet-arg="kube-reserved=cpu=250m,memory=500Mi,ephemeral-storage=2Gi"
Restart=always
LimitNOFILE=1048576
LimitNPROC=infinity
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
K3S_EOF

    # Enable and start k3s
    systemctl enable k3s
    systemctl start k3s

    # Litestream setup
    wget https://github.com/benbjohnson/litestream/releases/download/v0.3.8/litestream-v0.3.8-linux-amd64-static.tar.gz -O /tmp/litestream.tgz
    tar xvf /tmp/litestream.tgz -C /tmp
    mv /tmp/litestream /usr/bin/litestream
    chmod +x /usr/bin/litestream
    rm /tmp/litestream.tgz

    # Litestream systemd service
    cat > /etc/systemd/system/litestream.service <<LITE_EOF
[Unit]
Description=Litestream Replication
After=network.target

[Service]
ExecStart=/usr/bin/litestream replicate
Restart=always
StandardOutput=syslog
StandardError=syslog

[Install]
WantedBy=multi-user.target
LITE_EOF

    # Enable and start Litestream
    systemctl enable litestream
    systemctl start litestream

    # Helm installation
    wget https://get.helm.sh/helm-v3.9.1-linux-amd64.tar.gz -O /tmp/helm.tgz
    tar xvf /tmp/helm.tgz -C /tmp
    mv /tmp/linux-amd64/helm /usr/local/bin/helm
    rm /tmp/helm.tgz

    # Enable NTP with chrony
    systemctl enable chrony
    systemctl start chrony

    # Configure BPF
    echo "bpffs /sys/fs/bpf bpf defaults,shared 0 0" >> /etc/fstab
    echo "Post-installation complete. System is ready."

OUTER

# Step 9: Enable serial console in GRUB

cat > "$MOUNT_DIR/tmp/update-grub.sh" <<'EOF'
#!/bin/bash

echo "[*] Updating GRUB config for serial and console output..."

GRUB_FILE="/etc/default/grub"

if [ ! -f "$GRUB_FILE" ]; then
    echo "[!] GRUB config not found at $GRUB_FILE"
    exit 1
fi

cp "$GRUB_FILE" "${GRUB_FILE}.bak"

sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"/' "$GRUB_FILE"
sed -i 's/^#GRUB_TERMINAL=/GRUB_TERMINAL=/' "$GRUB_FILE"

update-grub

echo "[+] GRUB configuration updated."
EOF

chmod +x "$MOUNT_DIR/tmp/update-grub.sh"
chroot "$MOUNT_DIR" /tmp/update-grub.sh
