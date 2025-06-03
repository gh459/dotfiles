#!/bin/bash

# スクリプトの動作を厳格にする
# -e: コマンドがエラーになったら即座に終了
# -u: 未定義変数を参照したらエラー
# -o pipefail: パイプライン中のコマンドが失敗したら、パイプライン全体の終了ステータスをそのコマンドのものにする
set -euo pipefail

# ==========================
# グローバル設定変数
# ==========================
HOSTNAME_CONFIG="myarch"
TIMEZONE_CONFIG="Asia/Tokyo"
LOCALE_LANG_CONFIG="ja_JP.UTF-8"
KEYMAP_CONFIG="jp106"

# インストールする追加パッケージ
EXTRA_PACKAGES_CONFIG="xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-config lxqt-policykit lxqt-session lxqt-admin \
openbox pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts noto-fonts-cjk pipewire pipewire-pulse pavucontrol fcitx5 fcitx5-mozc-ut steam"

# GPTパーティションラベル名
EFI_PARTITION_NAME="ESP_ARCH" # 一意性を高めるため、少し変更
ROOT_PARTITION_NAME="ROOT_ARCH"
SWAP_PARTITION_NAME="SWAP_ARCH"

# グローバル変数（スクリプト内で設定される）
DISK=""
MAKE_SWAP=""
SWAP_SIZE=""
USERNAME=""
PASSWORD=""

EFI_PARTITION_DEVICE=""
ROOT_PARTITION_DEVICE=""
SWAP_PARTITION_DEVICE="" # スワップを作成する場合に設定

# ==========================
# ヘルパー関数
# ==========================

log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[WARN]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
}

# コマンドの終了ステータスを確認し、エラーならメッセージを表示して終了
check_command_status() {
    local status=$?
    local message=$1
    if [ $status -ne 0 ]; then
        log_error "Command failed: $message (Exit code: $status)"
        # cleanup関数がtrapで呼ばれる
        exit $status
    fi
}

# スクリプト終了時に実行されるクリーンアップ処理
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

# ==========================
# インストール処理関数
# ==========================

# 初期設定値の入力と確認
prompt_initial_settings() {
    log_info "Starting initial configuration..."
    echo "Enter the installation disk (e.g., /dev/sda, /dev/nvme0n1):"
    read -r DISK
    if [ ! -b "$DISK" ]; then
        log_error "The specified disk $DISK does not exist or is not a block device."
        exit 1
    fi

    echo "Do you want to create a swap partition? (yes/no)"
    read -r MAKE_SWAP
    if [ "$MAKE_SWAP" = "yes" ]; then
        SWAP_SIZE="2G" # Default swap size, change if needed
        log_info "Swap partition will be created with size: $SWAP_SIZE"
    else
        SWAP_SIZE=""
        log_info "Swap partition will NOT be created."
    fi

    echo -n "Enter the username for the new system: "
    read -r USERNAME
    while true; do
        echo -n "Enter password for user ${USERNAME}: "
        read -s -r PASSWORD
        echo
        echo -n "Re-enter password for confirmation: "
        read -s -r PASSWORD_CONFIRM
        echo
        if [ "$PASSWORD" == "$PASSWORD_CONFIRM" ]; then
            break
        else
            log_warn "Passwords do not match. Please try again."
        fi
    done
    log_info "Initial configuration complete."
}

# インストール実行前の最終確認
confirm_installation() {
    log_warn "--------------------------------------------------------------------"
    log_warn "Installation Target Disk: $DISK"
    if [ "$MAKE_SWAP" = "yes" ]; then
        log_warn "Swap Partition: Will be created (Size: $SWAP_SIZE)"
    else
        log_warn "Swap Partition: Will NOT be created"
    fi
    log_warn "Username: $USERNAME"
    log_warn "Hostname: $HOSTNAME_CONFIG"
    log_warn "Timezone: $TIMEZONE_CONFIG"
    log_warn "Locale: $LOCALE_LANG_CONFIG"
    log_warn "Keymap: $KEYMAP_CONFIG"
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

# ディスクのパーティショニング
partition_disk() {
    log_info "Wiping existing partition table on $DISK..."
    sgdisk --zap-all "$DISK"; check_command_status "Failed to wipe partition table on $DISK."

    log_info "Creating new partitions on $DISK..."
    # EFI System Partition (ESP)
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"$EFI_PARTITION_NAME" "$DISK"; check_command_status "Failed to create EFI partition."

    if [ "$MAKE_SWAP" = "yes" ]; then
        # Linux root partition (leaving space for swap at the end)
        sgdisk -n 2:0:-${SWAP_SIZE} -t 2:8300 -c 2:"$ROOT_PARTITION_NAME" "$DISK"; check_command_status "Failed to create root partition."
        # Linux swap partition (using the remaining space at the end)
        sgdisk -n 3:0:0 -t 3:8200 -c 3:"$SWAP_PARTITION_NAME" "$DISK"; check_command_status "Failed to create swap partition."
        SWAP_PARTITION_DEVICE="/dev/disk/by-partlabel/$SWAP_PARTITION_NAME"
    else
        # Linux root partition (using all remaining space)
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"$ROOT_PARTITION_NAME" "$DISK"; check_command_status "Failed to create root partition."
    fi

    EFI_PARTITION_DEVICE="/dev/disk/by-partlabel/$EFI_PARTITION_NAME"
    ROOT_PARTITION_DEVICE="/dev/disk/by-partlabel/$ROOT_PARTITION_NAME"

    log_info "Informing the OS of partition table changes..."
    partprobe "$DISK"; check_command_status "Failed to run partprobe on $DISK."
}

# パーティションが認識されるまで待機
wait_for_partitions() {
    log_info "Waiting for partitions to be recognized..."
    local retries=15 # 30秒程度待つ (15 * 2秒)
    local count=0
    while [ $count -lt $retries ]; do
        # すべての必要なパーティションデバイスが存在するか確認
        if [ -b "$EFI_PARTITION_DEVICE" ] && [ -b "$ROOT_PARTITION_DEVICE" ] && \
           { [ -z "$SWAP_PARTITION_DEVICE" ] || [ -b "$SWAP_PARTITION_DEVICE" ]; }; then
            log_info "Partitions recognized:"
            lsblk "$DISK"
            sleep 1 # 念のため少し待つ
            return 0
        fi
        log_info "Still waiting for partitions... ($((count+1))/$retries)"
        sleep 2
        partprobe "$DISK" # partprobeを再試行
        count=$((count+1))
    done
    log_error "Timeout waiting for partitions to be recognized. Please check manually using 'lsblk $DISK' or 'fdisk -l $DISK'."
    log_error "Expected EFI: $EFI_PARTITION_DEVICE, Root: $ROOT_PARTITION_DEVICE"
    if [ -n "$SWAP_PARTITION_DEVICE" ]; then
        log_error "Expected Swap: $SWAP_PARTITION_DEVICE"
    fi
    exit 1
}

# ファイルシステムの作成
format_partitions() {
    log_info "Formatting partitions..."
    log_info "Formatting EFI partition ($EFI_PARTITION_DEVICE) as FAT32..."
    mkfs.fat -F32 "$EFI_PARTITION_DEVICE"; check_command_status "Failed to format EFI partition $EFI_PARTITION_DEVICE."

    log_info "Formatting root partition ($ROOT_PARTITION_DEVICE) as ext4..."
    mkfs.ext4 -F "$ROOT_PARTITION_DEVICE"; check_command_status "Failed to format root partition $ROOT_PARTITION_DEVICE." # Added -F to force

    if [ -n "$SWAP_PARTITION_DEVICE" ]; then
        log_info "Formatting swap partition ($SWAP_PARTITION_DEVICE)..."
        mkswap "$SWAP_PARTITION_DEVICE"; check_command_status "Failed to format swap partition $SWAP_PARTITION_DEVICE."
        log_info "Enabling swap on $SWAP_PARTITION_DEVICE..."
        swapon "$SWAP_PARTITION_DEVICE"; check_command_status "Failed to enable swap on $SWAP_PARTITION_DEVICE."
    fi
    log_info "Partition formatting complete."
}

# ファイルシステムのマウント
mount_filesystems() {
    log_info "Mounting filesystems..."
    mount "$ROOT_PARTITION_DEVICE" /mnt; check_command_status "Failed to mount root partition $ROOT_PARTITION_DEVICE to /mnt."

    mkdir -p /mnt/boot/efi; check_command_status "Failed to create /mnt/boot/efi directory."
    mount "$EFI_PARTITION_DEVICE" /mnt/boot/efi; check_command_status "Failed to mount EFI partition $EFI_PARTITION_DEVICE to /mnt/boot/efi."
    log_info "Filesystems mounted."
}

# ベースシステムのインストール
install_base_system() {
    log_info "Setting up system clock..."
    timedatectl set-ntp true; check_command_status "Failed to set NTP."

    log_info "Optimizing pacman mirrorlist (this may take a moment)..."
    pacman -Sy reflector --noconfirm --needed; check_command_status "Failed to install reflector."
    reflector --country Japan --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist; check_command_status "Failed to optimize mirrorlist with reflector."
    log_info "Mirrorlist optimized."

    log_info "Installing base system packages (pacstrap)..."
    pacstrap /mnt base base-devel linux linux-firmware grub efibootmgr networkmanager sudo git vim; check_command_status "Pacstrap failed to install base packages."

    log_info "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab; check_command_status "Failed to generate fstab."
    log_info "Base system installation complete."
}

# chroot環境設定スクリプトの生成
generate_chroot_script() {
    log_info "Creating chroot setup script (/mnt/root/chroot-setup.sh)..."
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
USERNAME_CHROOT="${USERNAME}"
PASSWORD_CHROOT="${PASSWORD}"
HOSTNAME_CHROOT="${HOSTNAME_CONFIG}"
TIMEZONE_CHROOT="${TIMEZONE_CONFIG}"
LOCALE_LANG_CHROOT="${LOCALE_LANG_CONFIG}"
KEYMAP_CHROOT="${KEYMAP_CONFIG}"
EXTRA_PACKAGES_CHROOT="${EXTRA_PACKAGES_CONFIG}" # Ensure this is properly quoted if it contains spaces

log_info_chroot "Synchronizing package databases..."
pacman -Sy --noconfirm; check_cmd_chroot "Failed to synchronize package databases."

log_info_chroot "Configuring timezone to \${TIMEZONE_CHROOT}..."
ln -sf /usr/share/zoneinfo/\${TIMEZONE_CHROOT} /etc/localtime; check_cmd_chroot "Failed to set timezone."
hwclock --systohc; check_cmd_chroot "Failed to set hardware clock."

log_info_chroot "Configuring locale (\${LOCALE_LANG_CHROOT})..."
sed -i "s/^#\(\${LOCALE_LANG_CHROOT} UTF-8\)/\1/" /etc/locale.gen; check_cmd_chroot "Failed to uncomment locale: \${LOCALE_LANG_CHROOT}"
sed -i "s/^#\(en_US.UTF-8 UTF-8\)/\1/" /etc/locale.gen; check_cmd_chroot "Failed to uncomment locale: en_US.UTF-8" # Keep en_US as a fallback
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
log_info_chroot "Setting password for \${USERNAME_CHROOT}..."
# WARNING: Storing password in a script and using chpasswd can be a security risk.
# Consider prompting for password interactively if higher security is needed.
echo "\${USERNAME_CHROOT}:\${PASSWORD_CHROOT}" | chpasswd; check_cmd_chroot "chpasswd failed for user \${USERNAME_CHROOT}."

log_info_chroot "Configuring sudo for wheel group (using /etc/sudoers.d/)..."
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/01_wheel_sudo; check_cmd_chroot "Failed to configure sudoers.d for wheel group."
chmod 0440 /etc/sudoers.d/01_wheel_sudo

log_info_chroot "Installing additional packages: sddm and \${EXTRA_PACKAGES_CHROOT}..."
pacman -S --noconfirm --needed sddm \${EXTRA_PACKAGES_CHROOT}; check_cmd_chroot "Failed to install additional packages."

log_info_chroot "Enabling essential services (sddm, NetworkManager)..."
systemctl enable sddm; check_cmd_chroot "Failed to enable sddm service."
systemctl enable NetworkManager; check_cmd_chroot "Failed to enable NetworkManager service."

log_info_chroot "Setting up AUR helper (yay) and installing Google Chrome for user \${USERNAME_CHROOT}..."
# WARNING: Installing packages from AUR involves community-maintained PKGBUILDs.
# Always review PKGBUILDs before building and installing, especially when using --noconfirm.
sudo -u "\${USERNAME_CHROOT}" bash -c '
    set -euo pipefail # Add strict mode for user script
    cd ~
    log_info_chroot "User \${USERNAME_CHROOT}: Cloning yay repository..."
    git clone https://aur.archlinux.org/yay.git || { log_error_chroot "User \${USERNAME_CHROOT}: Failed to clone yay."; exit 1; }
    cd yay
    log_info_chroot "User \${USERNAME_CHROOT}: Building and installing yay..."
    makepkg -si --noconfirm || { log_error_chroot "User \${USERNAME_CHROOT}: Failed to build/install yay."; exit 1; }
    cd ..
    log_info_chroot "User \${USERNAME_CHROOT}: Removing yay build directory..."
    rm -rf yay

    log_info_chroot "User \${USERNAME_CHROOT}: Installing Google Chrome using yay..."
    # The --noconfirm here skips PKGBUILD review and all yay confirmations. Use with caution.
    yay -S --noconfirm google-chrome || { log_error_chroot "User \${USERNAME_CHROOT}: Failed to install google-chrome with yay."; exit 1; } # Added error check
' || log_warn "AUR helper setup or Google Chrome installation encountered issues. Check logs." # Outer check for sudo -u command

log_info_chroot "Chroot setup complete."
CHROOT_SCRIPT_EOF
    check_command_status "Failed to create chroot setup script."
    chmod +x /mnt/root/chroot-setup.sh; check_command_status "Failed to make chroot setup script executable."
}

# Chroot環境で設定スクリプトを実行
run_chroot_script() {
    log_info "Entering chroot and running setup script..."
    arch-chroot /mnt /root/chroot-setup.sh; check_command_status "Chroot setup script execution failed."
    # chrootスクリプト内でエラーが発生した場合、check_command_statusがそれを検知する
    log_info "Chroot setup script finished."
}

# 最終処理と再起動の確認
finish_installation() {
    log_info "Installation process finished."
    # chrootスクリプトの削除（オプション）
    if [ -f /mnt/root/chroot-setup.sh ]; then
        rm /mnt/root/chroot-setup.sh
        log_info "Removed chroot setup script."
    fi

    echo "You can now unmount the partitions and reboot the system."
    echo "Do you want to unmount and reboot now? (yes/no)"
    read -r reboot_confirmation
    if [ "$reboot_confirmation" == "yes" ]; then
        log_info "Unmounting filesystems..."
        # cleanup関数でアンマウントは行われるが、ここでは明示的に行う
        # ただし、trapで呼ばれるcleanupと競合しないように注意する
        # trapを一時的に無効化するか、cleanupを直接呼び出す
        trap - EXIT ERR INT TERM # trapを解除
        cleanup # 手動でクリーンアップを実行
        log_info "Rebooting system..."
        reboot
    else
        log_info "Please run 'umount -R /mnt && reboot' or simply 'reboot' (after exiting script) manually to restart into your new Arch Linux system."
        log_info "Ensure all /mnt/* partitions are unmounted before rebooting if you do it manually."
    fi
}

# ==========================
# メイン処理
# ==========================
main() {
    # スクリプト終了時に cleanup 関数を呼び出すように trap を設定
    trap cleanup EXIT ERR INT TERM

    prompt_initial_settings
    confirm_installation
    partition_disk
    wait_for_partitions # DISK変数はグローバルなので渡す必要なし
    format_partitions
    mount_filesystems
    install_base_system
    generate_chroot_script
    run_chroot_script
    finish_installation

    # 正常終了時はtrapを解除してexit
    trap - EXIT
    log_info "Arch Linux installation script completed successfully!"
    exit 0
}

# スクリプト実行開始
main

