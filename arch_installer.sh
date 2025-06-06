#!/bin/bash

# 設定ファイルの読み込み
source arch_install_config.conf

# 基本構成のセットアップ
echo "Arch Linux 基本構成のセットアップを開始します..."
pacman -Sy --noconfirm

# ディスク一覧の表示と選択
echo "ディスク一覧:"
lsblk
read -p "インストール先のディスクを入力してください (例: /dev/sda): " target_disk

# スワップパーティションの作成
read -p "スワップパーティションを作成しますか? (y/n): " create_swap
if [ "$create_swap" == "y" ]; then
  swap_size=2G
  echo "スワップパーティションを ${swap_size} で作成します。"
fi

# データの削除とフォーマット、パーティション作成
echo "ディスクのデータを削除し、フォーマットします..."
# 実際のパーティション構成はユーザーに合わせる必要があるため、ここでは基本的な例を示します
# parted などを使用してパーティションを作成する処理をここに記述
# 例:
# parted -s ${target_disk} mklabel gpt
# parted -s ${target_disk} mkpart primary ext4 0% 100%
# mkfs.ext4 ${target_disk}1

# マウント
mount ${target_disk}1 /mnt

# 基本システムのインストール
echo "基本システムをインストールします..."
pacstrap /mnt base base-devel linux linux-firmware vim

# fstab の生成
genfstab -U /mnt >> /mnt/etc/fstab

# chroot 環境に入るためのスクリプト
cat <<EOF > arch_chroot.sh
#!/bin/bash
arch-chroot /mnt bash -c "
  # タイムゾーンの設定
  ln -sf /usr/share/zoneinfo/Japan /etc/localtime
  hwclock --systohc

  # ロケールの設定
  echo 'LANG=ja_JP.UTF-8' > /etc/locale.conf
  locale-gen

  # ホスト名の設定
  echo 'archlinux' > /etc/hostname

  # ネットワーク設定
  systemctl enable dhcpcd

  # root パスワードの設定
  echo 'root:password' | chpasswd

  # ユーザー作成
  read -p 'ユーザー名を入力してください: ' username
  read -sp 'パスワードを入力してください: ' password
  echo
  useradd -m -g users -G wheel ${username}
  echo \"${username}:${password}\" | chpasswd
  
  # sudo を許可
  sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

  # 自動ログインの設定
  read -p '自動ログインを有効にしますか? (y/n): ' autologin
  if [ \"\$autologin\" == \"y\" ]; then
    systemctl enable getty@tty1.service
    echo \"[Service]\" > /etc/systemd/system/getty@tty1.service.d/override.conf
    echo \"ExecStart=\" >> /etc/systemd/system/getty@tty1.service.d/override.conf
    echo \"ExecStart=-/usr/bin/agetty --autologin ${username} %I \$TERM\" >> /etc/systemd/system/getty@tty1.service.d/override.conf
  fi

  # デスクトップ環境の選択
  echo 'デスクトップ環境を選択してください:'
  select desktop in \${desktop_environments[@]}; do
    break
  done
  echo \"選択されたデスクトップ環境: \$desktop\"
  case \$desktop in
    GNOME)
      pacman -S --noconfirm gnome gnome-extra
      ;;
    \"KDE Plasma\")
      pacman -S --noconfirm plasma-meta kde-applications
      ;;
    XFCE)
      pacman -S --noconfirm xfce4 xfce4-goodies
      ;;
    LXQt)
      pacman -S --noconfirm lxqt
      ;;
    Mate)
      pacman -S --noconfirm mate mate-extra
      ;;
    *)
      echo '無効な選択です'
      exit 1
      ;;
  esac

  # ログイン環境の選択
  echo 'ログイン環境を選択してください:'
  select login_env in \${login_environments[@]}; do
    break
  done
  echo \"選択されたログイン環境: \$login_env\"
  case \$login_env in
    SDDM)
      pacman -S --noconfirm sddm
      systemctl enable sddm
      ;;
    LightDM)
      pacman -S --noconfirm lightdm lightdm-gtk-greeter
      systemctl enable lightdm
      ;;
    GDM)
      pacman -S --noconfirm gdm
      systemctl enable gdm
      ;;
    LXDM)
      pacman -S --noconfirm lxdm
      systemctl enable lxdm
      ;;
    \"No DM (TTY login)\")
      ;;
    *)
      echo '無効な選択です'
      exit 1
      ;;
  esac

  # ターミナルエミュレータのインストール
  echo 'ターミナルエミュレータを選択してください:'
  select terminal in \${terminal_emulators[@]}; do
    break
  done
  echo \"選択されたターミナルエミュレータ: \$terminal\"
  pacman -S --noconfirm \$terminal

  # yay のインストール
  git clone https://aur.archlinux.org/yay.git /tmp/yay
  chown -R ${username}:${username} /tmp/yay
  su ${username} -c 'cd /tmp/yay && makepkg -si --noconfirm'

  # ブラウザのインストール
  echo 'ブラウザを選択してください:'
  select browser in \${browsers[@]}; do
    break
  done
  echo \"選択されたブラウザ: \$browser\"
  case \$browser in
    chrome)
      su ${username} -c 'yay -S google-chrome --noconfirm'
      ;;
    firefox)
      pacman -S --noconfirm firefox
      ;;
    *)
      echo '無効な選択です'
      exit 1
      ;;
  esac

  # STEAM と PROTONUP-QT のインストール
  read -p 'STEAM と PROTONUP-QT をインストールしますか? (y/n): ' install_steam
  if [ \"\$install_steam\" == \"y\" ]; then
    su ${username} -c 'yay -S steam protonup-qt --noconfirm'
  fi

  echo 'インストールが完了しました。再起動してください。'
"
EOF

chmod +x arch_chroot.sh
./arch_chroot.sh

# アンマウント
umount /mnt

echo "インストールが完了しました。再起動してください。"
