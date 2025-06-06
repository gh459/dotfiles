#!/bin/bash
# chroot_config.sh - Configuration script to be run inside chroot (Revised)

# (スクリプトの冒頭部分は変更なし)
# ...

# --- Helper Functions ---
info() {
    echo -e "\e[32m[CHROOT-INFO]\e[0m $1"
}

# (configure_system, setup_bootloader, create_user関数は変更なし)
# ...

# 4. Install desktop, drivers, fonts, IME and enable services
install_and_enable_services() {
    info "Installing graphic drivers..."
    pacman -S --noconfirm xorg-server mesa

    info "Installing Japanese fonts and Input Method (Fcitx5)..."
    pacman -S --noconfirm noto-fonts-cjk fcitx5-im fcitx5-mozc fcitx5-configtool

    info "Setting up Input Method environment variables..."
    {
        echo "GTK_IM_MODULE=fcitx"
        echo "QT_IM_MODULE=fcitx"
        echo "XMODIFIERS=@im=fcitx"
    } >> /etc/environment
    
    info "Installing Desktop Environment and Display Manager..."
    pacman -S --noconfirm $DE_PACKAGES
    
    info "Enabling Display Manager and NetworkManager..."
    systemctl enable "$DM.service"
    systemctl enable NetworkManager.service
}

# (install_additional_apps, configure_autologin関数は変更なし)
# ...

# --- Main Script Execution ---
main() {
    configure_system
    setup_bootloader
    create_user
    install_and_enable_services # This function is now updated
    install_additional_apps
    configure_autologin
}

main
