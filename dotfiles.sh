#!/bin/bash

# スクリプトの動作を厳格にする
set -euo pipefail

# ==========================
# !!! WARNING !!!
# (省略: 元のスクリプトと同じ警告文)
# ==========================

# ==========================
# グローバル変数
# ==========================
CONFIG_FILE="arch_install_config.conf"

# 設定ファイルから読み込まれる変数 (デフォルト値を一部設定)
HOSTNAME_CONFIG="myarch"
TIMEZONE_CONFIG="Asia/Tokyo"
LOCALE_LANG_CONFIG="ja_JP.UTF-8"
KEYMAP_CONFIG="jp106"
REFLECTOR_COUNTRY_CODE="Japan"
SWAP_DEFAULT_SIZE="0"
DESKTOP_ENVIRONMENT="minimal"
DISPLAY_MANAGER_CONFIG="none"
AUTOLOGIN_USER_CONFIG=""
TERMINAL_PACKAGE_CONFIG=""
ADDITIONAL_UTILITY_PACKAGES_CONFIG=""
INSTALL_BASE_DEVEL="no"
TEXT_EDITOR="vim"

# スクリプト内でユーザー入力や処理により設定される変数
DISK=""
MAKE_SWAP_CHOICE="" # ユーザーのswap作成選択 (yes/no)
USER_SWAP_SIZE_INPUT="" # ユーザーが入力したswapサイズ (設定ファイル値をオーバーライド可能)
USERNAME=""
EFI_PARTITION_DEVICE=""
ROOT_PARTITION_DEVICE=""
SWAP_PARTITION_DEVICE="" # スワップを作成する場合に設定

# パッケージとサービス関連 (configure_environment_packagesで設定)
FINAL_PACKAGES_TO_INSTALL=""
FINAL_DM_SERVICE=""


# ==========================
# ヘルパー関数
# (省略: log_info, log_warn, log_error, check_command_status, cleanup は元のスクリプトと同じ)
# ==========================
log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[WARN]\033[0m $1" >&2 # 警告も標準エラー出力へ
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
}

check_command_status() {
    local status=$?
    local message=$1
    if [ $status -ne 0 ]; then
        log_error "Command failed: $message (Exit code: $status)"
        # cleanup関数がtrapで呼ばれる
        exit $status
    fi
}

cleanup() {
    log_info "Running cleanup..."
    # スワップをオフにする (存在すれば)
    if [ -n "$SWAP_PARTITION_DEVICE" ] && grep -q "$SWAP_PARTITION_DEVICE" /proc/swaps; then
        log_info "Turning off swap on $SWAP_PARTITION_DEVICE..."
        swapoff "$SWAP_PARTITION_DEVICE" || log_warn "Failed to turn off swap on $SWAP_PARTITION_DEVICE. Manual check may be needed."
    fi
    # マウントポイントをアンマウント (逆順で)
    if mountpoint -q /mnt/boot/efi; then
        log_info "Unmounting /mnt/boot/efi..."
        umount /mnt/boot/efi || log_warn "Failed to unmount /mnt/boot/efi. Manual check may be needed."
    fi
    if mountpoint -q /mnt; then
        log_info "Unmounting /mnt..."
        umount /mnt || log_warn "Failed to unmount /mnt. Manual check may be needed."
    fi
    log_info "Cleanup finished."
}

check_required_commands() {
    log_info "Checking for required commands..."
    local missing_cmds=0
    local commands_to_check=(
        sgdisk mkfs.fat mkfs.ext4 mkswap swapon mount umount
        pacstrap genfstab arch-chroot reflector timedatectl
        partprobe udevadm lsblk fdisk
    )
    for cmd in "${commands_to_check[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command '$cmd' not found."
            missing_cmds=$((missing_cmds + 1))
        fi
    done
    if [ $missing_cmds -gt 0 ]; then
        log_error "Please install missing commands or ensure you are in the Arch Linux live environment and try again."
        exit 1
    fi
    log_info "All required commands are present."
}

# ==========================
# 設定ファイル読み込み
# ==========================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# パッケージリスト生成
configure_environment_packages() {
    local base_pkgs="base linux grub efibootmgr sudo $TEXT_EDITOR"
    if [ "$INSTALL_BASE_DEVEL" = "yes" ]; then
        base_pkgs="$base_pkgs base-devel"
    fi
    FINAL_PACKAGES_TO_INSTALL="$base_pkgs"
    # 必要に応じて追加
    if [ -n "$ADDITIONAL_UTILITY_PACKAGES_CONFIG" ]; then
        FINAL_PACKAGES_TO_INSTALL="$FINAL_PACKAGES_TO_INSTALL $ADDITIONAL_UTILITY_PACKAGES_CONFIG"
    fi
}

# ==========================
# インストール処理関数
# ==========================

prompt_initial_settings() {
    log_info "Starting initial configuration (prompts will override $CONFIG_FILE values if provided)..."
    log_info "Available block devices:"
    lsblk -f
    echo "You can also use 'fdisk -l' for more details."
    echo "Enter the installation disk (e.g., /dev/sda, /dev/nvme0n1):"
    read -r DISK
    if [ ! -b "$DISK" ]; then
        log_error "The specified disk $DISK does not exist or is not a block device."
        exit 1
    fi

    echo "Do you want to create a swap partition? (yes/no) [Default: yes, if SWAP_DEFAULT_SIZE is not '0']"
    local default_swap_choice="yes"
    if [ "$SWAP_DEFAULT_SIZE" = "0" ]; then
        default_swap_choice="no"
    fi
    read -r user_swap_choice
    MAKE_SWAP_CHOICE="${user_swap_choice:-$default_swap_choice}"

    if [ "$MAKE_SWAP_CHOICE" = "yes" ]; then
        echo "Enter swap size (e.g., 2G, 8G). [Default from config: $SWAP_DEFAULT_SIZE, or 4G if config empty/invalid]"
        read -r user_swap_size_input
        # ユーザー入力があればそれを使い、なければ設定ファイルのSWAP_DEFAULT_SIZE、それも無効なら4G
        if [ -n "$user_swap_size_input" ]; then
            USER_SWAP_SIZE_INPUT="$user_swap_size_input"
        elif [[ "$SWAP_DEFAULT_SIZE" =~ ^[0-9]+[GM]$ ]]; then
            USER_SWAP_SIZE_INPUT="$SWAP_DEFAULT_SIZE"
        else
            USER_SWAP_SIZE_INPUT="4G"
        fi
        log_info "Swap partition will be created with size: $USER_SWAP_SIZE_INPUT"
    else
        USER_SWAP_SIZE_INPUT="" # スワップなし
        log_info "Swap partition will NOT be created."
    fi

    echo -n "Enter the username for the new system: "
    read -r USERNAME
    if [ -z "$USERNAME" ]; then
        log_error "Username cannot be empty."
        exit 1
    fi

    # Reflectorの国コードは設定ファイルから読み込むが、ここで上書きも可能にするか検討
    # echo "Enter the country code for reflector (e.g., JP, US, GB). [Current from config: $REFLECTOR_COUNTRY_CODE]"
    # read -r user_country_code_input
    # if [ -n "$user_country_code_input" ]; then REFLECTOR_COUNTRY_CODE="$user_country_code_input"; fi
    log_info "Reflector will use country: $REFLECTOR_COUNTRY_CODE"

    # AUTOLOGIN_USER_CONFIG が設定されていて、USERNAME と異なる場合は警告
    if [ -n "$AUTOLOGIN_USER_CONFIG" ] && [ "$AUTOLOGIN_USER_CONFIG" != "$USERNAME" ]; then
        log_warn "AUTOLOGIN_USER_CONFIG ('$AUTOLOGIN_USER_CONFIG') in $CONFIG_FILE differs from the entered username ('$USERNAME'). Autologin might not work as expected. It's recommended they are the same."
    fi
    log_info "Initial configuration complete."
}

configure_environment_packages() {
    log_info "Determining packages to install based on configuration..."
    local de_pkg_list=()
    local dm_pkg_list=() # display manager package(s)
    local terminal_pkg_list=()
    local common_gui_pkg_list=()
    local additional_pkg_list=()
    local final_pkg_candidate_list=() # 結合前のリスト

    # 1. Desktop Environment Packages
    case "$DESKTOP_ENVIRONMENT" in
        "lxqt") de_pkg_list+=("lxqt" "lxqt-config" "lxqt-session" "openbox" "pcmanfm-qt" "featherpad");;
        "gnome") de_pkg_list+=("gnome" "gnome-extra");;
        "kde") de_pkg_list+=("plasma" "plasma-wayland-session" "kde-applications");;
        "xfce") de_pkg_list+=("xfce4" "xfce4-goodies");;
        "minimal") ;; # No DE packages
        *) log_warn "Unsupported DESKTOP_ENVIRONMENT '$DESKTOP_ENVIRONMENT'. No specific DE packages will be installed.";;
    esac
    if [ ${#de_pkg_list[@]} -gt 0 ]; then final_pkg_candidate_list+=("${de_pkg_list[@]}"); fi

    # 2. Display Manager Package and Service
    FINAL_DM_SERVICE="" # Reset
    case "$DISPLAY_MANAGER_CONFIG" in
        "sddm") dm_pkg_list+=("sddm"); FINAL_DM_SERVICE="sddm.service";;
        "gdm")  dm_pkg_list+=("gdm");  FINAL_DM_SERVICE="gdm.service";;
        "lightdm") dm_pkg_list+=("lightdm" "lightdm-gtk-greeter"); FINAL_DM_SERVICE="lightdm.service";;
        "none") ;; # No DM
        *) log_warn "Unsupported DISPLAY_MANAGER_CONFIG '$DISPLAY_MANAGER_CONFIG'. No display manager will be installed.";;
    esac
    if [ ${#dm_pkg_list[@]} -gt 0 ]; then final_pkg_candidate_list+=("${dm_pkg_list[@]}"); fi

    # 3. Terminal Package
    if [ -n "$TERMINAL_PACKAGE_CONFIG" ]; then
        terminal_pkg_list+=("$TERMINAL_PACKAGE_CONFIG")
        final_pkg_candidate_list+=("${terminal_pkg_list[@]}")
    fi

    # 4. Common GUI Packages (if not minimal DE)
    if [ "$DESKTOP_ENVIRONMENT" != "minimal" ]; then
        common_gui_pkg_list+=("xorg-server" "xorg-xinit" "xorg-apps" "xf86-input-libinput" \
                              "ttf-dejavu" "ttf-liberation" "noto-fonts" "noto-fonts-cjk" \
                              "pipewire" "pipewire-pulse" "pavucontrol" \
                              "fcitx5" "fcitx5-mozc-ut" "fcitx5-configtool") # Added fcitx5-configtool
        final_pkg_candidate_list+=("${common_gui_pkg_list[@]}")
    fi

    # 5. Additional Utility Packages from config
    if [ -n "$ADDITIONAL_UTILITY_PACKAGES_CONFIG" ]; then
        # Convert string to array
        IFS=' ' read -r -a additional_pkg_array <<< "$ADDITIONAL_UTILITY_PACKAGES_CONFIG"
        if [ ${#additional_pkg_array[@]} -gt 0 ]; then
            additional_pkg_list+=("${additional_pkg_array[@]}")
            final_pkg_candidate_list+=("${additional_pkg_list[@]}")
        fi
    fi

    # Remove duplicates and convert to space-separated string
    if [ ${#final_pkg_candidate_list[@]} -gt 0 ]; then
        FINAL_PACKAGES_TO_INSTALL=$(echo "${final_pkg_candidate_list[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//') #末尾の空白削除
    else
        FINAL_PACKAGES_TO_INSTALL=""
    fi

    log_info "Packages to be installed (excluding base): ${FINAL_PACKAGES_TO_INSTALL:-None}"
    log_info "Display manager service to be enabled: ${FINAL_DM_SERVICE:-None}"
}


confirm_installation() {
    log_warn "--------------------------------------------------------------------"
    log_warn "Review your settings carefully:"
    log_warn "Installation Target Disk: $DISK"
    if [ "$MAKE_SWAP_CHOICE" = "yes" ]; then
        log_warn "Swap Partition: Will be created (Size: $USER_SWAP_SIZE_INPUT)"
    else
        log_warn "Swap Partition: Will NOT be created"
    fi
    log_warn "Username: $USERNAME"
    log_warn "--- From Configuration File ($CONFIG_FILE) ---"
    log_warn "Hostname: $HOSTNAME_CONFIG"
    log_warn "Timezone: $TIMEZONE_CONFIG"
    log_warn "Locale: $LOCALE_LANG_CONFIG"
    log_warn "Keymap: $KEYMAP_CONFIG"
    log_warn "Reflector Country: $REFLECTOR_COUNTRY_CODE"
    log_warn "Desktop Environment: $DESKTOP_ENVIRONMENT"
    log_warn "Display Manager: $DISPLAY_MANAGER_CONFIG (Service: ${FINAL_DM_SERVICE:-None})"
    if [ -n "$AUTOLOGIN_USER_CONFIG" ]; then
        log_warn "Autologin User: $AUTOLOGIN_USER_CONFIG (for $USERNAME)"
    else
        log_warn "Autologin: Disabled"
    fi
    log_warn "Default Terminal: ${TERMINAL_PACKAGE_CONFIG:-DE default or none}"
    log_warn "Additional Packages from config: ${ADDITIONAL_UTILITY_PACKAGES_CONFIG:-None}"
    log_warn ""
    log_warn "WARNING: ALL DATA ON $DISK WILL BE ERASED. THIS ACTION CANNOT BE UNDONE."
    log_warn "--------------------------------------------------------------------"
    echo "Are you sure you want to continue with the installation? (yes/no)"
    read -r confirmation
    if [ "$confirmation" != "yes" ]; then
        log_info "Installation aborted by user."
        exit 0
    fi
}

partition_disk() {
    log_info "Wiping existing partition table on $DISK..."
    sgdisk --zap-all "$DISK"; check_command_status "Failed to wipe partition table on $DISK."
    log_info "Creating new partitions on $DISK..."
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI_ARCH" "$DISK"; check_command_status "Failed to create EFI partition."
    if [ "$MAKE_SWAP_CHOICE" = "yes" ] && [ -n "$USER_SWAP_SIZE_INPUT" ]; then
        sgdisk -n 2:0:-${USER_SWAP_SIZE_INPUT} -t 2:8300 -c 2:"ROOT_ARCH" "$DISK"; check_command_status "Failed to create root partition."
        sgdisk -n 3:0:0 -t 3:8200 -c 3:"SWAP_ARCH" "$DISK"; check_command_status "Failed to create swap partition."
        SWAP_PARTITION_DEVICE="/dev/disk/by-partlabel/SWAP_ARCH"
    else
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT_ARCH" "$DISK"; check_command_status "Failed to create root partition."
        SWAP_PARTITION_DEVICE="" # Ensure it's empty
    fi
    EFI_PARTITION_DEVICE="/dev/disk/by-partlabel/EFI_ARCH"
    ROOT_PARTITION_DEVICE="/dev/disk/by-partlabel/ROOT_ARCH"
    log_info "Informing the OS of partition table changes..."
    partprobe "$DISK"; check_command_status "Failed to run partprobe on $DISK."
    udevadm settle; check_command_status "Failed to run udevadm settle."

    wait_for_partitions() { # (内容は前回のものと同様)
        log_info "Waiting for partitions to be recognized..."
        local retries=15
        local count=0
        while [ $count -lt $retries ]; do
            if [ -b "$EFI_PARTITION_DEVICE" ] && [ -b "$ROOT_PARTITION_DEVICE" ] && \
               { [ -z "$SWAP_PARTITION_DEVICE" ] || [ -b "$SWAP_PARTITION_DEVICE" ]; }; then
                log_info "Partitions recognized:"
                lsblk "$DISK"
                sleep 1
                return 0
            fi
            log_info "Still waiting for partitions... ($((count+1))/$retries)"
            sleep 2
            partprobe "$DISK"
            udevadm settle
            count=$((count+1))
        done
        log_error "Timeout waiting for partitions to be recognized."
        exit 1
    }
    wait_for_partitions
}

format_partitions() { # (内容は前回のものと同様、SWAP_PARTITION_DEVICE のチェックを修正)
    log_info "Formatting partitions..."
    log_info "Formatting EFI partition ($EFI_PARTITION_DEVICE) as FAT32..."
    mkfs.fat -F32 "$EFI_PARTITION_DEVICE"; check_command_status "Failed to format EFI partition."
    log_info "Formatting root partition ($ROOT_PARTITION_DEVICE) as ext4..."
    mkfs.ext4 -F "$ROOT_PARTITION_DEVICE"; check_command_status "Failed to format root partition."
    if [ "$MAKE_SWAP_CHOICE" = "yes" ] && [ -n "$SWAP_PARTITION_DEVICE" ]; then
        log_info "Formatting swap partition ($SWAP_PARTITION_DEVICE)..."
        mkswap "$SWAP_PARTITION_DEVICE"; check_command_status "Failed to format swap partition."
        log_info "Enabling swap on $SWAP_PARTITION_DEVICE..."
        swapon "$SWAP_PARTITION_DEVICE"; check_command_status "Failed to enable swap."
    fi
    log_info "Partition formatting complete."
}

mount_filesystems() { # (内容は前回のものと同様)
    log_info "Mounting filesystems..."
    mount "$ROOT_PARTITION_DEVICE" /mnt; check_command_status "Failed to mount root partition to /mnt."
    mkdir -p /mnt/boot/efi; check_command_status "Failed to create /mnt/boot/efi."
    mount "$EFI_PARTITION_DEVICE" /mnt/boot/efi; check_command_status "Failed to mount EFI partition to /mnt/boot/efi."
    log_info "Filesystems mounted."
}

install_base_system() { # (内容は前回のものと同様、Reflectorの国コードを修正)
    log_info "Setting up system clock..."
    timedatectl set-ntp true; check_command_status "Failed to set NTP."
    log_info "Optimizing pacman mirrorlist (this may take a moment)..."
    pacman -Sy reflector --noconfirm --needed; check_command_status "Failed to install reflector."
    # 国コードが空、または無効な形式でないか簡単なチェック（より厳密にはreflector --list-countriesの出力を利用）
    local country_for_reflector="$REFLECTOR_COUNTRY_CODE"
    if [ -z "$country_for_reflector" ]; then
        log_warn "Reflector country code is empty, defaulting to 'Japan'."
        country_for_reflector="Japan"
    fi
    reflector --country "$country_for_reflector" --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist; check_command_status "Failed to optimize mirrorlist with reflector."
    log_info "Mirrorlist optimized."
    log_info "Installing base system packages (pacstrap)..."
    pacstrap /mnt base base-devel linux linux-firmware grub efibootmgr networkmanager sudo git vim; check_command_status "Pacstrap failed to install base packages."
    log_info "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab; check_command_status "Failed to generate fstab."
    log_info "Base system installation complete."
}

generate_chroot_script() {
    log_info "Creating chroot setup script (/mnt/root/chroot-setup.sh)..."
    cat << CHROOT_SCRIPT_EOF > /mnt/root/chroot-setup.sh
#!/bin/bash
set -euo pipefail
# --- Helper Functions for chroot ---
# (省略: log_info_chroot, log_error_chroot, check_cmd_chroot は元のスクリプトと同じ)
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
USERNAME_CHROOT="${USERNAME}"
HOSTNAME_CHROOT="${HOSTNAME_CONFIG}"
TIMEZONE_CHROOT="${TIMEZONE_CONFIG}"
LOCALE_LANG_CHROOT="${LOCALE_LANG_CONFIG}"
KEYMAP_CHROOT="${KEYMAP_CONFIG}"
PACKAGES_TO_INSTALL_CHROOT="${FINAL_PACKAGES_TO_INSTALL}"
DM_SERVICE_CHROOT="${FINAL_DM_SERVICE}"
AUTOLOGIN_USER_CHROOT="${AUTOLOGIN_USER_CONFIG}" # Autologin user
DE_CHROOT="${DESKTOP_ENVIRONMENT}" # For SDDM autologin session

log_info_chroot "Synchronizing package databases..."
pacman -Syy --noconfirm; check_cmd_chroot "Failed to synchronize package databases." # -Syy推奨

# (タイムゾーン、ロケール、ホスト名、mkinitcpio、GRUB設定、ユーザー作成、パスワード設定、sudo設定は前回のスクリプトと同様)
log_info_chroot "Configuring timezone to \${TIMEZONE_CHROOT}..."
ln -sf /usr/share/zoneinfo/\${TIMEZONE_CHROOT} /etc/localtime; check_cmd_chroot "Failed to set timezone."
hwclock --systohc; check_cmd_chroot "Failed to set hardware clock."
log_info_chroot "Configuring locale (\${LOCALE_LANG_CHROOT})..."
sed -i "s/^#\(\${LOCALE_LANG_CHROOT}.*UTF-8\)/\1/" /etc/locale.gen; check_cmd_chroot "Failed to uncomment locale: \${LOCALE_LANG_CHROOT}"
sed -i "s/^#\(en_US.UTF-8 UTF-8\)/\1/" /etc/locale.gen; check_cmd_chroot "Failed to uncomment locale: en_US.UTF-8"
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

    # SDDM Autologin Configuration
    if [[ "\${DM_SERVICE_CHROOT}" == "sddm.service" ]] && [ -n "\${AUTOLOGIN_USER_CHROOT}" ]; then
        log_info_chroot "Configuring autologin for user \${AUTOLOGIN_USER_CHROOT} with SDDM..."
        mkdir -p /etc/sddm.conf.d
        local sddm_session_file=""
        case "\${DE_CHROOT}" in
            "lxqt") sddm_session_file="lxqt.desktop";;
            "gnome") sddm_session_file="gnome.desktop";; # Or gnome-xorg.desktop / gnome-wayland.desktop
            "kde") sddm_session_file="plasma.desktop";; # Or plasmawayland.desktop
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
    fi
else
    log_info_chroot "No display manager service selected to enable."
fi

# (AURヘルパーのインストールは、このスクリプトの範囲外とするか、別途オプション化を推奨)
# log_info_chroot "Setting up AUR helper (yay) ..."
# sudo -u "\${USERNAME_CHROOT}" bash -c '...'

log_info_chroot "Chroot setup complete."
CHROOT_SCRIPT_EOF
    check_command_status "Failed to create chroot setup script."
    chmod +x /mnt/root/chroot-setup.sh; check_command_status "Failed to make chroot setup script executable."
}

run_chroot_script() { # (内容は前回のものと同様)
    log_info "Entering chroot and running setup script..."
    arch-chroot /mnt /root/chroot-setup.sh; check_command_status "Chroot setup script execution failed."
    log_info "Chroot setup script finished."
}

finish_installation() { # (内容は前回のものと同様)
    log_info "Installation process finished."
    if [ -f /mnt/root/chroot-setup.sh ]; then
        rm /mnt/root/chroot-setup.sh
        log_info "Removed chroot setup script."
    fi
    echo "You can now unmount the partitions and reboot the system."
    echo "Do you want to unmount and reboot now? (yes/no)"
    read -r reboot_confirmation
    if [ "$reboot_confirmation" = "yes" ]; then
        cleanup
        log_info "Rebooting the system..."
        reboot
    else
        log_info "Please unmount the partitions manually and reboot when ready."
    fi
}

# ==========================
# メイン処理
# ==========================
main() {
    trap cleanup EXIT INT TERM
    check_required_commands
    load_config
    prompt_initial_settings
    configure_environment_packages
    confirm_installation
    partition_disk
    format_partitions
    mount_filesystems
    install_base_system
    generate_chroot_script
    run_chroot_script
    finish_installation
}

main "$@"
