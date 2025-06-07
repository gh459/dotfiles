#!/bin/bash
# install.sh - Arch Linux Base Installation Script

# Exit on any error
set -e

# --- Initial Setup ---
echo "Setting Japanese keyboard layout"
loadkeys jp106

echo "Verifying boot mode"
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "ERROR: Not booted in UEFI mode. This script is for UEFI systems only."
    exit 1
fi

echo "Updating system clock"
timedatectl set-ntp true

# --- Disk Partitioning ---
echo "------------------------------------------------"
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL
echo "------------------------------------------------"

read -p "Enter the disk to install Arch Linux on (e.g., /dev/sda): " TARGET_DISK

if ! lsblk -d -o NAME | grep -q "$(basename "$TARGET_DISK")"; then
    echo "ERROR: Disk $TARGET_DISK not found."
    exit 1
fi

read -p "THIS WILL WIPE ALL DATA ON ${TARGET_DISK}. Are you sure? (y/N): " CONFIRM_WIPE
if [[ ! "$CONFIRM_WIPE" =~ ^[yY]$ ]]; then
    echo "Aborting."
    exit 1
fi

read -p "Create a swap partition? (y/N): " CREATE_SWAP
SWAP_SIZE_GB=0
if [[ "$CREATE_SWAP" =~ ^[yY]$ ]]; then
    read -p "Enter swap size in GB (e.g., 8): " SWAP_SIZE_GB
fi

echo "Partitioning ${TARGET_DISK}..."
parted -s "${TARGET_DISK}" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 esp on

if [[ "$CREATE_SWAP" =~ ^[yY]$ ]]; then
    parted -s "${TARGET_DISK}" \
        mkpart primary linux-swap 513MiB $((513 + SWAP_SIZE_GB * 1024))MiB \
        mkpart primary ext4 $((513 + SWAP_SIZE_GB * 1024))MiB 100%
else
    parted -s "${TARGET_DISK}" \
        mkpart primary ext4 513MiB 100%
fi

# Determine partition names
EFI_PARTITION="${TARGET_DISK}1"
if [[ "$CREATE_SWAP" =~ ^[yY]$ ]]; then
    SWAP_PARTITION="${TARGET_DISK}2"
    ROOT_PARTITION="${TARGET_DISK}3"
else
    ROOT_PARTITION="${TARGET_DISK}2"
fi

# --- Formatting Partitions ---
echo "Formatting partitions..."
mkfs.fat -F32 "${EFI_PARTITION}"
mkfs.ext4 "${ROOT_PARTITION}"
if [[ "$CREATE_SWAP" =~ ^[yY]$ ]]; then
    mkswap "${SWAP_PARTITION}"
fi

# --- Mounting File Systems ---
echo "Mounting file systems..."
mount "${ROOT_PARTITION}" /mnt
mkdir -p /mnt/boot
mount "${EFI_PARTITION}" /mnt/boot
if [[ "$CREATE_SWAP" =~ ^[yY]$ ]]; then
    swapon "${SWAP_PARTITION}"
fi

# --- Installing Base System ---
echo "Installing base system and essential packages..."
pacstrap /mnt base linux linux-firmware base-devel git vim sudo networkmanager

# --- Generating fstab ---
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot and Final Setup ---
echo "Copying chroot script to new system..."
cp chroot_setup.sh /mnt/
chmod +x /mnt/chroot_setup.sh

echo "Entering chroot environment to continue setup..."
arch-chroot /mnt /chroot_setup.sh

# --- Finish ---
echo "------------------------------------------------"
echo "Installation complete."
echo "Unmounting partitions..."
umount -R /mnt
swapoff -a
echo "You can now safely reboot your system by typing 'reboot'."
echo "------------------------------------------------"

