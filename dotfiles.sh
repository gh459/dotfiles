#!/bin/bash
set -euo pipefail

# --- 事前変数定義（必要に応じて編集） ---
DISK="/dev/sda"
HOST_NAME="archlinux"
ROOT_PASSWORD="rootpass"
USER_NAME="user"
USER_PASSWORD="userpass"
AUTO_LOGIN="yes"            # "yes"で自動ログイン
CHROOT_PACKAGES_TO_INSTALL="xorg gnome gnome-extra gnome-keyring networkmanager"
DM_SERVICE_NAME="gdm.service"
INSTALL_STEAM="yes"
INSTALL_PROTONUPQT="yes"

# --- パーティション作成・フォーマット ---
echo "ディスクをパーティショニングし、フォーマットします..."
sgdisk -Z ${DISK}
sgdisk -n 1:0:+512M -t 1:ef00 ${DISK}
sgdisk -n 2:0:0     -t 2:8300 ${DISK}
mkfs.fat -F32 ${DISK}1
mkfs.ext4 ${DISK}2

# --- マウント ---
echo "パーティションをマウントします..."
mount ${DISK}2 /mnt
mkdir -p /mnt/boot
mount ${DISK}1 /mnt/boot

# --- ベースシステムインストール ---
echo "ベースシステムをインストールします..."
pacstrap /mnt base linux linux-firmware sudo vim

# --- fstab生成 ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- chroot内の設定をヒアドキュメントで実行 ---
echo "chroot環境に入り、各種設定を行います..."
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo "パッケージキャッシュをクリアし、キーリングを更新します..."
pacman -Scc --noconfirm
pacman -Sy --noconfirm archlinux-keyring

echo "タイムゾーンとロケールを設定します..."
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf

echo "ホスト名とhostsを設定します..."
echo "${HOST_NAME}" > /etc/hostname
cat <<HOSTS_EOF > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS_EOF

echo "rootパスワードを設定..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "ユーザー作成とパスワード設定..."
useradd -m -G wheel -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd

echo "wheelグループのsudo権限を有効化..."
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

if [ "${AUTO_LOGIN}" == "yes" ]; then
  echo "自動ログイン設定..."
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat <<AUTOLOGIN_CONF_EOF > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USER_NAME} --noclear %I \$TERM
AUTOLOGIN_CONF_EOF
  systemctl enable getty@tty1.service
fi

echo "ネットワークサービス有効化..."
systemctl enable NetworkManager
systemctl enable dhcpcd

echo "GRUBインストール..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
grub-mkconfig -o /boot/grub/grub.cfg

if [ -n "${CHROOT_PACKAGES_TO_INSTALL}" ]; then
  echo "デスクトップ環境など追加パッケージをインストール..."
  pacman -S --noconfirm --needed ${CHROOT_PACKAGES_TO_INSTALL}
fi

if [ -n "${DM_SERVICE_NAME}" ]; then
  echo "ディスプレイマネージャ有効化..."
  systemctl enable ${DM_SERVICE_NAME}
fi

echo "AURヘルパー yay をインストール..."
pacman -S --noconfirm --needed go git
cd /tmp
sudo -u "${USER_NAME}" bash -c 'git clone https://aur.archlinux.org/yay-bin.git || git clone https://aur.archlinux.org/yay.git && cd yay* && makepkg -si --noconfirm && cd .. && rm -rf yay*'

echo "Google Chrome をインストール..."
sudo -u "${USER_NAME}" yay -S --noconfirm google-chrome

if [ "${INSTALL_STEAM}" == "yes" ]; then
  echo "Steamをインストール..."
  sed -i "/\\[multilib\\]/,/Include/"'s/^#//' /etc/pacman.conf
  pacman -Sy --noconfirm
  pacman -S --noconfirm steam
fi

if [ "${INSTALL_PROTONUPQT}" == "yes" ]; then
  echo "ProtonUp-QTをFlatpak経由でインストール..."
  pacman -S --noconfirm --needed flatpak
  sudo -u "${USER_NAME}" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  sudo -u "${USER_NAME}" flatpak install -y --noninteractive flathub com.davidotek.protonup-qt
fi

echo "chroot内の処理が完了しました。"
EOF

# --- 完了メッセージ ---
echo "インストール完了！"
echo "次の手順:"
echo "1. umount -R /mnt"
echo "2. reboot"
