#!/bin/bash
set -e

# フォーマット
mkfs.fat -F32 /dev/sda1
mkfs.ext4 /dev/sda2
mkswap /dev/sda3
swapon /dev/sda3

# マウント
mount /dev/sda2 /mnt
mkdir -p /mnt/boot/efi
mount /dev/sda1 /mnt/boot/efi

# fstab生成
genfstab -U /mnt >> /mnt/etc/fstab

# chroot用スクリプトを作成
cat <<'EOF' > /mnt/root/chroot-setup.sh
#!/bin/bash
set -e

pacman -Syu --noconfirm
pacman -S --noconfirm grub efibootmgr

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

pacman -S --noconfirm xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-arch-config lxqt-policykit lxqt-session lxqt-admin \
openbox obconf sddm pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts networkmanager pipewire pipewire-pulse pavucontrol

systemctl enable sddm
systemctl enable NetworkManager

useradd -m -G wheel -s /bin/bash archuser
echo "archuser:password123" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

pacman -S --needed --noconfirm git base-devel

sudo -u archuser bash -c '
cd ~
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay
yay -S --noconfirm google-chrome
'
EOF

chmod +x /mnt/root/chroot-setup.sh

# chrootでセットアップ
arch-chroot /mnt /root/chroot-setup.sh

# chrootから戻ったらアンマウントと再起動
umount -R /mnt
reboot
