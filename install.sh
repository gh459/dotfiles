#!/bin/bash
# install.sh - Arch Linux Base Installation Script

# Stop on any error
set -e

echo "============================================="
echo " Arch Linux Installer Script"
echo "============================================="
echo "INFO: This script will erase all data on the selected disk."
echo "INFO: Make sure you have a backup of your important data."
echo "INFO: Please ensure you are connected to the internet."
echo "============================================="

# --- Get user inputs ---
read -p "Enter username: " USERNAME
read -s -p "Enter password for $USERNAME: " USER_PASSWORD
echo
read -p "Enter hostname: " HOSTNAME

echo "Select your graphics card vendor:"
select DRIVER in "NVIDIA" "AMD" "Intel" "None (or Virtual Machine)"; do
    case $DRIVER in
        "NVIDIA") GFX_PACKAGE="nvidia nvidia-utils"; break;;
        "AMD") GFX_PACKAGE="xf86-video-amdgpu"; break;;
        "Intel") GFX_PACKAGE="xf86-video-intel"; break;;
        "None (or Virtual Machine)") GFX_PACKAGE="mesa"; break;;
    esac
done

echo "Select your Desktop Environment:"
select DE_CHOICE in "GNOME" "KDE Plasma" "XFCE" "Cinnamon" "MATE"; do
    case $DE_CHOICE in
        "GNOME") DE_PACKAGES="gnome gdm gnome-terminal"; DM="gdm"; break;;
        "KDE Plasma") DE_PACKAGES="plasma-meta konsole sddm"; DM="sddm"; break;;
        "XFCE") DE_PACKAGES="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xfce4-terminal"; DM="lightdm"; break;;
        "Cinnamon") DE_PACKAGES="cinnamon lightdm lightdm-gtk-greeter gnome-terminal"; DM="lightdm"; break;;
        "MATE") DE_PACKAGES="mate mate-extra lightdm lightdm-gtk-greeter mate-terminal"; DM="lightdm"; break;;
    esac
done

read -p "Enable automatic login? (y/n): " AUTOLOGIN_CHOICE
[[ "$AUTOLOGIN_CHOICE" =~ ^[Yy]$ ]] && AUTOLOGIN="yes" || AUTOLOGIN="no"

read -p "Create a swap partition? (y/n): " SWAP_CHOICE
if [[ "$SWAP_CHOICE" =~ ^[Yy]$ ]]; then
    read -p "Enter swap size (e.g., 8G): " SWAP_SIZE
fi

read -p "Install Steam and ProtonUp-Qt? (y/n): " STEAM_CHOICE
[[ "$STEAM_CHOICE" =~ ^[Yy]$ ]] && INSTALL_STEAM="yes" || INSTALL_STEAM="no"


# --- Disk partitioning ---
echo "INFO: Available disks:"
lsblk -d -o NAME,SIZE
read -p "Enter the disk to install on (e.g., /dev/sda): " INSTALL_DISK

echo "WARNING: This will delete all data on $INSTALL_DISK. Press Enter to continue, or Ctrl+C to cancel."
read -r

echo "INFO: Partitioning disk $INSTALL_DISK..."
timedatectl set-ntp true

# Wipe disk and create partitions with sgdisk
sgdisk --zap-all "$INSTALL_DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:EFI "$INSTALL_DISK" # EFI Partition

if [[ "$SWAP_CHOICE" =~ ^[Yy]$ ]]; then
    sgdisk -n 2:0:+"$SWAP_SIZE" -t 2:8200 -c 2:SWAP "$INSTALL_DISK" # Swap Partition
    sgdisk -n 3:0:0 -t 3:8300 -c 3:ROOT "$INSTALL_DISK" # Root Partition
    PART_EFI="${INSTALL_DISK}1"
    PART_SWAP="${INSTALL_DISK}2"
    PART_ROOT="${INSTALL_DISK}3"
else
    sgdisk -n 2:0:0 -t 2:8300 -c 2:ROOT "$INSTALL_DISK" # Root Partition
    PART_EFI="${INSTALL_DISK}1"
    PART_ROOT="${INSTALL_DISK}2"
fi

echo "INFO: Formatting partitions..."
mkfs.fat -F32 "$PART_EFI"
mkfs.ext4 "$PART_ROOT"
if [[ "$SWAP_CHOICE" =~ ^[Yy]$ ]]; then
    mkswap "$PART_SWAP"
fi

echo "INFO: Mounting filesystems..."
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$PART_EFI" /mnt/boot/efi
if [[ "$SWAP_CHOICE" =~ ^[Yy]$ ]]; then
    swapon "$PART_SWAP"
fi


# --- Base system installation ---
echo "INFO: Installing base system (pacstrap)... This may take a while."
pacstrap /mnt base base-devel linux linux-firmware git grub efibootmgr networkmanager

echo "INFO: Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab


# --- Prepare chroot environment ---
echo "INFO: Preparing chroot environment..."
# Store variables for chroot script
cat <<EOF > /mnt/install_vars.sh
USERNAME="$USERNAME"
USER_PASSWORD="$USER_PASSWORD"
HOSTNAME="$HOSTNAME"
GFX_PACKAGE="$GFX_PACKAGE"
DE_PACKAGES="$DE_PACKAGES"
DM="$DM"
AUTOLOGIN="$AUTOLOGIN"
INSTALL_STEAM="$INSTALL_STEAM"
EOF

# Copy chroot script to new system
cp chroot_setup.sh /mnt/
chmod +x /mnt/chroot_setup.sh

echo "INFO: Entering chroot and running setup script..."
arch-chroot /mnt /chroot_setup.sh


# --- Finalization ---
echo "INFO: Cleaning up..."
rm /mnt/install_vars.sh
rm /mnt/chroot_setup.sh

echo "INFO: Unmounting partitions..."
umount -R /mnt

echo "============================================="
echo " Installation Complete!"
echo "============================================="
echo "INFO: You can now reboot the system. Please remove the installation media."
read -p "Reboot now? (y/n): " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    reboot
fi
