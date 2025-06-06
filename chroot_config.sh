#!/bin/bash
# chroot_config.sh - Configuration script to be run inside chroot (Revised for Japanese support)

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Received Variables from install.sh ---
TIMEZONE=$1
LOCALE_LANG=$2
VCONSOLE_KEYMAP=$3
USERNAME=$4
PASSWORD=$5
DE_PACKAGES=$6
DM=$7
AUTOLOGIN=$8
INSTALL_STEAM=$9
INSTALL_PROTONUP=${10}

# --- Helper Functions ---
info() {
    echo -e "\e[32m[CHROOT-INFO]\e[0m $1"
}

# --- Configuration inside chroot ---

# 1. System configuration (Timezone, Locale, Hostname)
configure_system() {
    info "Setting timezone, locale, and hostname..."
    
    # Set timezone
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    hwclock --systohc

    # Configure locale
    sed -i "s/#${LOCALE_LANG}/${LOCALE_LANG}/" /etc/locale.gen
    sed -i "s/#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen
    echo "LANG=${LOCALE_LANG}" > /etc/locale.conf
    
    # Set keyboard layout for the virtual console
    echo "KEYMAP=${VCONSOLE_KEYMAP}" > /etc/vconsole.conf

    # Set hostname
    read -p "Enter a hostname for your system: " HOSTNAME
    echo "$HOSTNAME" > /etc/hostname
    {
        echo "127.0.0.1   localhost"
        echo "::1         localhost"
        echo "127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}"
    } >> /etc/hosts
}

# 2. Bootloader setup (GRUB)
setup_bootloader() {
    info "Installing and configuring GRUB bootloader..."
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH
    grub-mkconfig -o /boot/grub/grub.cfg
}

# 3. User creation and sudo configuration
create_user() {
    info "Creating user account..."
    
    # Set root password
    echo "root:${PASSWORD}" | chpasswd
    
    # Create user and set password
    useradd -m -g users -G wheel "$USERNAME"
    echo "${USERNAME}:${PASSWORD}" | chpasswd

    info "Configuring sudo for the wheel group..."
    # Allow users in the 'wheel' group to use sudo
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    
    info "User ${USERNAME} created."
}

# 4. Install desktop, drivers, fonts, IME and enable services
install_and_enable_services() {
    info "Installing graphic drivers..."
    pacman -S --noconfirm xorg-server mesa

    info "Installing Japanese fonts and Input Method (Fcitx5)..."
    pacman -S --noconfirm noto-fonts-cjk fcitx5-im fcitx5-mozc fcitx5-configtool

    info "Setting up Input Method environment variables..."[23]
    {
        echo "GTK_IM_MODULE=fcitx"
        echo "QT_IM_MODULE=fcitx"
        echo "XMODIFIERS=@im=fcitx"
    } >> /etc/environment
    
    info "Installing Desktop Environment and Display Manager..."
    pacman -S --noconfirm $DE_PACKAGES
    
    info "Enabling Display Manager
