#!/bin/bash

# Arch Linux 一括インストールスクリプト
# rootユーザーで実行してください

set -e

# --- 文字化け防止 ---
export LANG=ja_JP.UTF-8
export LC_ALL=ja_JP.UTF-8

# --- ディスク選択 ---
echo "ディスク一覧:"
lsblk -d -o NAME,SIZE,MODEL
read -rp "インストールするディスク名 (例: sda): " DISK

# --- スワップパーティション作成有無 ---
while true; do
    read -rp "スワップパーティションを作成しますか？ (y/n): " CREATE_SWAP
    case "$CREATE_SWAP" in
        [Yy]*) SWAP="yes"; break ;;
        [Nn]*) SWAP="no"; break ;;
        *) echo "yまたはnで答えてください。" ;;
    esac
done

# --- ユーザー名とパスワード ---
read -rp "新規ユーザー名: " USERNAME
while true; do
    read -rsp "ユーザーのパスワード: " USERPASS
    echo
    read -rsp "パスワード再入力: " USERPASS2
    echo
    [ "$USERPASS" = "$USERPASS2" ] && break
    echo "パスワードが一致しません。"
done

# --- 自動ログイン有無 ---
while true; do
    read -rp "自動ログインを有効にしますか？ (y/n): " AUTOLOGIN
    case "$AUTOLOGIN" in
        [Yy]*) AUTOLOGIN="yes"; break ;;
        [Nn]*) AUTOLOGIN="no"; break ;;
        *) echo "yまたはnで答えてください。" ;;
    esac
done

# --- デスクトップ環境選択 ---
DE_OPTIONS=("GNOME" "KDE Plasma" "XFCE" "Cinnamon" "MATE")
echo "デスクトップ環境を選択してください:"
select DE in "${DE_OPTIONS[@]}"; do
    [ -n "$DE" ] && break
done

# --- ログイン環境（ディスプレイマネージャ）選択 ---
DM_OPTIONS=("GDM" "SDDM" "LightDM" "LXDM" "None")
echo "ディスプレイマネージャを選択してください:"
select DM in "${DM_OPTIONS[@]}"; do
    [ -n "$DM" ] && break
done

# --- ターミナルエミュレータ選択 ---
TERM_OPTIONS=("gnome-terminal" "konsole" "xfce4-terminal" "lxterminal" "mate-terminal")
echo "ターミナルエミュレータを選択してください:"
select TERMINAL in "${TERM_OPTIONS[@]}"; do
    [ -n "$TERMINAL" ] && break
done

# --- STEAM/PROTONUP-QT ---
while true; do
    read -rp "STEAMをインストールしますか？ (y/n): " INSTALL_STEAM
    case "$INSTALL_STEAM" in
        [Yy]*) INSTALL_STEAM="yes"; break ;;
        [Nn]*) INSTALL_STEAM="no"; break ;;
        *) echo "yまたはnで答えてください。" ;;
    esac
done

while true; do
    read -rp "PROTONUP-QTをインストールしますか？ (y/n): " INSTALL_PROTON
    case "$INSTALL_PROTON" in
        [Yy]*) INSTALL_PROTON="yes"; break ;;
        [Nn]*) INSTALL_PROTON="no"; break ;;
        *) echo "yまたはnで答えてください。" ;;
    esac
done

# --- パーティション・フォーマット・マウント ---
echo "ディスクのパーティションとフォーマットを開始します。"
umount -A --recursive /mnt || true

sgdisk -Z "/dev/$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "/dev/$DISK"
if [ "$SWAP" = "yes" ]; then
    sgdisk -n 2:0:+4G -t 2:8200 -c 2:"SWAP" "/dev/$DISK"
    sgdisk -n 3:0:0 -t 3:8300 -c 3:"ROOT" "/dev/$DISK"
else
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "/dev/$DISK"
fi

sync

# --- フォーマット ---
mkfs.fat -F32 "/dev/${DISK}1"
if [ "$SWAP" = "yes" ]; then
    mkswap "/dev/${DISK}2"
    mkfs.ext4 "/dev/${DISK}3"
else
    mkfs.ext4 "/dev/${DISK}2"
fi

# --- マウント ---
if [ "$SWAP" = "yes" ]; then
    mount "/dev/${DISK}3" /mnt
    swapon "/dev/${DISK}2"
else
    mount "/dev/${DISK}2" /mnt
fi
mkdir -p /mnt/boot/efi
mount "/dev/${DISK}1" /mnt/boot/efi

# --- ベースシステムインストール ---
pacstrap /mnt base linux linux-firmware networkmanager sudo

# --- fstab生成 ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- chroot用スクリプト生成 ---
cat << EOF > /mnt/install_in_chroot.sh
#!/bin/bash
set -e

ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

sed -i 's/#ja_JP.UTF-8/ja_JP.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf

echo archlinux > /etc/hostname

echo -e "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\tarchlinux.localdomain\tarchlinux" >> /etc/hosts

echo "root:root" | chpasswd

useradd -m -G wheel,audio,video $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd

sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

# デスクトップ環境
case "$DE" in
    "GNOME") pacman -Sy --noconfirm gnome gnome-tweaks ;;
    "KDE Plasma") pacman -Sy --noconfirm plasma kde-applications ;;
    "XFCE") pacman -Sy --noconfirm xfce4 xfce4-goodies ;;
    "Cinnamon") pacman -Sy --noconfirm cinnamon ;;
    "MATE") pacman -Sy --noconfirm mate mate-extra ;;
esac

# ディスプレイマネージャ
case "$DM" in
    "GDM") pacman -Sy --noconfirm gdm && systemctl enable gdm ;;
    "SDDM") pacman -Sy --noconfirm sddm && systemctl enable sddm ;;
    "LightDM") pacman -Sy --noconfirm lightdm lightdm-gtk-greeter && systemctl enable lightdm ;;
    "LXDM") pacman -Sy --noconfirm lxdm && systemctl enable lxdm ;;
    "None") ;;
esac

# ターミナルエミュレータ
case "$TERMINAL" in
    "gnome-terminal") pacman -Sy --noconfirm gnome-terminal ;;
    "konsole") pacman -Sy --noconfirm konsole ;;
    "xfce4-terminal") pacman -Sy --noconfirm xfce4-terminal ;;
    "lxterminal") pacman -Sy --noconfirm lxterminal ;;
    "mate-terminal") pacman -Sy --noconfirm mate-terminal ;;
esac

# ブラウザ
pacman -Sy --noconfirm google-chrome

# STEAM
if [ "$INSTALL_STEAM" = "yes" ]; then
    pacman -Sy --noconfirm steam
fi

# PROTONUP-QT
if [ "$INSTALL_PROTON" = "yes" ]; then
    pacman -Sy --noconfirm protonup-qt
fi

# ブートローダー
pacman -Sy --noconfirm grub efibootmgr os-prober
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

if [ "$AUTOLOGIN" = "yes" ]; then
    if [ "$DM" = "GDM" ]; then
        mkdir -p /etc/gdm
        echo -e "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$USERNAME" > /etc/gdm/custom.conf
    elif [ "$DM" = "SDDM" ]; then
        sed -i "/^User=/c User=$USERNAME" /etc/sddm.conf || echo -e "[Autologin]\nUser=$USERNAME" >> /etc/sddm.conf
    elif [ "$DM" = "LightDM" ]; then
        mkdir -p /etc/lightdm
        echo -e "[Seat:*]\nautologin-user=$USERNAME" >> /etc/lightdm/lightdm.conf
    fi
fi

EOF

chmod +x /mnt/install_in_chroot.sh

arch-chroot /mnt /install_in_chroot.sh

rm /mnt/install_in_chroot.sh

echo "インストール完了。アンマウント後、再起動してください。"
