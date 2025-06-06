#!/bin/bash

set -e

CONFIG_FILE="./arch_installer.conf"

# ヘルパー関数
ask_confirm() {
    while true; do
        read -rp "$1 (y/n): " yn
        case $yn in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "yまたはnで答えてください。" ;;
        esac
    done
}

ask_choice() {
    local prompt="$1"
    shift
    local choices=("$@")
    echo "$prompt"
    for i in "${!choices[@]}"; do
        echo "$((i+1))) ${choices[$i]}"
    done
    while true; do
        read -rp "番号を選んで入力してください: " num
        if [[ $num =~ ^[1-9][0-9]*$ ]] && (( num >= 1 && num <= ${#choices[@]} )); then
            echo "${choices[$((num-1))]}"
            return 0
        else
            echo "有効な番号を入力してください"
        fi
    done
}

write_config() {
    cat <<EOF >"$CONFIG_FILE"
DISK=$DISK
CREATE_SWAP=$CREATE_SWAP
SWAP_SIZE=$SWAP_SIZE
USERNAME=$USERNAME
PASSWORD=$PASSWORD
AUTOLOGIN=$AUTOLOGIN
DESKTOP=$DESKTOP
LOGIN_MANAGER=$LOGIN_MANAGER
TERMINAL=$TERMINAL
BROWSER=chrome
INSTALL_STEAM=$INSTALL_STEAM
INSTALL_PROTONUP=$INSTALL_PROTONUP
EOF
}

# ディスク一覧表示
echo "使用可能なディスク:"
lsblk -d -o NAME,SIZE,MODEL
read -rp "インストール先のディスク名(例: sda, nvme0n1など)を入力してください: " DISK

while [[ ! -b "/dev/$DISK" ]]; do
    echo "存在しないディスクです。"
    read -rp "もう一度入力してください: " DISK
done

# スワップパーティション作成有無
if ask_confirm "スワップパーティションを作成しますか？"; then
    CREATE_SWAP="yes"
    read -rp "スワップサイズ(例: 2G, 4096M): " SWAP_SIZE
else
    CREATE_SWAP="no"
    SWAP_SIZE=""
fi

# パーティション作成・フォーマット
echo "/dev/$DISK のパーティションを作成します。"
sgdisk -Z "/dev/$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "/dev/$DISK"
if [[ $CREATE_SWAP == "yes" ]]; then
    sgdisk -n 2:0:-${SWAP_SIZE} -t 2:8300 "/dev/$DISK"
    sgdisk -n 3:0:0 -t 3:8200 "/dev/$DISK"
    ROOT_PART="/dev/${DISK}2"
    SWAP_PART="/dev/${DISK}3"
else
    sgdisk -n 2:0:0 -t 2:8300 "/dev/$DISK"
    ROOT_PART="/dev/${DISK}2"
    SWAP_PART=""
fi
EFI_PART="/dev/${DISK}1"

# パーティション フォーマット
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 "$ROOT_PART"
if [[ $CREATE_SWAP == "yes" ]]; then
    mkswap "$SWAP_PART"
fi

# マウント
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi
if [[ $CREATE_SWAP == "yes" ]]; then
    swapon "$SWAP_PART"
fi

# ベースシステムインストール
pacstrap /mnt base linux linux-firmware networkmanager sudo

# fstab 生成
genfstab -U /mnt >> /mnt/etc/fstab

# ユーザー名・パスワード
read -rp "新しいユーザー名: " USERNAME
read -rsp "パスワード: " PASSWORD
echo

# 自動ログイン
if ask_confirm "自動ログインを有効にしますか？"; then
    AUTOLOGIN="yes"
else
    AUTOLOGIN="no"
fi

# デスクトップ環境, ログインマネージャ, ターミナルエミュレータ選択
DESKTOP=$(ask_choice "デスクトップ環境を選択してください" "gnome" "kde" "xfce" "lxqt" "cinnamon")
LOGIN_MANAGER=$(ask_choice "ログインマネージャを選択してください" "gdm" "sddm" "lightdm" "lxdm" "none")
TERMINAL=$(ask_choice "ターミナルエミュレータを選択してください" "gnome-terminal" "konsole" "xfce4-terminal" "lxterminal" "tilix")

# Chromeインストール固定
# Steam, ProtonUP-QT
INSTALL_STEAM=$(ask_confirm "Steamをインストールしますか？" && echo "yes" || echo "no")
INSTALL_PROTONUP=$(ask_confirm "ProtonUP-QTをインストールしますか？" && echo "yes" || echo "no")

# confファイル書き出し
write_config

# chrootシェルスクリプトを/mnt/root/setup.shとして設置
cp "$(dirname "$0")/arch_installer_chroot.sh" /mnt/root/setup.sh
cp "$CONFIG_FILE" /mnt/root/arch_installer.conf
chmod +x /mnt/root/setup.sh

arch-chroot /mnt /root/setup.sh

echo "インストール完了！再起動してください。"
