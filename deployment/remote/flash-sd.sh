#!/bin/bash
#
# Flash Arch Linux ARM to SD card for Raspberry Pi 4
#
# Usage: ./flash-sd.sh /dev/sdX
#
# This script will:
# 1. Partition the SD card (1GB boot, rest root)
# 2. Download Arch Linux ARM aarch64 tarball
# 3. Extract to SD card
# 4. Fix fstab for RPi 4 (mmcblk1)
# 5. Inject SSH public key for kosciak user
#
# WARNING: This will DESTROY all data on the target device!

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ARCH_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz"
ARCH_MD5_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5"
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/arch-arm}"

# Check if running as root for certain operations
need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}This operation requires root. Using sudo...${NC}"
        sudo "$@"
    else
        "$@"
    fi
}

usage() {
    echo "Usage: $0 <device>"
    echo ""
    echo "  device    The SD card device (e.g., /dev/sda, /dev/mmcblk0)"
    echo ""
    echo "Environment variables:"
    echo "  SSH_PUBKEY    Path to SSH public key (default: ~/.ssh/id_ed25519.pub)"
    echo "  DOWNLOAD_DIR  Directory for downloads (default: /tmp/arch-arm)"
    echo ""
    echo "Example:"
    echo "  $0 /dev/sda"
    echo "  SSH_PUBKEY=~/.ssh/id_rsa.pub $0 /dev/sda"
    exit 1
}

confirm() {
    echo -e "${RED}WARNING: This will DESTROY all data on $DEVICE${NC}"
    echo ""
    lsblk "$DEVICE"
    echo ""
    read -p "Are you sure you want to continue? Type 'yes' to proceed: " response
    if [[ "$response" != "yes" ]]; then
        echo "Aborted."
        exit 1
    fi
}

check_dependencies() {
    local deps=("fdisk" "mkfs.vfat" "mkfs.ext4" "tar" "wget" "md5sum")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -ne 0 ]]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
        echo "On Arch Linux: pacman -S dosfstools e2fsprogs tar wget coreutils"
        exit 1
    fi
    
    if [[ ! -f "$SSH_PUBKEY" ]]; then
        echo -e "${RED}SSH public key not found: $SSH_PUBKEY${NC}"
        echo "Generate one with: ssh-keygen -t ed25519"
        exit 1
    fi
}

partition_device() {
    echo -e "${GREEN}Partitioning $DEVICE...${NC}"
    
    # Unmount any existing partitions
    for part in "${DEVICE}"*; do
        if mountpoint -q "$part" 2>/dev/null || mount | grep -q "$part"; then
            echo "Unmounting $part..."
            need_root umount "$part" 2>/dev/null || true
        fi
    done
    
    # Create new partition table
    need_root fdisk "$DEVICE" <<EOF
o
n
p
1

+1G
t
c
n
p
2


w
EOF

    # Wait for kernel to re-read partition table
    sleep 2
    need_root partprobe "$DEVICE" 2>/dev/null || true
    sleep 2
}

format_partitions() {
    echo -e "${GREEN}Formatting partitions...${NC}"
    
    # Determine partition naming scheme
    if [[ "$DEVICE" == *"nvme"* ]] || [[ "$DEVICE" == *"mmcblk"* ]]; then
        BOOT_PART="${DEVICE}p1"
        ROOT_PART="${DEVICE}p2"
    else
        BOOT_PART="${DEVICE}1"
        ROOT_PART="${DEVICE}2"
    fi
    
    need_root mkfs.vfat -F 32 "$BOOT_PART"
    need_root mkfs.ext4 -F "$ROOT_PART"
}

download_arch() {
    echo -e "${GREEN}Downloading Arch Linux ARM...${NC}"
    
    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR"
    
    # Download if not already present or if MD5 doesn't match
    if [[ ! -f "ArchLinuxARM-rpi-aarch64-latest.tar.gz" ]]; then
        wget -c "$ARCH_URL"
        wget -c "$ARCH_MD5_URL"
    fi
    
    echo "Verifying checksum..."
    if ! md5sum -c "ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5"; then
        echo -e "${RED}Checksum verification failed!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Checksum OK${NC}"
}

extract_arch() {
    echo -e "${GREEN}Extracting Arch Linux ARM to SD card...${NC}"
    
    # Create mount points
    MOUNT_BOOT=$(mktemp -d)
    MOUNT_ROOT=$(mktemp -d)
    
    # Mount partitions
    need_root mount "$BOOT_PART" "$MOUNT_BOOT"
    need_root mount "$ROOT_PART" "$MOUNT_ROOT"
    
    # Extract root filesystem (must be done as root to preserve permissions)
    echo "Extracting tarball (this may take a few minutes)..."
    need_root tar -xpf "$DOWNLOAD_DIR/ArchLinuxARM-rpi-aarch64-latest.tar.gz" -C "$MOUNT_ROOT"
    
    # Move boot files to boot partition
    need_root mv "$MOUNT_ROOT/boot/"* "$MOUNT_BOOT/"
    
    # Sync to ensure all data is written
    sync
    
    echo -e "${GREEN}Extraction complete${NC}"
}

fix_fstab() {
    echo -e "${GREEN}Fixing fstab for Raspberry Pi 4...${NC}"
    
    # RPi 4 uses mmcblk1 instead of mmcblk0
    need_root sed -i 's/mmcblk0/mmcblk1/g' "$MOUNT_ROOT/etc/fstab"
    
    echo "Updated fstab:"
    cat "$MOUNT_ROOT/etc/fstab"
}

inject_ssh_key() {
    echo -e "${GREEN}Injecting SSH public key for alarm user...${NC}"
    
    # Create .ssh directory for alarm user
    need_root mkdir -p "$MOUNT_ROOT/home/alarm/.ssh"
    need_root chmod 700 "$MOUNT_ROOT/home/alarm/.ssh"
    
    # Copy SSH public key
    need_root cp "$SSH_PUBKEY" "$MOUNT_ROOT/home/alarm/.ssh/authorized_keys"
    need_root chmod 600 "$MOUNT_ROOT/home/alarm/.ssh/authorized_keys"
    
    # Fix ownership (alarm user has UID 1000 by default)
    need_root chown -R 1000:1000 "$MOUNT_ROOT/home/alarm/.ssh"
    
    echo "SSH key injected from: $SSH_PUBKEY"
}

cleanup() {
    echo -e "${GREEN}Cleaning up...${NC}"
    
    sync
    
    if [[ -n "${MOUNT_BOOT:-}" ]] && mountpoint -q "$MOUNT_BOOT" 2>/dev/null; then
        need_root umount "$MOUNT_BOOT"
        rmdir "$MOUNT_BOOT"
    fi
    
    if [[ -n "${MOUNT_ROOT:-}" ]] && mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
        need_root umount "$MOUNT_ROOT"
        rmdir "$MOUNT_ROOT"
    fi
}

main() {
    if [[ $# -ne 1 ]]; then
        usage
    fi
    
    DEVICE="$1"
    
    if [[ ! -b "$DEVICE" ]]; then
        echo -e "${RED}Error: $DEVICE is not a block device${NC}"
        exit 1
    fi
    
    # Prevent accidental use on system drives
    if [[ "$DEVICE" == "/dev/sda" ]] && [[ -d "/sys/block/sda/device/scsi_disk" ]]; then
        # Check if it looks like a system drive (has multiple partitions with common mount points)
        if mount | grep -q "^$DEVICE.* / \|^$DEVICE.*/home"; then
            echo -e "${RED}Error: $DEVICE appears to be a system drive!${NC}"
            exit 1
        fi
    fi
    
    check_dependencies
    confirm
    
    trap cleanup EXIT
    
    partition_device
    format_partitions
    download_arch
    extract_arch
    fix_fstab
    inject_ssh_key
    cleanup
    
    trap - EXIT
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}SD card is ready!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Insert SD card into Raspberry Pi 4"
    echo "2. Connect ethernet cable"
    echo "3. Power on the Pi"
    echo "4. Find the Pi's IP address (check your router or use: nmap -sn 192.168.1.0/24)"
    echo "5. SSH in: ssh alarm@<ip-address>"
    echo "6. Run Ansible bootstrap: ansible-playbook playbooks/bootstrap.yml"
    echo ""
    echo "Default credentials (before bootstrap):"
    echo "  User: alarm / Password: alarm"
    echo "  Root: root / Password: root"
}

main "$@"
