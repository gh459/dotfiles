cat << CHROOT_SCRIPT_EOF > /mnt/root/chroot-setup.sh
#!/bin/bash
set -euo pipefail

# --- Helper Functions for chroot ---
log_info_chroot() { echo -e "\033[32m[CHROOT INFO]\033[0m \$1"; }
log_error_chroot() { echo -e "\033[31m[CHROOT ERROR]\033[0m \$1" >&2; }
check_cmd_chroot() {
    local status=\$?
    local message=\$1
    if [ \$status -ne 0 ]; then
        log_error_chroot "Command failed: \$message (Exit code: \$status)"
        exit \$status
    fi
}

# --- End Helper Functions ---

# Variables passed from the main script
USERNAME_CHROOT=${username_chroot_esc}
HOSTNAME_CHROOT=${hostname_chroot_esc}
TIMEZONE_CHROOT=${timezone_chroot_esc}
LOCALE_LANG_CHROOT=${locale_lang_chroot_esc}
KEYMAP_CHROOT=${keymap_chroot_esc}
PACKAGES_TO_INSTALL_CHROOT=${packages_to_install_chroot_esc}
DM_SERVICE_CHROOT=${dm_service_chroot_esc}
AUTOLOGIN_USER_CHROOT=${autologin_user_chroot_esc}
DE_CHROOT=${de_chroot_esc}
INSTALL_YAY_CHROOT=${install_yay_chroot_esc} # <<< chroot内で使用するyay選択変数

# <<< 拡張設定変数 >>>
PREFERRED_SHELL_CHROOT=${preferred_shell_chroot_esc}
INSTALL_OHMYZSH_CHROOT=${install_ohmyzsh_chroot_esc}
INSTALL_STEAM_CHROOT=${install_steam_chroot_esc}
INSTALL_PROTONUPQT_CHROOT=${install_protonupqt_chroot_esc}
INSTALL_CHROME_CHROOT=${install_chrome_chroot_esc}
ENABLE_FIREWALLD_CHROOT=${enable_firewalld_chroot_esc}
ENABLE_BLUETOOTH_CHROOT=${enable_bluetooth_chroot_esc}
ENABLE_CUPS_CHROOT=${enable_cups_chroot_esc}

log_info_chroot "Synchronizing package databases..."
pacman -Syy --noconfirm; check_cmd_chroot "Failed to synchronize package databases."

log_info_chroot "Configuring timezone to \${TIMEZONE_CHROOT}..."
ln -sf /usr/share/zoneinfo/\${TIMEZONE_CHROOT} /etc/localtime; check_cmd_chroot "Failed to set timezone."
hwclock --systohc; check_cmd_chroot "Failed to set hardware clock."

log_info_chroot "Configuring locale (\${LOCALE_LANG_CHROOT})..."
sed -i "s/^#\(\${LOCALE_LANG_CHROOT}.*UTF-8\)/\1/" /etc/locale.gen; check_cmd_chroot "Failed to uncomment locale: \${LOCALE_LANG_CHROOT}"
sed -i "s/^#\(en_US.UTF-8 UTF-8\)/\1/" /etc/locale.gen; check_cmd_chroot "Failed to uncomment locale: en_US.UTF-8" # Ensure en_US is also available as a fallback
locale-gen; check_cmd_chroot "locale-gen failed."
echo "LANG=\${LOCALE_LANG_CHROOT}" > /etc/locale.conf
echo "KEYMAP=\${KEYMAP_CHROOT}" > /etc/vconsole.conf

log_info_chroot "Configuring hostname to \${HOSTNAME_CHROOT}..."
echo "\${HOSTNAME_CHROOT}" > /etc/hostname
cat << HOSTS_EOF_INNER > /etc/hosts
127.0.0.1 localhost
::1 localhost
127.0.1.1 \${HOSTNAME_CHROOT}.localdomain \${HOSTNAME_CHROOT}
HOSTS_EOF_INNER
check_cmd_chroot "Failed to configure /etc/hosts."

log_info_chroot "Generating initramfs (mkinitcpio)..."
mkinitcpio -P; check_cmd_chroot "mkinitcpio -P failed."

log_info_chroot "Installing GRUB bootloader..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck; check_cmd_chroot "grub-install failed."
log_info_chroot "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg; check_cmd_chroot "grub-mkconfig failed."

log_info_chroot "Creating user \${USERNAME_CHROOT}..."
useradd -m -G wheel -s /bin/bash "\${USERNAME_CHROOT}"; check_cmd_chroot "Failed to create user \${USERNAME_CHROOT}."
log_info_chroot "Setting password for user \${USERNAME_CHROOT}..."
echo "Please enter the password for user \${USERNAME_CHROOT}:"
passwd "\${USERNAME_CHROOT}"; check_cmd_chroot "Failed to set password for user \${USERNAME_CHROOT}."

log_info_chroot "Configuring sudo for wheel group (using /etc/sudoers.d/)..."
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/01_wheel_sudo; check_cmd_chroot "Failed to configure sudoers.d for wheel group."
chmod 0440 /etc/sudoers.d/01_wheel_sudo

log_info_chroot "Installing DE, DM, Terminal, and additional packages..."
if [ -n "\${PACKAGES_TO_INSTALL_CHROOT}" ]; then
    pacman -S --noconfirm --needed \${PACKAGES_TO_INSTALL_CHROOT}; check_cmd_chroot "Failed to install selected packages."
else
    log_info_chroot "No extra DE/DM/Terminal/Utility packages selected to install."
fi

log_info_chroot "Enabling essential services (NetworkManager)..."
systemctl enable NetworkManager; check_cmd_chroot "Failed to enable NetworkManager service."

if [ -n "\${DM_SERVICE_CHROOT}" ]; then
    log_info_chroot "Enabling display manager service: \${DM_SERVICE_CHROOT}..."
    systemctl enable "\${DM_SERVICE_CHROOT}"; check_cmd_chroot "Failed to enable \${DM_SERVICE_CHROOT} service."
    if [[ "\${DM_SERVICE_CHROOT}" == "sddm.service" ]] && [ -n "\${AUTOLOGIN_USER_CHROOT}" ] && [ "\${AUTOLOGIN_USER_CHROOT}" == "\${USERNAME_CHROOT}" ]; then
        log_info_chroot "Configuring autologin for user \${AUTOLOGIN_USER_CHROOT} with SDDM..."
        mkdir -p /etc/sddm.conf.d
        local sddm_session_file=""
        case "\${DE_CHROOT}" in
            "lxqt") sddm_session_file="lxqt.desktop";;
            "gnome") sddm_session_file="gnome.desktop";;
            "kde") sddm_session_file="plasma.desktop";;
            "xfce") sddm_session_file="xfce.desktop";;
            *) log_info_chroot "Warning: Could not determine SDDM session for DE '\${DE_CHROOT}'. Autologin might require manual session setting.";;
        esac
        if [ -n "\$sddm_session_file" ]; then
            echo -e "[Autologin]\nUser=\${AUTOLOGIN_USER_CHROOT}\nSession=\${sddm_session_file}" > /etc/sddm.conf.d/autologin.conf
            check_cmd_chroot "Failed to write SDDM autologin configuration."
            log_info_chroot "SDDM autologin configured for session: \${sddm_session_file}"
        else
            echo -e "[Autologin]\nUser=\${AUTOLOGIN_USER_CHROOT}" > /etc/sddm.conf.d/autologin.conf
            log_info_chroot "SDDM autologin configured for user \${AUTOLOGIN_USER_CHROOT}, session may need to be chosen on first login or set manually."
        fi
    elif [ -n "\${AUTOLOGIN_USER_CHROOT}" ] && [ "\${AUTOLOGIN_USER_CHROOT}" != "\${USERNAME_CHROOT}" ]; then
        log_info_chroot "Warning: AUTOLOGIN_USER_CHROOT (\${AUTOLOGIN_USER_CHROOT}) does not match current user (\${USERNAME_CHROOT}). SDDM Autologin not configured for this discrepancy."
    fi
else
    log_info_chroot "No display manager service selected to enable."
fi

# <<< シェルの設定 (PREFERRED_SHELL_CHROOT) >>>
if [ -n "\${PREFERRED_SHELL_CHROOT}" ] && [ "\${PREFERRED_SHELL_CHROOT}" != "bash" ]; then
    log_info_chroot "Installing preferred shell: \${PREFERRED_SHELL_CHROOT}..."
    pacman -S --noconfirm --needed "\${PREFERRED_SHELL_CHROOT}"; check_cmd_chroot "Failed to install \${PREFERRED_SHELL_CHROOT}."
    log_info_chroot "Changing default shell for user \${USERNAME_CHROOT} to \${PREFERRED_SHELL_CHROOT}..."
    chsh -s /usr/bin/\${PREFERRED_SHELL_CHROOT} "\${USERNAME_CHROOT}"; check_cmd_chroot "Failed to change shell to \${PREFERRED_SHELL_CHROOT} for user \${USERNAME_CHROOT}."

    # <<< Oh My Zsh のインストール (Zshの場合) >>>
    if [ "\${PREFERRED_SHELL_CHROOT}" == "zsh" ] && [ "\${INSTALL_OHMYZSH_CHROOT}" == "yes" ]; then
        log_info_chroot "Installing Oh My Zsh for user \${USERNAME_CHROOT}..."
        sudo -u "\${USERNAME_CHROOT}" bash -c '
            if [ ! -d "/home/\${USERNAME_CHROOT}/.oh-my-zsh" ]; then
                git clone https://github.com/ohmyzsh/ohmyzsh.git /home/\${USERNAME_CHROOT}/.oh-my-zsh
                chsh -s /usr/bin/zsh
                cp /home/\${USERNAME_CHROOT}/.oh-my-zsh/templates/zshrc.zsh-template /home/\${USERNAME_CHROOT}/.zshrc
                chown -R "\${USERNAME_CHROOT}:\${USERNAME_CHROOT}" /home/\${USERNAME_CHROOT}/.oh-my-zsh /home/\${USERNAME_CHROOT}/.zshrc
            fi
        '; check_cmd_chroot "Failed to install Oh My Zsh for user \${USERNAME_CHROOT}."
    fi
fi

# <<< サービスの有効化 >>>
if [ "\${ENABLE_FIREWALLD_CHROOT}" == "yes" ]; then
    log_info_chroot "Enabling firewalld service..."
    systemctl enable firewalld; check_cmd_chroot "Failed to enable firewalld service."
fi

if [ "\${ENABLE_BLUETOOTH_CHROOT}" == "yes" ]; then
    log_info_chroot "Enabling bluetooth service..."
    systemctl enable bluetooth; check_cmd_chroot "Failed to enable bluetooth service."
fi

if [ "\${ENABLE_CUPS_CHROOT}" == "yes" ]; then
    log_info_chroot "Enabling cups service..."
    systemctl enable cups; check_cmd_chroot "Failed to enable cups service."
fi

# <<< yayのインストール >>>
if [ "\${INSTALL_YAY_CHROOT}" = "yes" ]; then
    log_info_chroot "Attempting to install AUR helper (yay) for user \${USERNAME_CHROOT}..."
    sudo -u "\${USERNAME_CHROOT}" bash -ec '
        echo "[YAY_INSTALL INFO] Starting yay installation as user: $(whoami)"
        build_dir="/home/$(whoami)/yay_build_temp_$(date +%s)"
        mkdir -p "${build_dir}"
        cd "${build_dir}" || { echo "[YAY_INSTALL ERROR] Failed to cd to ${build_dir}."; exit 1; }
        echo "[YAY_INSTALL INFO] Cloning yay from AUR (https://aur.archlinux.org/yay.git) into ${build_dir}..."
        git clone https://aur.archlinux.org/yay.git || { echo "[YAY_INSTALL ERROR] Failed to clone yay repository."; exit 1; }
        cd yay || { echo "[YAY_INSTALL ERROR] Failed to cd into yay directory."; exit 1; }
        echo "[YAY_INSTALL INFO] Building and installing yay (makepkg -si --noconfirm)..."
        makepkg -si --noconfirm || { echo "[YAY_INSTALL ERROR] makepkg -si for yay failed."; exit 1; }
        echo "[YAY_INSTALL INFO] yay installed successfully."
        cd /home/$(whoami) || { echo "[YAY_INSTALL WARN] Could not cd to home for cleanup, build dir ${build_dir} may remain."; exit 0; }
        rm -rf "${build_dir}"
        echo "[YAY_INSTALL INFO] Cleaned up yay build directory: ${build_dir}."
    '
    check_cmd_chroot "yay installation process for user \${USERNAME_CHROOT} failed."

    # <<< ProtonUp-QtとGoogle Chromeのインストール (yay経由) >>>
    if [ "\${INSTALL_PROTONUPQT_CHROOT}" = "yes" ]; then
        log_info_chroot "Installing ProtonUp-Qt for user \${USERNAME_CHROOT} via yay..."
        sudo -u "\${USERNAME_CHROOT}" yay -S --noconfirm --needed protonup-qt
        check_cmd_chroot "Failed to install ProtonUp-Qt via yay."
        log_info_chroot "ProtonUp-Qt installed."
    else
        log_info_chroot "Skipping ProtonUp-Qt installation as per user choice or yay not installed."
    fi

    if [ "\${INSTALL_CHROME_CHROOT}" = "yes" ]; then
        log_info_chroot "Installing Google Chrome for user \${USERNAME_CHROOT} via yay..."
        sudo -u "\${USERNAME_CHROOT}" yay -S --noconfirm --needed google-chrome
        check_cmd_chroot "Failed to install Google Chrome via yay."
        log_info_chroot "Google Chrome installed."
    else
        log_info_chroot "Skipping Google Chrome installation as per user choice or yay not installed."
    fi
else
    log_info_chroot "Skipping yay installation as per user choice."
    if [ "\${INSTALL_PROTONUPQT_CHROOT}" = "yes" ] || [ "\${INSTALL_CHROME_CHROOT}" = "yes" ]; then
        log_info_chroot "Skipping ProtonUp-Qt/Google Chrome installation as yay was not selected to be installed."
    fi
fi

# <<< Steamのインストール (yay経由) >>>
if [ "\${INSTALL_STEAM_CHROOT}" = "yes" ]; then
     log_info_chroot "Installing Steam"
     pacman -S --noconfirm --needed steam; check_cmd_chroot "Failed to install steam."
     log_info_chroot "Steam installed"
fi

log_info_chroot "Chroot setup complete. Exiting chroot environment."
CHROOT_SCRIPT_EOF
