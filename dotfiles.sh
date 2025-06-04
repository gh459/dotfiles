#!/bin/bash
set -euo pipefail # エラー発生時にスクリプトを停止

# --- 初期設定 ---
echo "キーボードレイアウトを日本語に設定します。"
loadkeys jp106

echo "ネットワーク時刻同期を有効にします。"
timedatectl set-ntp true

# --- ディスク設定 ---
echo "利用可能なディスク:"
lsblk -dno NAME,SIZE,MODEL # ディスク一覧を表示[4][15] (旧ソースからの引用)

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
# UEFIシステムを想定
# 既存のパーティション情報を消去
sgdisk --zap-all "${TARGET_DEV}" # ディスクの全パーティション情報を消去[13] (旧ソースからの引用)

# GPTパーティションテーブルを作成
sgdisk -o "${TARGET_DEV}" # GPTラベルを作成[5] (旧ソースからの引用)

# EFIシステムパーティション (ESP) を作成
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "${TARGET_DEV}"

# パーティション番号の管理
PART_NUM=2
ROOT_PART_DEV=""
SWAP_PART_DEV=""

if [ "$CREATE_SWAP" == "yes" ]; then
    # スワップパーティションを作成
    sgdisk -n ${PART_NUM}:0:+${SWAP_SIZE} -t ${PART_NUM}:8200 -c ${PART_NUM}:"Linux swap" "${TARGET_DEV}"
    SWAP_PART_DEV="${TARGET_DEV}${PART_NUM}"
    PART_NUM=$((PART_NUM + 1))
fi

# ルートパーティションを作成 (残りの全領域)
sgdisk -n ${PART_NUM}:0:0 -t ${PART_NUM}:8300 -c ${PART_NUM}:"Linux root" "${TARGET_DEV}"
ROOT_PART_DEV="${TARGET_DEV}${PART_NUM}"
EFI_PART_DEV="${TARGET_DEV}1" # EFIパーティションは常に1番

# パーティション変更をカーネルに認識させる
partprobe "${TARGET_DEV}"
sleep 2 # 念のため待機

echo "ファイルシステムを作成しています..."
mkfs.fat -F32 "${EFI_PART_DEV}" # EFIパーティションをFAT32でフォーマット[13] (旧ソースからの引用)

if [ "$CREATE_SWAP" == "yes" ]; then
    mkswap "${SWAP_PART_DEV}" # スワップパーティションをフォーマット[13] (旧ソースからの引用)
fi

mkfs.ext4 -F "${ROOT_PART_DEV}" # ルートパーティションをext4でフォーマット[13] (旧ソースからの引用)

echo "パーティションをマウントしています..."
mount "${ROOT_PART_DEV}" /mnt
mkdir -p /mnt/boot
mount "${EFI_PART_DEV}" /mnt/boot

if [ "$CREATE_SWAP" == "yes" ]; then
    swapon "${SWAP_PART_DEV}" # スワップを有効化
fi

# --- キーリングとパッケージデータベースの準備 ---
echo "ミラーリストを同期し、キーリングを初期化・更新します..."
pacman -Syy --noconfirm # ミラーリスト強制同期 [4]
pacman -S --noconfirm archlinux-keyring # キーリングパッケージ更新 [2][4][9]
pacman-key --init # キーリング初期化 [9]
pacman-key --populate archlinux # Arch Linuxキーをインポート [1][9]

# --- ベースシステムのインストール ---
echo "ベースシステムと必須パッケージをインストールしています..."
# 必要なパッケージ: 基本システム、カーネル、ファームウェア、開発ツール、git、sudo、テキストエディタ、ネットワーク管理、ブートローダー
pacstrap /mnt base linux linux-firmware base-devel git sudo nano networkmanager grub efibootmgr dhcpcd

# --- fstabの生成 ---
echo "fstabを生成しています..."
genfstab -U /mnt >> /mnt/etc/fstab # fstabを生成[13] (旧ソースからの引用)

# --- chrootスクリプトのための情報収集 ---
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


# --- chrootスクリプトの作成と実行 ---
echo "chrootスクリプトを生成しています..."
cat <<CHROOT_SCRIPT > /mnt/arch-chroot-script.sh
#!/bin/bash
set -euo pipefail

# --- chroot環境内でのキーリングとキャッシュの整備 ---
echo "chroot環境内でパッケージキャッシュをクリアし、キーリングを更新します..."
pacman -Scc --noconfirm # キャッシュを全てクリア [5]
pacman -Sy --noconfirm archlinux-keyring # キーリングを更新 [2][4][9]
# pacman-key --init # chroot環境では不要な場合が多いが、念のためコメントアウト
# pacman-key --populate archlinux # 同上

echo "タイムゾーンを設定 (Asia/Tokyo)"
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

echo "ロケールを設定 (ja_JP.UTF-8, en_US.UTF-8)"
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf # コンソールキーマップ

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
useradd -m -G wheel -s /bin/bash "${USER_NAME}" # wheelグループに追加[6][17] (旧ソースからの引用)
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
echo "ユーザー '${USER_NAME}' のsudo権限を有効化します (wheelグループのコメント解除)"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers # wheelグループのsudo権限を有効化

if [ "${AUTO_LOGIN}" == "yes" ]; then
    echo "コンソールへの自動ログインを設定します..."
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat <<AUTOLOGIN_CONF > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USER_NAME} --noclear %I \$TERM
AUTOLOGIN_CONF
    systemctl enable getty@tty1.service # 自動ログインサービス有効化[7][18] (旧ソースからの引用)
    echo "コンソールへの自動ログインが設定されました。ディスプレイマネージャーの自動ログインは別途設定が必要な場合があります。"
fi

echo "ネットワークマネージャーを有効化します..."
systemctl enable NetworkManager
systemctl enable dhcpcd # 有線LANのDHCPクライアント

echo "ブートローダー (GRUB) をインストールし設定します..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck # GRUBインストール[13] (旧ソースからの引用)
grub-mkconfig -o /boot/grub/grub.cfg # GRUB設定ファイル生成[13] (旧ソースからの引用)

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

if [ -n "\$INSTALL_PACKAGES" ]; then
    echo "選択されたデスクトップ関連パッケージをインストールします: \$INSTALL_PACKAGES"
    pacman -S --noconfirm --needed \$INSTALL_PACKAGES
fi

if [ -n "${DM_SERVICE_NAME}" ]; then
    echo "ディスプレイマネージャーサービス (${DM_SERVICE_NAME}) を有効化します..."
    systemctl enable "${DM_SERVICE_NAME}" # ディスプレイマネージャーサービス有効化[8] (旧ソースからの引用)
fi

# --- 追加ソフトウェアのインストール ---
echo "AURヘルパー (yay) をインストールします..."
pacman -S --noconfirm --needed go # goはyayのビルドに必要
cd /tmp
sudo -u "${USER_NAME}" bash -c 'git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay' # yayのインストール[9][19] (旧ソースからの引用)

echo "Google Chrome をインストールします..."
sudo -u "${USER_NAME}" yay -S --noconfirm google-chrome # Chromeインストール[9][19] (旧ソースからの引用)

if [ "${INSTALL_STEAM}" == "yes" ]; then
    echo "Steam をインストールします..."
    # multilibリポジトリを有効化
    sed -i "/\\[multilib\\]/,/Include/"'s/^#//' /etc/pacman.conf # multilib有効化[10][20] (旧ソースからの引用)
    pacman -Sy --noconfirm # パッケージデータベース同期
    pacman -S --noconfirm steam # Steamインストール[10][20] (旧ソースからの引用)
fi

if [ "${INSTALL_PROTONUPQT}" == "yes" ]; then
    echo "ProtonUp-QT をインストールします (Flatpak経由)..."
    pacman -S --noconfirm flatpak # Flatpakインストール
    sudo -u "${USER_NAME}" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo # Flathubリポジトリ追加
    sudo -u "${USER_NAME}" flatpak install -y --noninteractive flathub com.davidotek.protonup-qt # ProtonUp-QTインストール[11] (旧ソースからの引用)
    echo "ProtonUp-QTがFlatpak経由でインストールされました。"
fi

echo "chrootスクリプトの処理が完了しました。"
echo "システムを再起動する準備ができました。"
echo "chroot環境から抜けるには 'exit' と入力し、その後ホストシステムで 'umount -R /mnt' を実行し、'reboot' してください。"

CHROOT_SCRIPT

chmod +x /mnt/arch-chroot-script.sh

echo "chroot環境に入り、設定スクリプトを実行します..."
arch-chroot /mnt /arch-chroot-script.sh

# --- 後処理 ---
echo "インストール処理が完了しました。"
echo "アンマウントと再起動を行ってください。"
echo "1. exit (もしchroot環境内にまだいる場合)"
echo "2. umount -R /mnt"
echo "3. reboot"
