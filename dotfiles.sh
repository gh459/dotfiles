#!/bin/bash
set -e

# --- 設定変数 (カスタマイズ可能) ---
DISK="/dev/sda" # 注意: このディスクのデータは全て消えます！
EFI_PARTITION="${DISK}1"
ROOT_PARTITION="${DISK}2"
SWAP_PARTITION="${DISK}3"

USERNAME="archuser"
PASSWORD="password123" # セキュリティのため、実際の運用では変更または対話的に入力させる
HOSTNAME="myarch"
TIMEZONE="Asia/Tokyo"
LOCALE_LANG="ja_JP.UTF-8"
KEYMAP="jp106" # コンソールキーマップ

# --- 事前準備 (ライブ環境) ---
echo "INFO: システムクロックを更新しています..."
timedatectl set-ntp true

echo "INFO: ミラーリストを最適化しています (日本国内のミラー)..."
pacman -Sy reflector --noconfirm --needed
reflector --country Japan --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "INFO: これからディスク ${DISK} のパーティションをフォーマットします。"
echo "続行すると ${DISK} のデータは全て失われます。よろしいですか？ (yes/no)"
read -r confirmation
if [ "$confirmation" != "yes" ]; then
    echo "処理を中断しました。"
    exit 1
fi

# --- パーティション作成とフォーマット (既存のパーティション構成を前提) ---
# この部分は parted や fdisk を使ってパーティションを作成する処理を別途追加するか、
# 事前に手動でパーティションが作成済みであることを前提とします。
# 以下はフォーマットのみの例です。
echo "INFO: パーティションをフォーマットしています..."
mkfs.fat -F32 "${EFI_PARTITION}"
mkfs.ext4 "${ROOT_PARTITION}"
mkswap "${SWAP_PARTITION}"
swapon "${SWAP_PARTITION}"

# --- マウント ---
echo "INFO: ファイルシステムをマウントしています..."
mount "${ROOT_PARTITION}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PARTITION}" /mnt/boot/efi

# --- ベースシステムのインストール ---
echo "INFO: ベースシステムをインストールしています (pacstrap)..."
pacstrap /mnt base base-devel linux linux-firmware grub efibootmgr networkmanager sudo git vim # その他必要な基本パッケージ

# --- fstab生成 ---
echo "INFO: fstabを生成しています..."
genfstab -U /mnt >> /mnt/etc/fstab

# --- chroot用スクリプトを作成 ---
echo "INFO: chroot内設定スクリプトを作成しています..."
cat <<EOF > /mnt/root/chroot-setup.sh
#!/bin/bash
set -e

echo "INFO: タイムゾーンを設定しています (${TIMEZONE})..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

echo "INFO: ロケールを設定しています (${LOCALE_LANG})..."
echo "${LOCALE_LANG} UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen # 念のため英語ロケールも有効化
locale-gen
echo "LANG=${LOCALE_LANG}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf # コンソールキーマップ

echo "INFO: ホスト名を設定しています (${HOSTNAME})..."
echo "${HOSTNAME}" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echo "INFO: 初期RAMディスクを再生成しています (mkinitcpio)..."
mkinitcpio -P

echo "INFO: GRUBブートローダーをインストール・設定しています..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

echo "INFO: ユーザー '${USERNAME}' を作成し、パスワードとsudo権限を設定しています..."
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers # パスワード入力ありのsudo
# もしパスワードなしsudoにしたい場合 (非推奨):
# sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

echo "INFO: 追加パッケージをインストールしています..."
pacman -S --noconfirm --needed xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-arch-config lxqt-policykit lxqt-session lxqt-admin \
openbox obconf sddm pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts pipewire pipewire-pulse pavucontrol

echo "INFO: サービスを有効化しています (sddm, NetworkManager)..."
systemctl enable sddm
systemctl enable NetworkManager

echo "INFO: AURヘルパー (yay) とGoogle Chromeをインストールしています..."
sudo -u "${USERNAME}" bash -c '
cd ~
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay
yay -S --noconfirm google-chrome
'

echo "INFO: chroot内セットアップ完了。"
EOF

chmod +x /mnt/root/chroot-setup.sh

# --- chrootでセットアップ実行 ---
echo "INFO: chroot環境に入り、システム設定を実行します..."
arch-chroot /mnt /root/chroot-setup.sh

# --- 後処理 ---
echo "INFO: インストールが完了しました。"
echo "アンマウントして再起動しますか？ (yes/no)"
read -r reboot_confirmation
if [ "$reboot_confirmation" == "yes" ]; then
    umount -R /mnt
    echo "システムを再起動します。"
    reboot
else
    echo "手動でアンマウントと再起動を行ってください: umount -R /mnt && reboot"
fi
