#!/bin/bash
set -e

# ==========================
# 設定値セクション
# ==========================

# ディスクとパーティションの選択
echo "インストール先ディスクを入力してください（例: /dev/sda, /dev/nvme0n1）:"
read DISK
if [ ! -b "$DISK" ]; then
    echo "エラー: 指定されたディスク $DISK は存在しません。"
    exit 1
fi

echo "EFIパーティション（例: ${DISK}1）を入力してください:"
read EFI_PARTITION
if [ ! -b "$EFI_PARTITION" ]; then
    echo "エラー: 指定されたパーティション $EFI_PARTITION は存在しません。"
    exit 1
fi

echo "ルートパーティション（例: ${DISK}2）を入力してください:"
read ROOT_PARTITION
if [ ! -b "$ROOT_PARTITION" ]; then
    echo "エラー: 指定されたパーティション $ROOT_PARTITION は存在しません。"
    exit 1
fi

echo "スワップパーティション（例: ${DISK}3、スワップ不要なら空Enter）を入力してください:"
read SWAP_PARTITION
if [ -n "$SWAP_PARTITION" ] && [ ! -b "$SWAP_PARTITION" ]; then
    echo "エラー: 指定されたパーティション $SWAP_PARTITION は存在しません。"
    exit 1
fi

# システム設定
HOSTNAME="myarch"
TIMEZONE="Asia/Tokyo"
LOCALE_LANG="ja_JP.UTF-8"
KEYMAP="jp106"

# インストールする追加パッケージ
EXTRA_PACKAGES="xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-arch-config lxqt-policykit lxqt-session lxqt-admin \
openbox obconf sddm pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts pipewire pipewire-pulse pavucontrol"

# ==========================
# ここまで設定値セクション
# ==========================

# ユーザー名とパスワードの入力
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

# 確認表示
echo "-------------------------"
echo "インストール設定内容を確認してください："
echo "ディスク: ${DISK}"
echo "EFIパーティション: ${EFI_PARTITION}"
echo "ルートパーティション: ${ROOT_PARTITION}"
echo "スワップパーティション: ${SWAP_PARTITION:-なし}"
echo "ホスト名: ${HOSTNAME}"
echo "タイムゾーン: ${TIMEZONE}"
echo "ロケール: ${LOCALE_LANG}"
echo "キーマップ: ${KEYMAP}"
echo "追加パッケージ: ${EXTRA_PACKAGES}"
echo "ユーザー名: ${USERNAME}"
echo "-------------------------"
echo "続行すると ${DISK} のデータは全て消去されます。本当によろしいですか？(yes/no)"
read confirmation
if [ "$confirmation" != "yes" ]; then
    echo "中断しました。"
    exit 1
fi

# システムクロックの設定
timedatectl set-ntp true

# ミラーリスト最適化
pacman -Sy reflector --noconfirm --needed
reflector --country Japan --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# パーティションのフォーマット
mkfs.fat -F32 "${EFI_PARTITION}"
mkfs.ext4 "${ROOT_PARTITION}"
if [ -n "$SWAP_PARTITION" ]; then
    mkswap "${SWAP_PARTITION}"
    swapon "${SWAP_PARTITION}"
fi

# マウント
mount "${ROOT_PARTITION}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PARTITION}" /mnt/boot/efi

# ベースシステムのインストール
pacstrap /mnt base base-devel linux linux-firmware grub efibootmgr networkmanager sudo git vim

# fstab生成
genfstab -U /mnt >> /mnt/etc/fstab

# chroot用スクリプトを作成
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

# chrootでセットアップ実行
arch-chroot /mnt /root/chroot-setup.sh

# 後処理
echo "インストールが完了しました。アンマウントして再起動しますか？(yes/no)"
read reboot_confirmation
if [ "$reboot_confirmation" == "yes" ]; then
    umount -R /mnt
    reboot
else
    echo "手動で umount -R /mnt && reboot を実行してください。"
fi
