#!/bin/bash
# chroot_config.sh - Configuration script to be run inside chroot

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Received Variables ---
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

# 1. System configuration
configure_system() {
    info "Setting timezone, locale, and hostname..."
    
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    hwclock --systohc

    sed -i "s/#${LOCALE_LANG}/${LOCALE_LANG}/" /etc/locale.gen
    sed -i "s/#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen
    echo "LANG=${LOCALE_LANG}" > /etc/locale.conf
    
    echo "KEYMAP=${VCONSOLE_KEYMAP}" > /etc/vconsole.conf

    read -p "Enter a hostname for your system: " HOSTNAME
    echo "$HOSTNAME" > /etc/hostname
    {
        echo "127.0.0.1   localhost"
        echo "::1         localhost"
        echo "127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}"
    } >> /etc/hosts
}

# 2. Bootloader setup
setup_bootloader() {
    info "Installing and configuring GRUB bootloader..."
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH
    grub-mkconfig -o /boot/grub/grub.cfg
}

# 3. User creation
create_user() {
    info "Creating user account..."
    
    echo "root:${PASSWORD}" | chpasswd
    useradd -m -g users -G wheel "$USERNAME"
    echo "${USERNAME}:${PASSWORD}" | chpasswd

    info "Configuring sudo for the wheel group..."
    sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    
    info "User ${USERNAME} created."
}

# 4. Install desktop, drivers and enable services
install_and_enable_services() {
    info "Installing graphic drivers..."
    pacman -S --noconfirm xorg-server mesa

    info "Installing Desktop Environment and Display Manager..."
    pacman -S --noconfirm $DE_PACKAGES
    
    info "Enabling Display Manager and NetworkManager..."
    systemctl enable "$DM.service"
    systemctl enable NetworkManager.service
}

# 5. Install yay and additional apps
install_additional_apps() {
    info "Installing yay (AUR Helper)..."
    sudo -u "$USERNAME" bash -c '
        cd /tmp
        git clone https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si --noconfirm
    '
    
    info "Installing Google Chrome..."
    sudo -u "$USERNAME" yay -S --noconfirm google-chrome

    if [ "$INSTALL_STEAM" == "true" ]; then
        info "Installing Steam..."
        # Enable multilib repository for steam
        sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
        pacman -Syu --noconfirm
        pacman -S --noconfirm steam
    fi

    if [ "$INSTALL_PROTONUP" == "true" ]; then
        info "Installing ProtonUp-Qt..."
        sudo -u "$USERNAME" yay -S --noconfirm protonup-qt
    fi
}

# 6. Configure autologin
configure_autologin() {
    if [ "$AUTOLOGIN" == "false" ]; then
        info "Autologin disabled."
        return
    fi

    info "Configuring autologin for ${DM}..."
    case $DM in
        "lightdm")
            sed -i "s/#autologin-user=/autologin-user=${USERNAME}/" /etc/lightdm/lightdm.conf
            sed -i "s/#autologin-session=/autologin-session=default/" /etc/lightdm/lightdm.conf
            ;;
        "gdm")
            echo -e "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=${USERNAME}" > /etc/gdm/custom.conf
            ;;
        "sddm")
            mkdir -p /etc/sddm.conf.d
            echo -e "[Autologin]\nUser=${USERNAME}\nSession=plasma.desktop" > /etc/sddm.conf.d/autologin.conf
            ;;
        *)
            echo "Warning: Autologin not configured for the selected display manager (${DM})."
            ;;
    esac
}

# --- Main Script Execution ---
main() {
    configure_system
    setup_bootloader
    create_user
    install_and_enable_services
    install_additional_apps
    configure_autologin
}

main
