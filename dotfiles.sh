#!/bin/bash

# Arch Linux Automatic Installer Script
# This script helps you install Arch Linux with interactive prompts.

set -e

CONFIG_FILE="./arch_installer.conf"

echo "==== Arch Linux Auto Installer ===="

# Load config (if exists)
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 1. Disk Selection
echo "Available disks:"
lsblk -d -n -o NAME,SIZE,MODEL
echo "Which disk do you want to install Arch Linux on? (e.g. sda, nvme0n1)"
read -rp "Disk: " INSTALL_DISK

INSTALL_DISK="/dev/$INSTALL_DISK"

# 2. Swap Partition
read -rp "Do you want to create a swap partition? (y/n): " CREATE_SWAP

# 3. Basic Partitioning & Formatting
echo "Partitioning disk $INSTALL_DISK..."
sgdisk --zap-all "$INSTALL_DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "$INSTALL_DISK"    # EFI partition
if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
    read -rp "Swap size (e.g. 4G): " SWAP_SIZE
    sgdisk -n 2:0:+"$SWAP_SIZE" -t 2:8200 "$INSTALL_DISK" # Linux swap
    sgdisk -n 3:0:0 -t 3:8300 "$INSTALL_DISK"             # Root
    SWAP_PART="${INSTALL_DISK}2"
    ROOT_PART="${INSTALL_DISK}3"
else
    sgdisk -n 2:0:0 -t 2:8300 "$INSTALL_DISK"             # Root
    ROOT_PART="${INSTALL_DISK}2"
fi
EFI_PART="${INSTALL_DISK}1"

echo "Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 "$ROOT_PART"
if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
fi

echo "Mounting partitions..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# 4. Base System Install
echo "Installing base system..."
pacstrap /mnt base linux linux-firmware networkmanager sudo

# 5. Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 6. User Setup
echo "Enter username for the new user:"
read -rp "Username: " NEW_USER
read -rsp "Password: " NEW_PASS; echo

echo "Do you want to enable autologin for this user? (y/n): "
read -r AUTOLOGIN

# 7. Desktop Environment and Related Software
echo "Choose your Desktop Environment:"
DE=("GNOME" "KDE" "XFCE" "Cinnamon" "MATE")
select DESKTOP in "${DE[@]}"; do
    [[ -n $DESKTOP ]] && break
done

echo "Choose your Display Manager:"
DM=("gdm" "sddm" "lightdm" "lxdm" "none")
select DISPLAY_MANAGER in "${DM[@]}"; do
    [[ -n $DISPLAY_MANAGER ]] && break
done

echo "Choose your Terminal Emulator:"
TE=("gnome-terminal" "konsole" "xfce4-terminal" "kitty" "alacritty")
select TERMINAL in "${TE[@]}"; do
    [[ -n $TERMINAL ]] && break
done

echo "Choose your Login Environment:"
LE=("default" "Wayland" "Xorg" "console" "none")
select LOGIN_ENV in "${LE[@]}"; do
    [[ -n $LOGIN_ENV ]] && break
done

# 8. Browser and Others
echo "Google Chrome will be installed by default."
echo "Do you want to install Steam? (y/n): "
read -r INSTALL_STEAM
echo "Do you want to install ProtonUp-Qt? (y/n): "
read -r INSTALL_PROTONUP

# 9. Save config for chroot
cat << EOF > /mnt/arch_installer.conf
NEW_USER="$NEW_USER"
NEW_PASS="$NEW_PASS"
AUTOLOGIN="$AUTOLOGIN"
DESKTOP="$DESKTOP"
DISPLAY_MANAGER="$DISPLAY_MANAGER"
TERMINAL="$TERMINAL"
LOGIN_ENV="$LOGIN_ENV"
INSTALL_STEAM="$INSTALL_STEAM"
INSTALL_PROTONUP="$INSTALL_PROTONUP"
EOF

# 10. Copy post-install script into chroot
cat << 'EOS' > /mnt/post_install.sh
#!/bin/bash
set -e

source /arch_installer.conf

# Set timezone and locales
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc
sed -i '/^#en_US.UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "archlinux" > /etc/hostname

# Setup hosts
cat << HO > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   archlinux.localdomain archlinux
HO

# Set root password to blank (user must change later)
echo "root:" | chpasswd

# Create user
useradd -m -G wheel "$NEW_USER"
echo "$NEW_USER:$NEW_PASS" | chpasswd
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

# Enable network
systemctl enable NetworkManager

# Install microcode
if grep -q GenuineIntel /proc/cpuinfo; then
    pacman -S --noconfirm intel-ucode
else
    pacman -S --noconfirm amd-ucode
fi

# Install desktop environment and display manager
case "$DESKTOP" in
    GNOME)
        pacman -S --noconfirm gnome gnome-tweaks
        ;;
    KDE)
        pacman -S --noconfirm plasma kde-applications
        ;;
    XFCE)
        pacman -S --noconfirm xfce4 xfce4-goodies
        ;;
    Cinnamon)
        pacman -S --noconfirm cinnamon
        ;;
    MATE)
        pacman -S --noconfirm mate mate-extra
        ;;
esac

case "$DISPLAY_MANAGER" in
    gdm)   pacman -S --noconfirm gdm; systemctl enable gdm ;;
    sddm)  pacman -S --noconfirm sddm; systemctl enable sddm ;;
    lightdm) pacman -S --noconfirm lightdm lightdm-gtk-greeter; systemctl enable lightdm ;;
    lxdm)  pacman -S --noconfirm lxdm; systemctl enable lxdm ;;
esac

# Terminal emulator
pacman -S --noconfirm "$TERMINAL"

# Install Chrome
pacman -S --noconfirm --needed base-devel
if ! grep -q '\[chaotic-aur\]' /etc/pacman.conf; then
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key 3056513887B78AEB
    echo -e '[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
    pacman -Syu --noconfirm
fi
pacman -S --noconfirm google-chrome

# Steam
if [[ "$INSTALL_STEAM" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm steam
fi

# ProtonUp-Qt
if [[ "$INSTALL_PROTONUP" =~ ^[Yy]$ ]]; then
    pacman -S --noconfirm protonup-qt
fi

# Autologin
if [[ "$AUTOLOGIN" =~ ^[Yy]$ ]] && [[ "$DISPLAY_MANAGER" == "gdm" ]]; then
    mkdir -p /etc/gdm
    echo -e "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$NEW_USER" >> /etc/gdm/custom.conf
fi

if [[ "$AUTOLOGIN" =~ ^[Yy]$ ]] && [[ "$DISPLAY_MANAGER" == "sddm" ]]; then
    mkdir -p /etc/sddm.conf.d
    echo -e "[Autologin]\nUser=$NEW_USER" > /etc/sddm.conf.d/autologin.conf
fi

echo "Installation complete! Please reboot."
EOS

chmod +x /mnt/post_install.sh

arch-chroot /mnt /post_install.sh

echo "Arch Linux installation is complete! You can now reboot."
