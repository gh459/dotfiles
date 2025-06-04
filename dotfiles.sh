#!/bin/bash

# スクリプトの動作を厳格にする
# -e: コマンドがエラーになったら即座に終了
# -u: 未定義変数を参照したらエラー
# -o pipefail: パイプライン中のコマンドが失敗したら、パイプライン全体の終了ステータスをそのコマンドのものにする
set -euo pipefail

# ==========================
#      !!! WARNING !!!
# ==========================
# このスクリプトはUEFIシステム専用です。
# 実行前に、動作するインターネット接続があることを確認してください。
# このスクリプトは選択されたディスク上のすべてのデータを消去します。
# 自己責任で使用してください。実行前にスクリプトを注意深く確認してください。
# Arch Linuxのライブ環境からこのスクリプトを実行することを強く推奨します。
# ==========================

# ==========================
# グローバル設定変数
# ==========================
HOSTNAME_CONFIG="myarch"
TIMEZONE_CONFIG="Asia/Tokyo"
LOCALE_LANG_CONFIG="ja_JP.UTF-8"
KEYMAP_CONFIG="jp106"

# インストールする追加パッケージ
# 将来的に、これを外部ファイルから読み込むか、ユーザーに選択させることで柔軟性を高めることができます。
EXTRA_PACKAGES_CONFIG="xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-config lxqt-policykit lxqt-session lxqt-admin \
openbox pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts noto-fonts-cjk pipewire pipewire-pulse pavucontrol fcitx5 fcitx5-mozc-ut steam"

# GPTパーティションラベル名
EFI_PARTITION_NAME="ESP_ARCH"
ROOT_PARTITION_NAME="ROOT_ARCH"
SWAP_PARTITION_NAME="SWAP_ARCH"

# グローバル変数（スクリプト内で設定される）
DISK=""
MAKE_SWAP=""
SWAP_SIZE=""
USERNAME=""
# PASSWORD="" # chroot内で直接設定するため不要に
REFLECTOR_COUNTRY_CODE="" # Reflectorで使用する国コード

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
# 必須コマンドチェック関数
# ==========================
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
# インストール処理関数
# ==========================

# 初期設定値の入力と確認
prompt_initial_settings() {
    log_info "Starting initial configuration..."

    log_info "Available block devices:"
    lsblk -f
    echo "You can also use 'fdisk -l' for more details."

    echo "Enter the installation disk (e.g., /dev/sda, /dev/nvme0n1):"
    read -r DISK
    if [ ! -b "$DISK" ]; then
        log_error "The specified disk $DISK does not exist or is not a block device."
        exit 1
    fi

    echo "Do you want to create a swap partition? (yes/no)"
    read -r MAKE_SWAP
    if [ "$MAKE_SWAP" = "yes" ]; then
        echo "Enter swap size (e.g., 2G, 8G, if empty, default 4G will be used):"
        read -r user_swap_size
        SWAP_SIZE="${user_swap_size:-4G}" # デフォルトスワップサイズを4Gに変更
        log_info "Swap partition will be created with size: $SWAP_SIZE"
    else
        SWAP_SIZE=""
        log_info "Swap partition will NOT be created."
    fi

    echo -n "Enter the username for the new system: "
    read -r USERNAME
    if [ -z "$USERNAME" ]; then
        log_error "Username cannot be empty."
        exit 1
    fi

    echo "Enter the country code for reflector (e.g., JP, US, GB). Leave empty for 'Japan'."
    read -r user_country_code
    REFLECTOR_COUNTRY_CODE="${user_country_code:-Japan}"
    log_info "Reflector will use country: $REFLECTOR_COUNTRY_CODE"

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
    log_warn "Reflector Country: $REFLECTOR_COUNTRY_CODE"
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
    udevadm settle; check_command_status "Failed to run udevadm settle."
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
        udevadm settle
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
    mkfs.ext4 -F "$ROOT_PARTITION_DEVICE"; check_command_status "Failed to format root partition $ROOT_PARTITION_DEVICE."

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
    reflector --country "$REFLECTOR_COUNTRY_CODE" --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist; check_command_status "Failed to optimize mirrorlist with reflector."
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
# PASSWORD_CHROOT is no longer passed. Password will be set interactively.
HOSTNAME_CHROOT="${HOSTNAME_CONFIG}"
TIMEZONE_CHROOT="${TIMEZONE_CONFIG}"
LOCALE_LANG_CHROOT="${LOCALE_LANG_CONFIG}"
KEYMAP_CHROOT="${KEYMAP_CONFIG}"
EXTRA_PACKAGES_CHROOT="${EXTRA_PACKAGES_CONFIG}"

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

log_info_chroot "Setting password for user \${USERNAME_CHROOT}..."
log_info_chroot "You will now be prompted to enter and confirm the password for user \${USERNAME_CHROOT}."
passwd "\${USERNAME_CHROOT}"; check_cmd_chroot "Failed to set password for user \${USERNAME_CHROOT}."

log_info_chroot "Configuring sudo for wheel group (using /etc/sudoers.d/)..."
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/01_wheel_sudo; check_cmd_chroot "Failed to configure sudoers.d for wheel group."
chmod 0440 /etc/sudoers.d/01_wheel_sudo

log_info_chroot "Installing additional packages: sddm and others..."
pacman -S --noconfirm --needed sddm \${EXTRA_PACKAGES_CHROOT}; check_cmd_chroot "Failed to install additional packages."

log_info_chroot "Enabling essential services (sddm, NetworkManager)..."
systemctl enable sddm; check_cmd_chroot "Failed to enable sddm service."
systemctl enable NetworkManager; check_cmd_chroot "Failed to enable NetworkManager service."

log_info_chroot "Setting up AUR helper (yay) and installing Google Chrome for user \${USERNAME_CHROOT}..."
# WARNING: Installing packages from AUR involves community-maintained PKGBUILDs.
# Always review PKGBUILDs before building and installing.
sudo -u "\${USERNAME_CHROOT}" bash -c '
set -euo pipefail # Add strict mode for user script
# Helper functions need to be accessible or re-defined if used within this sub-shell
# For simplicity, direct echo is used here.
echo "[CHROOT USER INFO] User \${USERNAME_CHROOT}: Changing to home directory..."
cd ~
echo "[CHROOT USER INFO] User \${USERNAME_CHROOT}: Cloning yay repository..."
git clone https://aur.archlinux.org/yay.git || { echo "[CHROOT USER ERROR] User \${USERNAME_CHROOT}: Failed to clone yay." >&2; exit 1; }
cd yay
echo "[CHROOT USER INFO] User \${USERNAME_CHROOT}: Building and installing yay. Please review PKGBUILDs when prompted."
makepkg -si || { echo "[CHROOT USER ERROR] User \${USERNAME_CHROOT}: Failed to build/install yay." >&2; exit 1; }
cd ..
echo "[CHROOT USER INFO] User \${USERNAME_CHROOT}: Removing yay build directory..."
rm -rf yay
echo "[CHROOT USER INFO] User \${USERNAME_CHROOT}: Installing Google Chrome using yay. Please review PKGBUILDs and confirm when prompted."
yay -S google-chrome || { echo "[CHROOT USER ERROR] User \${USERNAME_CHROOT}: Failed to install google-chrome with yay." >&2; exit 1; }
' || log_warn "AUR helper setup or Google Chrome installation encountered issues. Check logs."

log_info_chroot "Chroot setup complete."
CHROOT_SCRIPT_EOF
    check_command_status "Failed to create chroot setup script."
    chmod +x /mnt/root/chroot-setup.sh; check_command_status "Failed to make chroot setup script executable."
}

# Chroot環境で設定スクリプトを実行
run_chroot_script() {
    log_info "Entering chroot and running setup script..."
    arch-chroot /mnt /root/chroot-setup.sh; check_command_status "Chroot setup script execution failed."
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
    if [ "$reboot_
