#!/bin/bash

# Exit on any error
set -e

echo ">>> Setting up Japanese keyboard layout"
loadkeys jp106

echo ">>> Updating system clock"
timedatectl set-ntp true

echo ">>> Listing available disks"
lsblk -d -o NAME,SIZE,MODEL
echo ">>> Please enter the disk to install Arch Linux on (e.g., sda, nvme0n1):"
read -r INSTALL_DRIVE
INSTALL_DRIVE="/dev/${INSTALL_DRIVE}"

if ! [ -b "$INSTALL_DRIVE" ]; then
    echo "!!! ERROR: Disk ${INSTALL_DRIVE} not found."
    exit 1
fi

echo ">>> WARNING: This will format ${INSTALL_DRIVE}. All data will be lost."
echo ">>> Do you want to continue? (y/N)"
read -r CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "!!! Installation aborted."
    exit 0
fi

echo ">>> Do you want to create a swap partition? (y/N)"
read -r SWAP_CHOICE
SWAP_SIZE="8G" # You can change the swap size here

echo ">>> Please enter a username:"
read -r USER_NAME

echo ">>> Please enter a password for the user ${USER_NAME}:"
read -s -r USER_PASSWORD

echo ">>> Do you want to enable autologin? (y/N)"
read -r AUTOLOGIN_CHOICE

echo ">>> Select a Desktop Environment:"
echo "1) GNOME"
echo "2) KDE Plasma"
echo "3) XFCE4"
echo "4) Cinnamon"
echo "5) MATE"
read -r DE_CHOICE

echo ">>> Do you want to install Steam and ProtonUp-Qt? (y/N)"
read -r STEAM_CHOICE

# Partitioning the disk
echo ">>> Partitioning ${INSTALL_DRIVE}"
sgdisk --zap-all "${INSTALL_DRIVE}"
sgdisk -n 1:0:+512M -t 1:ef00 "${INSTALL_DRIVE}" # EFI Partition

if [ "$SWAP_CHOICE" = "y" ]; then
    sgdisk -n 2:0:+"${SWAP_SIZE}" -t 2:8200 "${INSTALL_DRIVE}" # Swap Partition
    sgdisk -n 3:0:0 -t 3:8300 "${INSTALL_DRIVE}" # Root Partition
    ROOT_PARTITION="${INSTALL_DRIVE}p3"
    SWAP_PARTITION="${INSTALL_DRIVE}p2"
else
    sgdisk -n 2:0:0 -t 2:8300 "${INSTALL_DRIVE}" # Root Partition
    ROOT_PARTITION="${INSTALL_DRIVE}p2"
fi
EFI_PARTITION="${INSTALL_DRIVE}p1"

# Formatting the partitions
echo ">>> Formatting partitions"
mkfs.fat -F32 "${EFI_PARTITION}"
mkfs.ext4 "${ROOT_PARTITION}"
if [ "$SWAP_CHOICE" = "y" ]; then
    mkswap "${SWAP_PARTITION}"
    swapon "${SWAP_PARTITION}"
fi

# Mounting the file systems
echo ">>> Mounting file systems"
mount "${ROOT_PARTITION}" /mnt
mkdir -p /mnt/boot
mount "${EFI_PARTITION}" /mnt/boot

# Install essential packages
echo ">>> Installing base system (pacstrap)"
pacstrap /mnt base linux linux-firmware base-devel git vim networkmanager grub efibootmgr

# Generate fstab
echo ">>> Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Create configuration file for chroot script
echo ">>> Creating chroot configuration"
cat <<EOF > /mnt/chroot_config.sh
USER_NAME="${USER_NAME}"
USER_PASSWORD="${USER_PASSWORD}"
AUTOLOGIN_CHOICE="${AUTOLOGIN_CHOICE}"
DE_CHOICE="${DE_CHOICE}"
STEAM_CHOICE="${STEAM_CHOICE}"
EOF

# Copy chroot script and execute it
echo ">>> Preparing for chroot"
cp chroot_setup.sh /mnt/
chmod +x /mnt/chroot_setup.sh

echo ">>> Entering chroot and running setup script"
arch-chroot /mnt /bin/bash /chroot_setup.sh

# Cleanup and finish
echo ">>> Cleaning up"
rm /mnt/chroot_setup.sh
rm /mnt/chroot_config.sh

echo ">>> Installation finished. You can now unmount and reboot."
echo ">>> umount -R /mnt"
echo ">>> reboot"

