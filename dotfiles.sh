#!/bin/bash

set -euo pipefail # スクリプトの堅牢性を高める設定

# --- Helper Functions for chroot ---

log_info_chroot() {
    echo -e "\033[32m[CHROOT INFO]\033[0m $1"
}

log_error_chroot() {
    echo -e "\033[31m[CHROOT ERROR]\033[0m $1" >&2
}

check_cmd_chroot() {
    local status=$? # 直前のコマンドの終了ステータスを取得
    local message=$1
    if [ $status -ne 0 ]; then
        log_error_chroot "Command failed: $message (Exit code: $status)"
        exit $status
    fi
} # 関数定義の閉じ括弧を追加

# --- End Helper Functions ---

# Variables passed from the main script (placeholders, should be properly escaped and passed)
USERNAME_CHROOT=${username_chroot_esc:-archuser}
HOSTNAME_CHROOT=${hostname_chroot_esc:-archlinux}
TIMEZONE_CHROOT=${timezone_chroot_esc:-UTC}
LOCALE_LANG_CHROOT=${locale_lang_chroot_esc:-en_US.UTF-8}
KEYMAP_CHROOT=${keymap_chroot_esc:-us}
PACKAGES_TO_INSTALL_CHROOT="${packages_to_install_chroot_esc}" # Ensure it's treated as a string
DM_SERVICE_CHROOT="${dm_service_chroot_esc}"
AUTOLOGIN_USER_CHROOT="${autologin_user_chroot_esc}"
DE_CHROOT="${de_chroot_esc}"
INSTALL_YAY_CHROOT=${install_yay_chroot_esc:-no}
PREFERRED_SHELL_CHROOT=${preferred_shell_chroot_esc:-bash}
INSTALL_OHMYZSH_CHROOT=${install_ohmyzsh_chroot_esc:-no}
INSTALL_STEAM_CHROOT=${install_steam_chroot_esc:-no}
INSTALL_PROTONUPQT_CHROOT=${install_protonupqt_chroot_esc:-no}
INSTALL_CHROME_CHROOT=${install_chrome_chroot_esc:-no}
ENABLE_FIREWALLD_CHROOT=${enable_firewalld_chroot_esc:-no}
ENABLE_BLUETOOTH_CHROOT=${enable_bluetooth_chroot_esc:-no}
ENABLE_CUPS_CHROOT=${enable_cups_chroot_esc:-no}

log_info_chroot "Starting chroot setup script..."

log_info_chroot "Synchronizing package databases..."
pacman -Syy --noconfirm; check_cmd_chroot "Failed to synchronize package databases."

log_info_chroot "Installing essential development tools: base-devel and git..."
pacman -S --noconfirm --needed base-devel git; check_cmd_chroot "Failed to install base-devel and git." # [5]

log_info_chroot "Configuring timezone to ${TIMEZONE_CHROOT}..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE_CHROOT}" /etc/localtime; check_cmd_chroot "Failed to set timezone." # [2]
hwclock --systohc; check_cmd_chroot "Failed to set hardware clock." # [2]

log_info_chroot "Configuring locale (${LOCALE_LANG_CHROOT})..."
sed -i "s/^#\(${LOCALE_LANG_CHROOT}.*UTF-8\)/\1/" /etc/locale.gen; check_cmd_chroot "Failed to uncomment locale: ${LOCALE_LANG_CHROOT}"
if [[ "${LOCALE_LANG_CHROOT}" != "en_US.UTF-8" ]]; then # en_US.UTF-8は多くの場合デフォルトで必要
    sed -i "s/^#\(en_US.UTF-8 UTF-8\)/\1/" /etc/locale.gen; check_cmd_chroot "Failed to uncomment locale: en_US.UTF-8"
fi
locale-gen; check_cmd_chroot "locale-gen failed."
echo "LANG=${LOCALE_LANG_CHROOT}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP_CHROOT}" > /etc/vconsole.conf

log_info_chroot "Configuring hostname to ${HOSTNAME_CHROOT}..."
echo "${HOSTNAME_CHROOT}" > /etc/hostname # [3]
cat << HOSTS_EOF_INNER > /etc/hosts
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME_CHROOT}.localdomain ${HOSTNAME_CHROOT}
HOSTS_EOF_INNER
check_cmd_chroot "Failed to configure /etc/hosts." # [3]

log_info_chroot "Generating initramfs (mkinitcpio)..."
mkinitcpio -P; check_cmd_chroot "mkinitcpio -P failed."

log_info_chroot "Installing GRUB bootloader..."
# EFIディレクトリは環境に合わせて調整が必要な場合がある
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck; check_cmd_chroot "grub-install failed." # [2]

log_info_chroot "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg; check_cmd_chroot "grub-mkconfig failed." # [2]

log_info_chroot "Creating user ${USERNAME_CHROOT}..."
useradd -m -G wheel -s /bin/bash "${USERNAME_CHROOT}"; check_cmd_chroot "Failed to create user ${USERNAME_CHROOT}."

log_info_chroot "Setting password for user ${USERNAME_CHROOT}..."
echo "Please enter the password for user ${USERNAME_CHROOT} in the chroot environment:"
passwd "${USERNAME_CHROOT}"; # ここではcheck_cmd_chrootを使わない（対話的なため終了ステータスが異なる可能性）

log_info_chroot "Configuring sudo for wheel group (using /etc/sudoers.d/)..."
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/01_wheel_sudo; check_cmd_chroot "Failed to configure sudoers.d for wheel group."
chmod 0440 /etc/sudoers.d/01_wheel_sudo

log_info_chroot "Installing DE, DM, Terminal, and additional packages..."
if [ -n "${PACKAGES_TO_INSTALL_CHROOT}" ]; then
    pacman -S --noconfirm --needed ${PACKAGES_TO_INSTALL_CHROOT}; check_cmd_chroot "Failed to install selected packages."
else
    log_info_chroot "No extra DE/DM/Terminal/Utility packages selected to install."
fi

log_info_chroot "Enabling essential services (NetworkManager)..."
systemctl enable NetworkManager; check_cmd_chroot "Failed to enable NetworkManager service." # [2]

if [ -n "${DM_SERVICE_CHROOT}" ] && [ "${DM_SERVICE_CHROOT}" != "none" ]; then
    log_info_chroot "Enabling display manager service: ${DM_SERVICE_CHROOT}..."
    systemctl enable "${DM_SERVICE_CHROOT}"; check_cmd_chroot "Failed to enable ${DM_SERVICE_CHROOT} service."

    if [[ "${DM_SERVICE_CHROOT}" == "sddm.service" ]] && [ -n "${AUTOLOGIN_USER_CHROOT}" ] && [ "${AUTOLOGIN_USER_CHROOT}" == "${USERNAME_CHROOT}" ]; then
        log_info_chroot "Configuring autologin for user ${AUTOLOGIN_USER_CHROOT} with SDDM..."
        mkdir -p /etc/sddm.conf.d
        sddm_session_file="" # localを削除
        case "${DE_CHROOT}" in
            "lxqt") sddm_session_file="lxqt.desktop";;
            "gnome") sddm_session_file="gnome.desktop";;
            "kde") sddm_session_file="plasma.desktop";; # KDE Plasmaの場合はplasma.desktop
            "xfce") sddm_session_file="xfce.desktop";;
            *) log_info_chroot "Warning: Could not determine SDDM session for DE '${DE_CHROOT}'. Autologin might require manual session setting.";;
        esac
        if [ -n "$sddm_session_file" ]; then
            echo -e "[Autologin]\nUser=${AUTOLOGIN_USER_CHROOT}\nSession=${sddm_session_file}" > /etc/sddm.conf.d/autologin.conf
            check_cmd_chroot "Failed to write SDDM autologin configuration."
            log_info_chroot "SDDM autologin configured for session: ${sddm_session_file}"
        else
            echo -e "[Autologin]\nUser=${AUTOLOGIN_USER_CHROOT}" > /etc/sddm.conf.d/autologin.conf
            log_info_chroot "SDDM autologin configured for user ${AUTOLOGIN_USER_CHROOT}, session may need to be chosen on first login or set manually."
        fi
    elif [ -n "${AUTOLOGIN_USER_CHROOT}" ] && [ "${AUTOLOGIN_USER_CHROOT}" != "${USERNAME_CHROOT}" ]; then
        log_info_chroot "Warning: AUTOLOGIN_USER_CHROOT (${AUTOLOGIN_USER_CHROOT}) does not match current user (${USERNAME_CHROOT}). SDDM Autologin not configured for this discrepancy."
    fi
else
    log_info_chroot "No display manager service selected to enable."
fi

# Preferred shell setup
if [ -n "${PREFERRED_SHELL_CHROOT}" ] && [ "/bin/${PREFERRED_SHELL_CHROOT}" != "/bin/bash" ]; then
    log_info_chroot "Installing preferred shell: ${PREFERRED_SHELL_CHROOT}..."
    pacman -S --noconfirm --needed "${PREFERRED_SHELL_CHROOT}"; check_cmd_chroot "Failed to install ${PREFERRED_SHELL_CHROOT}." # [3]

    log_info_chroot "Changing default shell for user ${USERNAME_CHROOT} to /usr/bin/${PREFERRED_SHELL_CHROOT}..."
    chsh -s "/usr/bin/${PREFERRED_SHELL_CHROOT}" "${USERNAME_CHROOT}"; check_cmd_chroot "Failed to change shell to ${PREFERRED_SHELL_CHROOT} for user ${USERNAME_CHROOT}." # [3]
fi

# Oh My Zsh installation (if zsh is the preferred shell)
if [ "${PREFERRED_SHELL_CHROOT}" == "zsh" ] && [ "${INSTALL_OHMYZSH_CHROOT}" == "yes" ]; then
    log_info_chroot "Installing Oh My Zsh for user ${USERNAME_CHROOT}..."
    # sudo -u で実行するユーザーの $HOME を使うように修正
    sudo -u "${USERNAME_CHROOT}" bash -c '
        set -e # エラー時にスクリプトを終了
        if [ ! -d "$HOME/.oh-my-zsh" ]; then
            echo "Cloning Oh My Zsh..."
            git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh" >/dev/null 2>&1 # [3] [5]
            echo "Copying .zshrc template..."
            cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
            echo "Oh My Zsh installed."
        else
            echo "Oh My Zsh is already installed."
        fi
    '; check_cmd_chroot "Failed to install Oh My Zsh for user ${USERNAME_CHROOT}." # check_cmd_chrootはsudoの外
fi

# Enable additional services
if [ "${ENABLE_FIREWALLD_CHROOT}" == "yes" ]; then
    log_info_chroot "Enabling firewalld service..."
    systemctl enable firewalld; check_cmd_chroot "Failed to enable firewalld service."
fi

if [ "${ENABLE_BLUETOOTH_CHROOT}" == "yes" ]; then
    log_info_chroot "Enabling bluetooth service..."
    # bluetoothパッケージのインストールが必要な場合がある
    pacman -S --noconfirm --needed bluez bluez-utils
    systemctl enable bluetooth; check_cmd_chroot "Failed to enable bluetooth service."
fi

if [ "${ENABLE_CUPS_CHROOT}" == "yes" ]; then
    log_info_chroot "Enabling cups service..."
    # cupsパッケージのインストールが必要
    pacman -S --noconfirm --needed cups
    systemctl enable cups.service; check_cmd_chroot "Failed to enable cups service." # cups.service が一般的
fi

# yay installation
if [ "${INSTALL_YAY_CHROOT}" = "yes" ]; then
    log_info_chroot "Attempting to install AUR helper (yay) for user ${USERNAME_CHROOT}..."
    # yayのビルドには base-devel と git が必要 (既にインストール済みのはず)
    # sudo -u で実行。サブシェル内の check_cmd_chroot は削除。
    sudo -u "${USERNAME_CHROOT}" bash -ec '
        echo "[YAY_INSTALL INFO] Starting yay installation as user: $(whoami)"
        # 一時ビルドディレクトリをユーザーのホームに作成
        build_dir_name="yay_build_temp_$(date +%s)"
        build_dir="$HOME/${build_dir_name}"

        mkdir -p "${build_dir}"
        cd "${build_dir}" || { echo "[YAY_INSTALL ERROR] Failed to cd to ${build_dir}."; exit 1; }

        echo "[YAY_INSTALL INFO] Cloning yay from AUR (https://aur.archlinux.org/yay.git) into ${build_dir}..."
        git clone --depth=1 https://aur.archlinux.org/yay.git || { echo "[YAY_INSTALL ERROR] Failed to clone yay repository."; exit 1; } # [3] [5]

        cd yay || { echo "[YAY_INSTALL ERROR] Failed to cd into yay directory."; exit 1; }

        echo "[YAY_INSTALL INFO] Building and installing yay (makepkg -si --noconfirm --needed)..."
        makepkg -si --noconfirm --needed || { echo "[YAY_INSTALL ERROR] makepkg -si for yay failed."; exit 1; } # [3]

        echo "[YAY_INSTALL INFO] yay installed successfully."

        cd "$HOME" || echo "[YAY_INSTALL WARN] Could not cd to home for cleanup, build dir ${build_dir} may remain."
        rm -rf "${build_dir}"
        echo "[YAY_INSTALL INFO] Cleaned up yay build directory: ${build_dir}."
    '; check_cmd_chroot "yay installation process for user ${USERNAME_CHROOT} failed." # check_cmd_chroot は sudo の外側

    # ProtonUp-Qt and Google Chrome installation via yay
    if [ "${INSTALL_PROTONUPQT_CHROOT}" = "yes" ]; then
        log_info_chroot "Installing ProtonUp-Qt for user ${USERNAME_CHROOT} via yay..."
        sudo -u "${USERNAME_CHROOT}" yay -S --noconfirm --needed protonup-qt
        check_cmd_chroot "Failed to install ProtonUp-Qt via yay."
        log_info_chroot "ProtonUp-Qt installed."
    fi

    if [ "${INSTALL_CHROME_CHROOT}" = "yes" ]; then
        log_info_chroot "Installing Google Chrome for user ${USERNAME_CHROOT} via yay..."
        sudo -u "${USERNAME_CHROOT}" yay -S --noconfirm --needed google-chrome
        check_cmd_chroot "Failed to install Google Chrome via yay."
        log_info_chroot "Google Chrome installed."
    fi
else
    log_info_chroot "Skipping yay installation as per user choice."
    if [ "${INSTALL_PROTONUPQT_CHROOT}" = "yes" ] || [ "${INSTALL_CHROME_CHROOT}" = "yes" ]; then
        log_info_chroot "Skipping ProtonUp-Qt/Google Chrome installation as yay was not selected to be installed."
    fi
fi

# Steam installation (via pacman)
# Steamのインストールにはmultilibリポジトリの有効化が必要 [2]
# これは /etc/pacman.conf の編集を伴うため、このchrootスクリプトより前の段階で設定されている想定
if [ "${INSTALL_STEAM_CHROOT}" = "yes" ]; then
    log_info_chroot "Checking if multilib repository is enabled for Steam..."
    if grep -q "^\s*\[multilib\]" /etc/pacman.conf && grep -A1 "^\s*\[multilib\]" /etc/pacman.conf | grep -q "^\s*Include = /etc/pacman.d/mirrorlist"; then
        log_info_chroot "Multilib repository appears to be enabled. Installing Steam..."
        pacman -S --noconfirm --needed steam lib32-mesa; check_cmd_chroot "Failed to install steam and lib32-mesa." # [2]
        # 必要に応じて他の lib32-* パッケージも追加
        log_info_chroot "Steam installed."
    else
        log_error_chroot "Multilib repository is not enabled in /etc/pacman.conf. Steam installation aborted. Please enable it first."
        # exit 1; # 必要ならここでスクリプトを中断
    fi
fi

log_info_chroot "Chroot setup complete. You should exit chroot and unmount filesystems before rebooting."
exit 0
