#!/bin/bash
# install.sh - Main Arch Linux installation script

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
TIMEZONE="Asia/Tokyo"
LOCALE_LANG="ja_JP.UTF-8"
VCONSOLE_KEYMAP="jp106"

# --- Helper Functions ---
info() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
    exit 1
}

# --- Main Functions ---

# 1. Pre-installation checks
pre_install_checks() {
    info "Starting pre-installation checks..."

    # Check for UEFI boot mode
    if [ ! -d /sys/firmware/efi/efivars ]; then
        error "UEFI boot mode not detected. This script only supports UEFI systems."
    fi
    info "UEFI boot mode confirmed."

    # Check for internet connection
    if ! ping -c 1 archlinux.org &>/dev/null; then
        error "No internet connection. Please connect to the internet and try again."
    fi
    info "Internet connection confirmed."

    # Update system clock
    info "Updating system clock..."
    timedatectl set-ntp true
    info "System clock updated."
}

# 2. Disk partitioning and formatting
setup_disk() {
    info "Listing available disks..."
    lsblk -d -o NAME,SIZE,MODEL

    read -p "Enter the disk to install Arch Linux on (e.g., /dev/sda, /dev/nvme0n1): " INSTALL_DISK
    if [ ! -b "$INSTALL_DISK" ]; then
        error "Invalid disk selected: $INSTALL_DISK"
    fi

    read -p "Do you want to create a swap partition (8GB)? [y/N]: " CREATE_SWAP

    info "THIS WILL DELETE ALL DATA ON $INSTALL_DISK. Are you sure?"
    read -p "Type 'YES' to continue: " CONFIRM_DELETE
    if [ "$CONFIRM_DELETE" != "YES" ]; then
        error "Installation aborted by user."
    fi

    info "Partitioning $INSTALL_DISK..."
    # Wipe existing partition table
    sgdisk --zap-all "$INSTALL_DISK"

    parted -s "$INSTALL_DISK" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 esp on

    if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
        parted -s "$INSTALL_DISK" \
            mkpart swap linux-swap 513MiB 8705MiB \
            mkpart root ext4 8705MiB 100%
        
        if [[ "$INSTALL_DISK" == *"nvme"* ]]; then
            EFI_PARTITION="${INSTALL_DISK}p1"
            SWAP_PARTITION="${INSTALL_DISK}p2"
            ROOT_PARTITION="${INSTALL_DISK}p3"
        else
            EFI_PARTITION="${INSTALL_DISK}1"
            SWAP_PARTITION="${INSTALL_DISK}2"
            ROOT_PARTITION="${INSTALL_DISK}3"
        fi
        
        info "Formatting partitions..."
        mkfs.fat -F32 "$EFI_PARTITION"
        mkswap "$SWAP_PARTITION"
        mkfs.ext4 -F "$ROOT_PARTITION"

        info "Mounting file systems..."
        mount "$ROOT_PARTITION" /mnt
        swapon "$SWAP_PARTITION"
        mkdir -p /mnt/boot
        mount "$EFI_PARTITION" /mnt/boot
    else
        parted -s "$INSTALL_DISK" \
            mkpart root ext4 513MiB 100%

        if [[ "$INSTALL_DISK" == *"nvme"* ]]; then
            EFI_PARTITION="${INSTALL_DISK}p1"
            ROOT_PARTITION="${INSTALL_DISK}p2"
        else
            EFI_PARTITION="${INSTALL_DISK}1"
            ROOT_PARTITION="${INSTALL_DISK}2"
        fi

        info "Formatting partitions..."
        mkfs.fat -F32 "$EFI_PARTITION"
        mkfs.ext4 -F "$ROOT_PARTITION"

        info "Mounting file systems..."
        mount "$ROOT_PARTITION" /mnt
        mkdir -p /mnt/boot
        mount "$EFI_PARTITION" /mnt/boot
    fi

    info "Disk setup complete."
}

# 3. User and Desktop Environment setup
setup_user_and_de() {
    info "Setting up user and desktop environment choices..."
    
    read -p "Enter your desired username: " USERNAME
    read -s -p "Enter your password: " PASSWORD
    echo
    read -s -p "Confirm your password: " PASSWORD_CONFIRM
    echo
    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        error "Passwords do not match."
    fi

    read -p "Enable autologin? [y/N]: " AUTOLOGIN_CHOICE
    [[ "$AUTOLOGIN_CHOICE" =~ ^[Yy]$ ]] && AUTOLOGIN="true" || AUTOLOGIN="false"

    info "Please choose a Desktop Environment:"
    echo "1) GNOME"
    echo "2) KDE Plasma"
    echo "3) XFCE"
    echo "4) Cinnamon"
    echo "5) MATE"
    read -p "Enter the number of your choice [1-5]: " DE_CHOICE

    case $DE_CHOICE in
        1) DE_PACKAGES="gnome gdm gnome-terminal"; DM="gdm";;
        2) DE_PACKAGES="plasma-meta sddm konsole"; DM="sddm";;
        3) DE_PACKAGES="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xfce4-terminal"; DM="lightdm";;
        4) DE_PACKAGES="cinnamon lightdm lightdm-gtk-greeter gnome-terminal"; DM="lightdm";;
        5) DE_PACKAGES="mate mate-extra lightdm lightdm-gtk-greeter mate-terminal"; DM="lightdm";;
        *) error "Invalid choice. Exiting.";;
    esac

    read -p "Install Steam? [y/N]: " INSTALL_STEAM
    [[ "$INSTALL_STEAM" =~ ^[Yy]$ ]] && STEAM="true" || STEAM="false"
    read -p "Install ProtonUp-Qt? [y/N]: " INSTALL_PROTONUP
    [[ "$INSTALL_PROTONUP" =~ ^[Yy]$ ]] && PROTONUP="true" || PROTONUP="false"

    info "Configuration complete."
}

# 4. Core installation
install_system() {
    info "Installing base system (pacstrap). This may take a while..."
    pacstrap /mnt base linux linux-firmware base-devel git sudo grub efibootmgr networkmanager

    info "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab

    info "Copying chroot script to new system..."
    cp chroot_config.sh /mnt/chroot_config.sh
    chmod +x /mnt/chroot_config.sh

    info "Chrooting into new system to continue setup..."
    arch-chroot /mnt ./chroot_config.sh \
        "$TIMEZONE" "$LOCALE_LANG" "$VCONSOLE_KEYMAP" "$USERNAME" "$PASSWORD" \
        "$DE_PACKAGES" "$DM" "$AUTOLOGIN" "$STEAM" "$PROTONUP"

    # Cleanup
    rm /mnt/chroot_config.sh
}

# 5. Finalization
finalize_installation() {
    info "Unmounting all partitions..."
    umount -R /mnt
    
    if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
        swapoff -a
    fi

    info "Installation finished! You can now reboot your system."
    echo "Type 'reboot' to restart your computer."
}

# --- Main Script Execution ---
main() {
    pre_install_checks
    setup_disk
    setup_user_and_de
    install_system
    finalize_installation
}

main
