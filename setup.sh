#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

echo "Setting locale to Japanese..."
sed -i 's/#ja_JP.UTF-8/ja_JP.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=ja_JP.UTF-8' > /etc/locale.conf
export LANG=ja_JP.UTF-8

echo "Installing essential packages..."
pacman -Sy --noconfirm base base-devel linux linux-firmware vim nano

echo "Driver installation: Choose your GPU driver"
echo "1) NVIDIA 2) AMD 3) Intel"
read -r gpu_choice
if [ "$gpu_choice" -eq 1 ]; then
  pacman -Sy --noconfirm nvidia
elif [ "$gpu_choice" -eq 2 ]; then
  pacman -Sy --noconfirm xf86-video-amdgpu
elif [ "$gpu_choice" -eq 3 ]; then
  pacman -Sy --noconfirm xf86-video-intel
else
  echo "Invalid choice, skipping GPU driver installation."
fi

echo "Listing available disks..."
lsblk
echo "Enter the disk for installation (e.g., /dev/sda):"
read -r disk
echo "Create swap partition? (yes/no)"
read -r swap_choice
if [ "$swap_choice" == "yes" ]; then
  swap_size="1G" # Default swap size
  echo "Enter swap size (e.g., 1G, 2G):"
  read -r swap_size
  echo "Creating swap partition..."
  parted "$disk" mkpart primary linux-swap 1MiB "$swap_size"
  mkswap "${disk}1"
  swapon "${disk}1"
fi
echo "Formatting and partitioning the disk..."
parted "$disk" mklabel gpt
parted "$disk" mkpart primary ext4 "$swap_size" 100%
mkfs.ext4 "${disk}2"
mount "${disk}2" /mnt

echo "Installing Arch Linux base system..."
pacstrap /mnt base base-devel linux linux-firmware

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Chrooting into the new system..."
cp chroot_setup.sh /mnt/
arch-chroot /mnt ./chroot_setup.sh

echo "Setup completed successfully!"
