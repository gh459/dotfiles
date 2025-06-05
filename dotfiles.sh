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
sgdisk -o "${TARGET_DEV}" # GPTを作成
# EFIシステムパーティション
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "${TARGET_DEV}"

PART_NUM=2 # 次のパーティション番号
ROOT_PART_DEV=""
SWAP_PART_DEV=""
EFI_PART_DEV=""

# パーティションデバイス名の決定 (nvme/mmcblk と sda/hda で命名規則が異なるため)
if [[ "${TARGET_DEV}" == *nvme* || "${TARGET_DEV}" == *mmcblk* ]]; then
    EFI_PART_DEV="${TARGET_DEV}p1"
else
    EFI_PART_DEV="${TARGET_DEV}1"
fi

if [ "$CREATE_SWAP" == "yes" ]; then
    sgdisk -n ${PART_NUM}:0:+${SWAP_SIZE} -t ${PART_NUM}:8200 -c ${PART_NUM}:"Linux swap" "${TARGET_DEV}"
    if [[ "${TARGET_DEV}" == *nvme* || "${TARGET_DEV}" == *mmcblk* ]]; then
        SWAP_PART_DEV="${TARGET_DEV}p${PART_NUM}"
    else
        SWAP_PART_DEV="${TARGET_DEV}${PART_NUM}"
    fi
    PART_NUM=$((PART_NUM + 1))
fi

# ルートパーティション (残りの全領域)
sgdisk -n ${PART_NUM}:0:0 -t ${PART_NUM}:8300 -c ${PART_NUM}:"Linux root" "${TARGET_DEV}"
if [[ "${TARGET_DEV}" == *nvme* || "${TARGET_DEV}" == *mmcblk* ]]; then
    ROOT_PART_DEV="${TARGET_DEV}p${PART_NUM}"
else
    ROOT_PART_DEV="${TARGET_DEV}${PART_NUM}"
fi

partprobe "${TARGET_DEV}" # パーティションテーブルの再読み込み
sleep 2 # 変更がシステムに認識されるのを待つ

echo "ファイルシステムを作成しています..."
mkfs.fat -F32 "${EFI_PART_DEV}"
if [ "$CREATE_SWAP" == "yes" ]; then
    mkswap "${SWAP_PART_DEV}"
fi
mkfs.ext4 -F "${ROOT_PART_DEV}" # -F オプションで強制実行

echo "パーティションをマウントしています..."
mount "${ROOT_PART_DEV}" /mnt
mkdir -p /mnt/boot # /mnt/boot が存在しない場合作成
mount "${EFI_PART_DEV}" /mnt/boot
if [ "$CREATE_SWAP" == "yes" ]; then
    swapon "${SWAP_PART_DEV}"
fi

echo "ミラーリストを同期し、キーリングを初期化・更新します..."
pacman -Syy --noconfirm
pacman -S --noconfirm archlinux-keyring # キーリングの更新
# pacman-key --init # 必須ではないことが多いが、問題が発生した場合に試す
# pacman-key --populate archlinux

echo "ベースシステムと必須パッケージをインストールしています..."
pacstrap /mnt base linux linux-firmware base-devel git sudo nano networkmanager grub efibootmgr # dhcpcdはNetworkManagerと併用する場合注意

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

SELECTED_DM_PKG_NAME="" # インストールするDMのパッケージ名
DM_SERVICE_NAME=""      # 有効化するDMのサービス名

if [ "$SELECTED_DE" != "なし" ]; then
    echo "ディスプレイマネージャーを選択してください:"
    # 選択肢 (表示名、パッケージ名、サービス名)
    DM_OPTIONS_DISPLAY=("GDM (GNOME推奨)" "SDDM (KDE Plasma推奨)" "LightDM (XFCE/LXQt/Cinnamon等)" "LXDM (LXQt/LXDE推奨)" "なし (手動でstartx)")
    DM_OPTIONS_PKG=("gdm" "sddm" "lightdm lightdm-gtk-greeter" "lxdm" "")
    DM_OPTIONS_SERVICE=("gdm.service" "sddm.service" "lightdm.service" "lxdm.service" "")

    select SELECTED_DM_DISPLAY_NAME in "${DM_OPTIONS_DISPLAY[@]}"; do
        REPLY_INDEX=$((REPLY - 1)) # select の REPLY は 1-indexed なので調整
        if [ "${REPLY_INDEX}" -ge 0 ] && [ "${REPLY_INDEX}" -lt "${#DM_OPTIONS_PKG[@]}" ]; then
            SELECTED_DM_PKG_NAME="${DM_OPTIONS_PKG[REPLY_INDEX]}"
            DM_SERVICE_NAME="${DM_OPTIONS_SERVICE[REPLY_INDEX]}"
            break
        else
            echo "無効な選択です。"
        fi
    done
fi

echo "ターミナルエミュレータを選択してください:"
TERM_OPTIONS_DISPLAY=("gnome-terminal (GNOME)" "konsole (KDE)" "xfce4-terminal (XFCE)" "lxterminal (LXDE/LXQt)" "alacritty (軽量/GPU)" "なし")
TERM_OPTIONS_PKG=("gnome-terminal" "konsole" "xfce4-terminal" "lxterminal" "alacritty" "")
SELECTED_TERM_PKG_NAME=""
select SELECTED_TERM_DISPLAY_NAME in "${TERM_OPTIONS_DISPLAY[@]}"; do
    REPLY_INDEX=$((REPLY - 1))
    if [ "${REPLY_INDEX}" -ge 0 ] && [ "${REPLY_INDEX}" -lt "${#TERM_OPTIONS_PKG[@]}" ]; then
        SELECTED_TERM_PKG_NAME="${TERM_OPTIONS_PKG[REPLY_INDEX]}"
        break
    else
        echo "無効な選択です。"
    fi
done

read -p "Steamをインストールしますか？ (yes/no): " INSTALL_STEAM
read -p "ProtonUp-QTをインストールしますか？ (yes/no): " INSTALL_PROTONUPQT

echo "chrootスクリプトを生成しています..."
# --- ここから chroot スクリプト ---
cat << CHROOT_SCRIPT_EOF > /mnt/arch-chroot-script.sh
#!/bin/bash
set -euo pipefail

echo "chroot環境内でパッケージキャッシュをクリアし、キーリングを更新します..."
pacman -Scc --noconfirm
pacman -Sy --noconfirm archlinux-keyring # 念のため

echo "タイムゾーンを設定 (Asia/Tokyo)"
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

echo "ロケールを設定 (ja_JP.UTF-8, en_US.UTF-8)"
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf # TTY用キーマップ

echo "ホスト名を設定: ${HOST_NAME}"
echo "${HOST_NAME}" > /etc/hostname

# /etc/hosts の設定
cat << HOSTS_EOF > /etc/hosts
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS_EOF

echo "rootパスワードを設定します..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "ユーザー '${USER_NAME}' を作成し、パスワードを設定します..."
useradd -m -G wheel -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd

echo "ユーザー '${USER_NAME}' のsudo権限を有効化します (wheelグループのコメント解除)"
# 両方の形式に対応
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers


if [ "${AUTO_LOGIN}" == "yes" ]; then
    echo "コンソールへの自動ログインを設定します..."
    mkdir -p /etc/systemd/system/getty@tty1.service.d
cat << AUTOLOGIN_CONF_EOF > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USER_NAME} --noclear %I \$TERM
AUTOLOGIN_CONF_EOF
    systemctl enable getty@tty1.service
    echo "コンソールへの自動ログインが設定されました。ディスプレイマネージャーの自動ログインは別途設定が必要な場合があります。"
fi

echo "ネットワークマネージャーを有効化します..."
systemctl enable NetworkManager.service
# systemctl enable dhcpcd.service # NetworkManagerを使用する場合、通常これは不要

echo "ブートローダー (GRUB) をインストールし設定します..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# --- デスクトップ環境、ディスプレイマネージャー、ターミナルのインストール ---
# メインスクリプトから渡された選択肢に基づいてパッケージ名を決定
# ${SELECTED_DE}, ${SELECTED_DM_PKG_NAME}, ${SELECTED_TERM_PKG_NAME} はヒアドキュメント内でメインスクリプトの値に展開される
DE_PKG_TO_INSTALL=""
case "${SELECTED_DE}" in
    "GNOME") DE_PKG_TO_INSTALL="gnome";;
    "KDE Plasma") DE_PKG_TO_INSTALL="plasma kde-applications";;
    "XFCE") DE_PKG_TO_INSTALL="xfce4 xfce4-goodies";;
    "LXQt") DE_PKG_TO_INSTALL="lxqt breeze-icons oxygen-icons xdg-utils";;
    "Cinnamon") DE_PKG_TO_INSTALL="cinnamon";;
esac

DM_PKG_TO_INSTALL="${SELECTED_DM_PKG_NAME}"
TERM_PKG_TO_INSTALL="${SELECTED_TERM_PKG_NAME}"

# インストールするパッケージのリストを構築 (chrootスクリプト内変数)
# ヒアドキュメント内では、chrootスクリプトの変数を参照するために \$ を使用
CHROOT_PACKAGES=""
if [ -n "\${DE_PKG_TO_INSTALL}" ]; then CHROOT_PACKAGES="\${DE_PKG_TO_INSTALL}"; fi
if [ -n "\${DM_PKG_TO_INSTALL}" ]; then CHROOT_PACKAGES="\${CHROOT_PACKAGES} \${DM_PKG_TO_INSTALL}"; fi
if [ -n "\${TERM_PKG_TO_INSTALL}" ]; then CHROOT_PACKAGES="\${CHROOT_PACKAGES} \${TERM_PKG_TO_INSTALL}"; fi

# gnome-keyring を常に追加 (libsecretを提供し、多くのアプリで認証情報管理に使われる)
CHROOT_PACKAGES="\${CHROOT_PACKAGES} gnome-keyring"

if [ -n "\${CHROOT_PACKAGES}" ]; then
    CHROOT_PACKAGES=\$(echo "\${CHROOT_PACKAGES}" | xargs) # 先頭・末尾の空白削除、連続空白を1つに
    if [ -n "\${CHROOT_PACKAGES}" ]; then # xargs の結果が空でないことを確認
        echo "選択されたデスクトップ関連パッケージとgnome-keyringをインストールします: \${CHROOT_PACKAGES}"
        pacman -S --noconfirm --needed \${CHROOT_PACKAGES}
    else
        # このケースはCHROOT_PACKAGESがスペースのみだった場合。通常は発生しにくいが念のため。
        # gnome-keyring は必ずインストールされる想定なので、それが単独で残る場合はそれをインストール。
        echo "インストールするデスクトップ関連パッケージはありませんでしたが、gnome-keyringをインストールします。"
        pacman -S --noconfirm --needed gnome-keyring
    fi
else
    # CHROOT_PACKAGES が完全に空（ありえないはずだが）の場合でも gnome-keyring はインストール
    echo "デスクトップ関連パッケージは選択されませんでしたが、gnome-keyringをインストールします。"
    pacman -S --noconfirm --needed gnome-keyring
fi

if [ -n "${DM_SERVICE_NAME}" ]; then # ${DM_SERVICE_NAME} はメインスクリプトの値に展開される
    echo "ディスプレイマネージャーサービス (${DM_SERVICE_NAME}) を有効化します..."
    systemctl enable "${DM_SERVICE_NAME}"
fi

echo "AURヘルパー (yay-bin) をインストールします..."
# go は base-devel に含まれているはず
# pacman -S --noconfirm --needed go
cd /tmp
# sudo -u でユーザーとして実行
sudo -u "${USER_NAME}" bash -c 'git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm && cd .. && rm -rf yay-bin'

echo "Google Chrome をインストールします..."
sudo -u "${USER_NAME}" yay -S --noconfirm google-chrome

if [ "${INSTALL_STEAM}" == "yes" ]; then
    echo "Steam をインストールします..."
    # multilib の有効化 (pacman.conf の編集)
    # 既に [multilib] セクションが存在するか確認し、なければ追加、あればコメント解除
    if grep -Eq "^\\[multilib\\]" /etc/pacman.conf; then
        echo "multilib リポジトリは既にpacman.confに記述があります。コメントアウトを解除します。"
        sed -i '/^\\[multilib\\]$/,/^Include = /s/^#//' /etc/pacman.conf
    else
        echo "multilib リポジトリをpacman.confの末尾に追加します。"
        echo "" >> /etc/pacman.conf
        echo "[multilib]" >> /etc/pacman.conf
        echo "Include = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
    fi
    pacman -Sy --noconfirm # リポジトリ情報を更新 (multilibを含む)
    pacman -S --noconfirm steam
fi

if [ "${INSTALL_PROTONUPQT}" == "yes" ]; then
    echo "ProtonUp-QT をインストールします (Flatpak経由)..."
    pacman -S --noconfirm --needed flatpak
    sudo -u "${USER_NAME}" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    sudo -u "${USER_NAME}" flatpak install -y --noninteractive flathub com.davidotek.protonup-qt
    echo "ProtonUp-QTがFlatpak経由でインストールされました。"
fi

echo "chrootスクリプトの処理が完了しました。"
CHROOT_SCRIPT_EOF
# --- chroot スクリプトここまで ---

chmod +x /mnt/arch-chroot-script.sh

echo "chroot環境に入り、設定スクリプトを実行します..."
arch-chroot /mnt /arch-chroot-script.sh

# arch-chroot が終了した後に実行される
echo ""
echo "---------------------------------------------------------------------"
echo "インストール処理が完了しました。"
echo "設定スクリプトの実行が終了しました。"
echo "エラーメッセージが表示されていなければ、システムは正常に設定されています。"
echo ""
echo "次に、システムをアンマウントして再起動してください:"
echo "  1. umount -R /mnt  (もしスワップがあれば先に swapoff /dev/your_swap_partition)"
echo "  2. reboot"
echo ""
echo "もしchroot環境から手動で抜けてしまった場合は、上記のアンマウントと再起動コマンドを"
echo "このライブ環境のターミナルで実行してください。"
echo "---------------------------------------------------------------------"
