#!/bin/bash
echo "This is my script."
ls -l

# ルートパーティションをマウント
mount /dev/sda2 /mnt

# EFIパーティションを作成してマウント
mkdir -p /mnt/boot/efi
mount /dev/sda1 /mnt/boot/efi

# スワップパーティションを有効化
swapon /dev/sda3

genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt

# 必要なパッケージをインストール
pacman -S --noconfirm grub efibootmgr

# GRUBをインストール（--bootloader-id=GRUBは任意名）
grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB --recheck

# 一部のPCでは下記のコピーも推奨
mkdir -p /boot/EFI/boot
cp /boot/EFI/GRUB/grubx64.efi /boot/EFI/boot/bootx64.efi

# GRUB設定ファイルを生成
grub-mkconfig -o /boot/grub/grub.cfg

# 必要なパッケージをインストール
pacman -S --noconfirm grub efibootmgr

# GRUBをインストール（--bootloader-id=GRUBは任意名）
grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB --recheck

# 一部のPCでは下記のコピーも推奨
mkdir -p /boot/EFI/boot
cp /boot/EFI/GRUB/grubx64.efi /boot/EFI/boot/bootx64.efi

# GRUB設定ファイルを生成
grub-mkconfig -o /boot/grub/grub.cfg

# LXQtデスクトップ・必要パッケージ
pacman -Syu --noconfirm
pacman -S --noconfirm xorg-server xorg-xinit xorg-apps xf86-input-libinput \
  lxqt lxqt-arch-config lxqt-policykit lxqt-session lxqt-admin \
  openbox obconf sddm pcmanfm-qt qterminal featherpad \
  ttf-dejavu ttf-liberation noto-fonts networkmanager pipewire pipewire-pulse pavucontrol

systemctl enable sddm
systemctl enable NetworkManager

# ユーザー作成・パスワード設定
useradd -m -G wheel -s /bin/bash archuser
echo "archuser:password123" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# yayインストール
pacman -S --needed --noconfirm git base-devel
sudo -u archuser bash -c "
  cd ~
  git clone https://aur.archlinux.org/yay.git
  cd yay
  makepkg -si --noconfirm
  cd ..
  rm -rf yay
"

# Chromeインストール
sudo -u archuser yay -S --noconfirm google-chrome

exit
umount -R /mnt
reboot

