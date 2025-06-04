#!/bin/bash
set -euo pipefail # エラー発生時にスクリプトを停止

# --- 初期設定 ---
echo "キーボードレイアウトを日本語に設定します。"
loadkeys jp106

echo "ネットワーク時刻同期を有効にします。"
timedatectl set-ntp true

# --- ディスク設定 ---
echo "利用可能なディスク:"
lsblk -dno NAME,SIZE,MODEL

read -p "インストール先ディスクを選択してください (例: sda, nvme0n1): " INSTALL_DRIVE
TARGET_DEV="/dev/${INSTALL_DRIVE}"

read -p "このディスク (${TARGET_DEV}) のデータを全て消去し、パーティションを作成します。よろしいですか？ (yes/no): " CONFIRM_PARTITION
if [ "$CONFIRM_PARTITION" != "yes" ]; then
    echo "中止します。"
    exit 1
fi

read -p "スワップパーティションを作成しますか？ (yes/no): " CREATE_SWAP
SWAP_SIZE=""
if [ "$CREATE_SWAP" == "yes" ]; then
    read -p "スワップサイズを入力してください (例: 8G, RAMと同容量を推奨): " SWAP_SIZE
fi

echo "パーティションを作成しています..."
sgdisk --zap-all "${TARGET_DEV}"
sgdisk -o "${TARGET_DEV}"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "${TARGET_DEV}"

PART_NUM=2
ROOT_PART_DEV=""
SWAP_PART_DEV=""

if [ "$CREATE_SWAP" == "yes" ]; then
    sgdisk -n ${PART_NUM}:0:+${SWAP_SIZE} -t ${PART_NUM}:8200 -c ${PART_NUM}:"Linux swap" "${TARGET_DEV}"
    SWAP_PART_DEV="${TARGET_DEV}${PART_NUM}"
    PART_NUM=$((PART_NUM + 1))
fi

sgdisk -n ${PART_NUM}:0:0 -t ${PART_NUM}:8300 -c ${PART_NUM}:"Linux root" "${TARGET_DEV}"
ROOT_PART_DEV="${TARGET_DEV}${PART_NUM}"
EFI_PART_DEV="${TARGET_DEV}1"

partprobe "${TARGET_DEV}"
sleep 2

echo "ファイルシステムを作成しています..."
mkfs.fat -F32 "${EFI_PART_DEV}"
if [ "$CREATE_SWAP" == "yes" ]; then
    mkswap "${SWAP_PART_DEV}"
fi
mkfs.ext4 -F "${ROOT_PART_DEV}"

echo "パーティションをマウントしています..."
mount "${ROOT_PART_DEV}" /mnt
mkdir -p /mnt/boot
mount "${EFI_PART_DEV}" /mnt/boot
if [ "$CREATE_SWAP" == "yes" ]; then
    swapon "${SWAP_PART_DEV}"
fi

echo "ミラーリストを同期し、キーリングを初期化・更新します..."
pacman -Syy --noconfirm
pacman -S --noconfirm archlinux-keyring
pacman-key --init
pacman-key --populate archlinux

echo "ベースシステムと必須パッケージをインストールしています..."
pacstrap /mnt base linux linux-firmware base-devel git sudo nano networkmanager grub efibootmgr dhcpcd

echo "fstabを生成しています..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "システム設定情報を入力してください。"
read -p "作成するユーザー名: " USER_NAME
read -sp "作成するユーザーのパスワード: " USER_PASSWORD
echo
read -sp "rootユーザーのパスワード: " ROOT_PASSWORD
echo
read -p "ホスト名: " HOST_NAME
read -p "自動ログインを有効にしますか？ (yes/no): " AUTO_LOGIN

echo "デスクトップ環境を選択してください:"
DE_OPTIONS=("GNOME" "KDE Plasma" "XFCE" "LXQt" "Cinnamon" "なし")
select SELECTED_DE in "${DE_OPTIONS[@]}"; do
    if [[ " ${DE_OPTIONS[*]} " =~ " ${SELECTED_DE} " ]]; then
        break
    else
        echo "無効な選択です。"
    fi
done

SELECTED_DM=""
DM_SERVICE_NAME=""
if [ "$SELECTED_DE" != "なし" ]; then
    echo "ディスプレイマネージャーを選択してください:"
    DM_OPTIONS=("GDM (GNOME推奨)" "SDDM (KDE Plasma推奨)" "LightDM (軽量)" "LXDM (LXQt/LXDE推奨)" "なし (手動でstartx)")
    select SELECTED_DM_RAW in "${DM_OPTIONS[@]}"; do
        if [[ " ${DM_OPTIONS[*]} " =~ " ${SELECTED_DM_RAW} " ]]; then
            case "$SELECTED_DM_RAW" in
                "GDM (GNOME推奨)") SELECTED_DM="gdm"; DM_SERVICE_NAME="gdm.service";;
                "SDDM (KDE Plasma推奨)") SELECTED_DM="sddm"; DM_SERVICE_NAME="sddm.service";;
                "LightDM (軽量)") SELECTED_DM="lightdm lightdm-gtk-greeter"; DM_SERVICE_NAME="lightdm.service";;
                "LXDM (LXQt/LXDE推奨)") SELECTED_DM="lxdm"; DM_SERVICE_NAME="lxdm.service";;
                "なし (手動でstartx)") SELECTED_DM=""; DM_SERVICE_NAME="";;
            esac
            break
        else
            echo "無効な選択です。"
        fi
    done
fi

echo "ターミナルエミュレータを選択してください:"
TERM_OPTIONS=("gnome-terminal (GNOME)" "konsole (KDE)" "xfce4-terminal (XFCE)" "lxterminal (LXDE/LXQt)" "alacritty (軽量/GPU)" "なし")
select SELECTED_TERM in "${TERM_OPTIONS[@]}"; do
    if [[ " ${TERM_OPTIONS[*]} " =~ " ${SELECTED_TERM} " ]]; then
        break
    else
        echo "無効な選択です。"
    fi
done

read -p "Steamをインストールしますか？ (yes/no): " INSTALL_STEAM
read -p "ProtonUp-QTをインストールしますか？ (yes/no): " INSTALL_PROTONUPQT

echo "chrootスクリプトを生成しています..."
cat <<CHROOT_SCRIPT > /mnt/arch-chroot-script.sh
#!/bin/bash
set -euo pipefail

echo "chroot環境内でパッケージキャッシュをクリアし、キーリングを更新します..."
pacman -Scc --noconfirm
pacman -Sy --noconfirm archlinux-keyring

echo "タイムゾーンを設定 (Asia/Tokyo)"
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

echo "ロケールを設定 (ja_JP.UTF-8, en_US.UTF-8)"
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf

echo "ホスト名を設定: ${HOST_NAME}"
echo "${HOST_NAME}" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS

echo "rootパスワードを設定します..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "ユーザー '${USER_NAME}' を作成し、パスワードを設定します..."
useradd -m -G wheel -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
echo "ユーザー '${USER_NAME}' のsudo権限を有効化します (wheelグループのコメント解除)"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

if [ "${AUTO_LOGIN}" == "yes" ]; then
    echo "コンソールへの自動ログインを設定します..."
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat <<AUTOLOGIN_CONF > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USER_NAME} --noclear %I \$TERM
AUTOLOGIN_CONF
    systemctl enable getty@tty1.service
    echo "コンソールへの自動ログインが設定されました。ディスプレイマネージャーの自動ログインは別途設定が必要な場合があります。"
fi

echo "ネットワークマネージャーを有効化します..."
systemctl enable NetworkManager
systemctl enable dhcpcd

echo "ブートローダー (GRUB) をインストールし設定します..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# --- デスクトップ環境、ディスプレイマネージャー、ターミナルのインストール ---
DE_PACKAGE=""
case "${SELECTED_DE}" in
    "GNOME") DE_PACKAGE="gnome";;
    "KDE Plasma") DE_PACKAGE="plasma kde-applications";;
    "XFCE") DE_PACKAGE="xfce4 xfce4-goodies";;
    "LXQt") DE_PACKAGE="lxqt breeze-icons oxygen-icons";;
    "Cinnamon") DE_PACKAGE="cinnamon";;
    "なし") ;;
esac

DM_PACKAGE="${SELECTED_DM}"
TERM_PACKAGE_NAME=""
case "${SELECTED_TERM}" in
    "gnome-terminal (GNOME)") TERM_PACKAGE_NAME="gnome-terminal";;
    "konsole (KDE)") TERM_PACKAGE_NAME="konsole";;
    "xfce4-terminal (XFCE)") TERM_PACKAGE_NAME="xfce4-terminal";;
    "lxterminal (LXDE/LXQt)") TERM_PACKAGE_NAME="lxterminal";;
    "alacritty (軽量/GPU)") TERM_PACKAGE_NAME="alacritty";;
    "なし") ;;
esac

INSTALL_PACKAGES=""
if [ -n "\$DE_PACKAGE" ]; then INSTALL_PACKAGES="\$DE_PACKAGE"; fi
if [ -n "\$DM_PACKAGE" ]; then INSTALL_PACKAGES="\$INSTALL_PACKAGES \$DM_PACKAGE"; fi
if [ -n "\$TERM_PACKAGE_NAME" ]; then INSTALL_PACKAGES="\$INSTALL_PACKAGES \$TERM_PACKAGE_NAME"; fi

# <<< 修正点 >>>
# D-Bus関連エラー ("The name is not activatable") 対策として gnome-keyring を常に追加
# libsecret (gnome-keyringが提供) は多くのアプリケーションで認証情報管理に使われる [1][4]
INSTALL_PACKAGES="\$INSTALL_PACKAGES gnome-keyring"

if [ -n "\$INSTALL_PACKAGES" ]; then
    # 不要なスペースを削除し、パッケージリストを整形
    INSTALL_PACKAGES=\$(echo \$INSTALL_PACKAGES | xargs)
    echo "選択されたデスクトップ関連パッケージとgnome-keyringをインストールします: \$INSTALL_PACKAGES"
    pacman -S --noconfirm --needed \$INSTALL_PACKAGES
fi
# <<< 修正点ここまで >>>

if [ -n "${DM_SERVICE_NAME}" ]; then
    echo "ディスプレイマネージャーサービス (${DM_SERVICE_NAME}) を有効化します..."
    systemctl enable "${DM_SERVICE_NAME}"
fi

echo "AURヘルパー (yay) をインストールします..."
pacman -S --noconfirm --needed go
cd /tmp
sudo -u "${USER_NAME}" bash -c 'git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay'

echo "Google Chrome をインストールします..."
sudo -u "${USER_NAME}" yay -S --noconfirm google-chrome

if [ "${INSTALL_STEAM}" == "yes" ]; then
    echo "Steam をインストールします..."
    sed -i "/\\[multilib\\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Sy --noconfirm
    pacman -S --noconfirm steam
fi

if [ "${INSTALL_PROTONUPQT}" == "yes" ]; then
    echo "ProtonUp-QT をインストールします (Flatpak経由)..."
    pacman -S --noconfirm flatpak
    sudo -u "${USER_NAME}" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    sudo -u "${USER_NAME}" flatpak install -y --noninteractive flathub com.davidotek.protonup-qt
    echo "ProtonUp-QTがFlatpak経由でインストールされました。"
fi

echo "chrootスクリプトの処理が完了しました。"
echo "システムを再起動する準備ができました。"
echo "chroot環境から抜けるには 'exit' と入力し、その後ホストシステムで 'umount -R /mnt' を実行し、'reboot' してください。"

CHROOT_SCRIPT

chmod +x /mnt/arch-chroot-script.sh

echo "chroot環境に入り、設定スクリプトを実行します..."
arch-chroot /mnt /arch-chroot-script.sh

echo "インストール処理が完了しました。"
echo "アンマウントと再起動を行ってください。"
echo "1. exit (もしchroot環境内にまだいる場合)"
echo "2. umount -R /mnt"
echo "3. reboot"
