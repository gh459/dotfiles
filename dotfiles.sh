#!/bin/bash
set -e

# ==========================
# 設定値セクション
# ==========================
HOSTNAME="myarch"
TIMEZONE="Asia/Tokyo"
LOCALE_LANG="ja_JP.UTF-8"
KEYMAP="jp106"
EXTRA_PACKAGES="xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-arch-config lxqt-policykit lxqt-session lxqt-admin \
openbox obconf sddm pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts pipewire pipewire-pulse pavucontrol"
# ==========================
# ここまで設定値セクション
# ==========================

# インストール先ディスクの選択
echo "インストール先ディスクを入力してください（例: /dev/sda, /dev/nvme0n1）:"
read DISK
if [ ! -b "$DISK" ]; then
    echo "エラー: 指定されたディスク $DISK は存在しません。"
    exit 1
fi

echo "スワップパーティションを作成しますか？ (yes/no)"
read MAKE_SWAP
if [ "$MAKE_SWAP" = "yes" ]; then
    SWAP_SIZE="2G"  # 必要に応じて変更
else
    SWAP_SIZE=""
fi

echo "-------------------------"
echo "ディスク: $DISK"
if [ "$MAKE_SWAP" = "yes" ]; then
    echo "スワップ: 作成 ($SWAP_SIZE)"
else
    echo "スワップ: 作成しない"
fi
echo "続行すると $DISK のデータは全て消去されます。本当によろしいですか？(yes/no)"
read confirmation
if [ "$confirmation" != "yes" ]; then
    echo "中断しました。"
    exit 1
fi

# ==========================
# パーティション自動作成
# ==========================
# 既存パーティション全削除
sgdisk --zap-all "$DISK"

# EFI 512MiB, SWAP (任意), 残り全部root
if [ "$MAKE_SWAP" = "yes" ]; then
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" \
           -n 2:0:-${SWAP_SIZE} -t 2:8300 -c 2:"Linux root" \
           -n 3:0:0 -t 3:8200 -c 3:"Linux swap" "$DISK"
    EFI_PARTITION="${DISK}1"
    ROOT_PARTITION="${DISK}2"
    SWAP_PARTITION="${DISK}3"
else
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" \
           -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
    EFI_PARTITION="${DISK}1"
    ROOT_PARTITION="${DISK}2"
    SWAP_PARTITION=""
fi

partprobe "$DISK"
sleep 2  # デバイス認識待ち

# ==========================
# ユーザー名とパスワードの入力
# ==========================
echo -n "作成するユーザー名を入力してください: "
read USERNAME
while true; do
    echo -n "${USERNAME} のパスワードを入力してください: "
    read -s PASSWORD
    echo
    echo -n "パスワードを再入力してください: "
    read -s PASSWORD_CONFIRM
    echo
    if [ "$PASSWORD" == "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo "パスワードが一致しません。もう一度入力してください。"
    fi
done

# ==========================
# ファイルシステム作成
# ==========================
mkfs.fat -F32 "$EFI_PARTITION"
mkfs.ext4 "$ROOT_PARTITION"
if [ -n "$SWAP_PARTITION" ]; then
    mkswap "$SWAP_PARTITION"
    swapon "$SWAP_PARTITION"
fi

# ==========================
# マウント
# ==========================
mount "$ROOT_PARTITION" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PARTITION" /mnt/boot/efi

# ==========================
# ベースシステムのインストール
# ==========================
timedatectl set-ntp true
pacman -Sy reflector --noconfirm --needed
reflector --country Japan --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacstrap /mnt base base-devel linux linux-firmware grub efibootmgr networkmanager sudo git vim
genfstab -U /mnt >> /mnt/etc/fstab

# ==========================
# chroot用スクリプトを作成
# ==========================
cat <<EOF > /mnt/root/chroot-setup.sh
#!/bin/bash
set -e

USERNAME="${USERNAME}"
PASSWORD="${PASSWORD}"
HOSTNAME="${HOSTNAME}"
TIMEZONE="${TIMEZONE}"
LOCALE_LANG="${LOCALE_LANG}"
KEYMAP="${KEYMAP}"
EXTRA_PACKAGES="${EXTRA_PACKAGES}"

ln -sf /usr/share/zoneinfo/\${TIMEZONE} /etc/localtime
hwclock --systohc

echo "\${LOCALE_LANG} UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=\${LOCALE_LANG}" > /etc/locale.conf
echo "KEYMAP=\${KEYMAP}" > /etc/vconsole.conf

echo "\${HOSTNAME}" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
HOSTS

mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

useradd -m -G wheel -s /bin/bash "\${USERNAME}"
echo "\${USERNAME}:\${PASSWORD}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

pacman -S --noconfirm --needed \${EXTRA_PACKAGES}

systemctl enable sddm
systemctl enable NetworkManager

sudo -u "\${USERNAME}" bash -c '
cd ~
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay
yay -S --noconfirm google-chrome
'

echo "chroot内セットアップ完了。"
EOF

chmod +x /mnt/root/chroot-setup.sh

arch-chroot /mnt /root/chroot-setup.sh

echo "インストールが完了しました。アンマウントして再起動しますか？(yes/no)"
read reboot_confirmation
if [ "$reboot_confirmation" == "yes" ]; then
    umount -R /mnt
    reboot
else
    echo "手動で umount -R /mnt && reboot を実行してください。"
fi
