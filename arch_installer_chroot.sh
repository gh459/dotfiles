#!/bin/bash

set -e

CONFIG_FILE="/root/arch_installer.conf"
source "$CONFIG_FILE"

# タイムゾーンとロケール
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc
sed -i 's/#ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf

# ホスト名
echo "archlinux" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 archlinux.localdomain archlinux
EOF

# initramfs
mkinitcpio -P

# rootパスワード設定
echo "root:$PASSWORD" | chpasswd

# ユーザー作成
useradd -m -G wheel,audio,video,network -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# ブートローダー
bootctl --path=/boot install
cat <<EOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART") rw
EOF
cat <<EOF > /boot/loader/loader.conf
default arch.conf
timeout 3
console-mode max
editor no
EOF

# ネットワーク
systemctl enable NetworkManager

# デスクトップ環境
case "$DESKTOP" in
    gnome)
        pacman -Sy --noconfirm gnome
        ;;
    kde)
        pacman -Sy --noconfirm plasma kde-applications
        ;;
    xfce)
        pacman -Sy --noconfirm xfce4 xfce4-goodies
        ;;
    lxqt)
        pacman -Sy --noconfirm lxqt
        ;;
    cinnamon)
        pacman -Sy --noconfirm cinnamon
        ;;
esac

# ログインマネージャ
case "$LOGIN_MANAGER" in
    gdm)
        pacman -Sy --noconfirm gdm
        systemctl enable gdm
        ;;
    sddm)
        pacman -Sy --noconfirm sddm
        systemctl enable sddm
        ;;
    lightdm)
        pacman -Sy --noconfirm lightdm lightdm-gtk-greeter
        systemctl enable lightdm
        ;;
    lxdm)
        pacman -Sy --noconfirm lxdm
        systemctl enable lxdm
        ;;
    none)
        ;;
esac

# ターミナル
pacman -Sy --noconfirm "$TERMINAL"

# Chrome (AUR helper: yay)
pacman -Sy --noconfirm git base-devel
sudo -u "$USERNAME" bash << EOF
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
yay -S --noconfirm google-chrome
EOF

# Steam
if [[ $INSTALL_STEAM == "yes" ]]; then
    pacman -Sy --noconfirm steam
fi

# ProtonUP-QT (AUR)
if [[ $INSTALL_PROTONUP == "yes" ]]; then
    sudo -u "$USERNAME" yay -S --noconfirm protonup-qt
fi

# 自動ログイン
if [[ $AUTOLOGIN == "yes" ]]; then
    if [[ $LOGIN_MANAGER == "gdm" ]]; then
        mkdir -p /etc/gdm
        cat <<EOL > /etc/gdm/custom.conf
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = $USERNAME
EOL
    elif [[ $LOGIN_MANAGER == "sddm" ]]; then
        mkdir -p /etc/sddm.conf.d
        cat <<EOL > /etc/sddm.conf.d/autologin.conf
[Autologin]
User=$USERNAME
EOL
    elif [[ $LOGIN_MANAGER == "lightdm" ]]; then
        mkdir -p /etc/lightdm
        sed -i "s/#autologin-user=/autologin-user=$USERNAME/" /etc/lightdm/lightdm.conf
    elif [[ $LOGIN_MANAGER == "lxdm" ]]; then
        sed -i "s/# autologin=dgod/autologin=$USERNAME/" /etc/lxdm/lxdm.conf
    fi
fi

echo "セットアップ完了!"
