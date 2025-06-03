#!/bin/bash
set -e

# --- 事前準備 (ライブ環境) ---
echo "INFO: システムクロックを更新しています..."
timedatectl set-ntp true

echo "INFO: ミラーリストを最適化しています (日本国内のミラー)..."
pacman -Sy reflector --noconfirm --needed
reflector --country Japan --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# --- ユーザー名とパスワードの入力 ---
echo -n "作成するユーザー名を入力してください: "
read USERNAME
while true; do
    echo -n "${USERNAME} のパスワードを入力してください: "
    read -s PASSWORD # -s オプションで入力文字を非表示に
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

# --- その他の設定変数 (カスタマイズ可能) ---
DISK="/dev/sda" # 注意: このディスクのデータは全て消えます！
EFI_PARTITION="${DISK}1"
ROOT_PARTITION="${DISK}2"
SWAP_PARTITION="${DISK}3"

HOSTNAME="myarch" # ホスト名も入力させたい場合は同様に read を使う
TIMEZONE="Asia/Tokyo"
LOCALE_LANG="ja_JP.UTF-8"
KEYMAP="jp106"

echo "INFO: これからディスク ${DISK} のパーティションをフォーマットします。"
echo "ユーザー名: ${USERNAME}"
echo "上記設定で続行すると ${DISK} のデータは全て失われます。よろしいですか？ (yes/no)"
read -r confirmation
if [ "$confirmation" != "yes" ]; then
    echo "処理を中断しました。"
    exit 1
fi

# --- パーティション作成とフォーマット (既存のパーティション構成を前提) ---
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
# USERNAME と PASSWORD を chroot スクリプトに渡すためにエクスポートするか、
# chroot スクリプト内で再度入力させる、またはスクリプト内に直接埋め込む必要があります。
# ここでは、chrootスクリプトに直接埋め込む形で変数を展開します。
cat <<EOF > /mnt/root/chroot-setup.sh
#!/bin/bash
set -e

USERNAME_CHROOT="${USERNAME}" # 外側の変数をchrootスクリプト内で利用
PASSWORD_CHROOT="${PASSWORD}"

echo "INFO: タイムゾーンを設定しています (${TIMEZONE})..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

echo "INFO: ロケールを設定しています (${LOCALE_LANG})..."
echo "${LOCALE_LANG} UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE_LANG}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

echo "INFO: ホスト名を設定しています (${HOSTNAME})..."
echo "${HOSTNAME}" > /etc/hostname
cat <<HOST_CONFIG > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOST_CONFIG

echo "INFO: 初期RAMディスクを再生成しています (mkinitcpio)..."
mkinitcpio -P

echo "INFO: GRUBブートローダーをインストール・設定しています..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

echo "INFO: ユーザー '\${USERNAME_CHROOT}' を作成し、パスワードとsudo権限を設定しています..."
useradd -m -G wheel -s /bin/bash "\${USERNAME_CHROOT}"
echo "\${USERNAME_CHROOT}:\${PASSWORD_CHROOT}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "INFO: 追加パッケージをインストールしています..."
pacman -S --noconfirm --needed xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-arch-config lxqt-policykit lxqt-session lxqt-admin \
openbox obconf sddm pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts pipewire pipewire-pulse pavucontrol

echo "INFO: サービスを有効化しています (sddm, NetworkManager)..."
systemctl enable sddm
systemctl enable NetworkManager

echo "INFO: AURヘルパー (yay) とGoogle Chromeをインストールしています..."
sudo -u "\${USERNAME_CHROOT}" bash -c '
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
