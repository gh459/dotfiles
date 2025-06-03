#!/bin/bash
set -e

# ==========================
# 設定セクション
# ==========================
HOSTNAME="myarch"
TIMEZONE="Asia/Tokyo"
LOCALE_LANG="ja_JP.UTF-8" # 日本語ロケール
KEYMAP="jp106" # 日本語キーボードレイアウト

#  インストールするパッケージ（LXQt デスクトップ環境、日本語フォントなど）
EXTRA_PACKAGES="xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-config lxqt-policykit lxqt-session lxqt-admin \
openbox pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts noto-fonts-cjk pipewire pipewire-pulse pavucontrol fcitx5 fcitx5-mozc-ut steam"
#  noto-fonts-cjk は日本語フォントの表示用です。
# ==========================

#  ライブ環境での文字化けを回避するための英語の指示文
#  インストールディスクを選択してください
echo "Enter the installation disk (e.g., /dev/sda, /dev/nvme0n1):"
read DISK
if [ ! -b "$DISK" ]; then
    echo "Error: The specified disk $DISK does not exist."
    exit 1
fi

echo "Do you want to create a swap partition? (yes/no)"
read MAKE_SWAP
if [ "$MAKE_SWAP" = "yes" ]; then
    SWAP_SIZE="2G"  # Default swap size, change if needed
else
    SWAP_SIZE=""
fi

echo "-------------------------"
echo "Disk to be partitioned: $DISK"
if [ "$MAKE_SWAP" = "yes" ]; then
    echo "Swap partition: Will be created (Size: $SWAP_SIZE)"
else
    echo "Swap partition: Will NOT be created"
fi
echo "WARNING: All data on $DISK will be erased. This action cannot be undone."
echo "Are you sure you want to continue? (yes/no)"
read confirmation
if [ "$confirmation" != "yes" ]; then
    echo "Installation aborted by user."
    exit 1
fi

# ==========================
#  sgdiskを使用した自動パーティション分割
#  これにより、次が生成されます：
# 1. EFI System Partition (512MiB)
# 2. Linux root (rest of the disk, or rest minus swap)
# 3. Linux swap (if selected)
# ==========================
echo "Wiping existing partition table on $DISK..."
sgdisk --zap-all "$DISK"

echo "Creating new partitions on $DISK..."
#  EFIシステムパーティションを作成する
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
EFI_PARTITION="${DISK}1"

if [ "$MAKE_SWAP" = "yes" ]; then
    #  Linuxのルートパーティションを作成（スワップ領域のサイズを除いた残りのすべての領域を末尾に配置）
    sgdisk -n 2:0:-${SWAP_SIZE} -t 2:8300 -c 2:"Linux root" "$DISK"
    ROOT_PARTITION="${DISK}2"
    #  Linuxのスワップパーティションを作成します（残りの$｛SWAP_SIZE｝を末尾に割り当てます）
    sgdisk -n 3:0:0 -t 3:8200 -c 3:"Linux swap" "$DISK"
    SWAP_PARTITION="${DISK}3"
else
    #  Linuxのルートパーティションを作成（残りのすべての領域を使用）
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
    ROOT_PARTITION="${DISK}2"
    SWAP_PARTITION=""
fi

echo "Informing the OS of partition table changes..."
partprobe "$DISK"
sleep 3  # Give the system a moment to recognize new partitions

echo "Newly created partitions:"
lsblk "$DISK"

# ==========================
# ユーザー名とパスワード
# ==========================
echo -n "Enter the username to create for the new system: "
read USERNAME
while true; do
    echo -n "Enter password for user ${USERNAME}: "
    read -s PASSWORD
    echo
    echo -n "Re-enter password for confirmation: "
    read -s PASSWORD_CONFIRM
    echo
    if [ "$PASSWORD" == "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo "Passwords do not match. Please try again."
    fi
done

# ==========================
# ファイルシステムの作成
# ==========================
echo "Formatting partitions..."
echo "Formatting EFI partition ($EFI_PARTITION) as FAT32..."
mkfs.fat -F32 "$EFI_PARTITION"
echo "Formatting root partition ($ROOT_PARTITION) as ext4..."
mkfs.ext4 "$ROOT_PARTITION"

if [ -n "$SWAP_PARTITION" ]; then
    echo "Formatting swap partition ($SWAP_PARTITION)..."
    mkswap "$SWAP_PARTITION"
    echo "Enabling swap on $SWAP_PARTITION..."
    swapon "$SWAP_PARTITION"
fi

# ==========================
# ファイルシステムのマウント
# ==========================
echo "Mounting filesystems..."
mount "$ROOT_PARTITION" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PARTITION" /mnt/boot/efi

# ==========================
# ベースシステムインストール
# ==========================
echo "Setting up system clock..."
timedatectl set-ntp true

echo "Optimizing pacman mirrorlist (this may take a moment)..."
pacman -Sy reflector --noconfirm --needed
reflector --country Japan --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "Installing base system packages (pacstrap)..."
pacstrap /mnt base base-devel linux linux-firmware grub efibootmgr networkmanager sudo git vim

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ==========================
#  chroot 環境設定スクリプトを作成する
#  （このスクリプトは新しいシステム内で実行されます）
# ==========================
echo "Creating chroot setup script..."
cat <<EOF > /mnt/root/chroot-setup.sh
#!/bin/bash
set -e

# Variables passed from the main script
USERNAME="${USERNAME}"
PASSWORD="${PASSWORD}"
HOSTNAME="${HOSTNAME}"
TIMEZONE="${TIMEZONE}"
LOCALE_LANG="${LOCALE_LANG}"
KEYMAP="${KEYMAP}"
EXTRA_PACKAGES="${EXTRA_PACKAGES}"

echo "Configuring timezone to \${TIMEZONE}..."
ln -sf /usr/share/zoneinfo/\${TIMEZONE} /etc/localtime
hwclock --systohc

echo "Configuring locale (\${LOCALE_LANG})..."
sed -i "s/^#\(${LOCALE_LANG} UTF-8\)/\1/" /etc/locale.gen
sed -i "s/^#\(en_US.UTF-8 UTF-8\)/\1/" /etc/locale.gen # Keep en_US as a fallback
locale-gen
echo "LANG=\${LOCALE_LANG}" > /etc/locale.conf
echo "KEYMAP=\${KEYMAP}" > /etc/vconsole.conf

echo "Configuring hostname to \${HOSTNAME}..."
echo "\${HOSTNAME}" > /etc/hostname
cat <<HOSTS_EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
HOSTS_EOF

echo "Generating initramfs (mkinitcpio)..."
mkinitcpio -P

echo "Installing GRUB bootloader..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
echo "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "Creating user \${USERNAME}..."
useradd -m -G wheel -s /bin/bash "\${USERNAME}"
echo "Setting password for \${USERNAME}..."
echo "\${USERNAME}:\${PASSWORD}" | chpasswd
echo "Configuring sudo for wheel group..."
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "Installing additional packages: \${EXTRA_PACKAGES}..."
echo "Enabling essential services (sddm, NetworkManager)..."
pacman -S --noconfirm --needed sddm ${EXTRA_PACKAGES}

systemctl enable sddm
systemctl enable NetworkManager

echo "Setting up AUR helper (yay) and installing Google Chrome for user \${USERNAME}..."
sudo -u "\${USERNAME}" bash -c '
cd ~
echo "Cloning yay repository..."
git clone https://aur.archlinux.org/yay.git
cd yay
echo "Building and installing yay..."
makepkg -si --noconfirm
cd ..
echo "Removing yay build directory..."
rm -rf yay
echo "Installing Google Chrome using yay..."
yay -S --noconfirm google-chrome
'

echo "Chroot setup complete."
EOF

chmod +x /mnt/root/chroot-setup.sh

# ==========================
# Chroot セットアップ スクリプトを実行する
# ==========================
echo "Entering chroot and running setup script..."
arch-chroot /mnt /root/chroot-setup.sh

# ==========================
#  最終手順
# ==========================
echo "Installation process finished."
echo "You can now unmount the partitions and reboot the system."
echo "Do you want to unmount and reboot now? (yes/no)"
read reboot_confirmation
if [ "$reboot_confirmation" == "yes" ]; then
    echo "Unmounting filesystems..."
    umount -R /mnt
    echo "Rebooting system..."
    reboot
else
    echo "Please run 'umount -R /mnt && reboot' manually to restart into your new Arch Linux system."
fi
