# Debian Make VM Image

## Prerequisites

1. **Install Docker**  
   Ensure Docker is installed on your system.

2. **Run the Docker Container**  
   ```bash
   docker run -it --privileged -v /dev:/dev debian:bookworm bash
   ```

## Steps to Create the VM Image

1. **Copy and Execute the Script**  
   Copy the `debian-vm.sh` script to the container and execute it.

2. **Verify the Output**  
   After running the script, perform the following checks:
   - Run `lsblk` and ensure it outputs a loop device with the mount point as `/mnt/debian`.
   - Run:
     ```bash
     cat /mnt/debian/boot/grub/grub.cfg | grep console
     ```
     This should produce some output.

3. **Run the QEMU Command**  
   If the above steps are successful, execute the following command:
   ```bash
   qemu-system-x86_64 -m 4096 /workdir/debian.img -nographic -net user -net nic
   ```

4. **Login to the Shell Prompt**  
   After some time, a shell prompt should appear. Use the following credentials to log in:
   - **Username:** `root`
   - **Password:** `root`

5. **Verify Kubernetes Node**  
   Run the following command to verify the setup:
   ```bash
   k3s kubectl get nodes
   ```
   This should display the expected output.
