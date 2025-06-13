#!/usr/bin/env bash
# Arch Linux automated installer (chroot side)
set -euo pipefail

#----- load variables -------------------------------------------------------
source /root/.autosetup
rm /root/.autosetup

#----- locale & time --------------------------------------------------------
echo "## Configuring locale/time…" # English comment
sed -i '/^#ja_JP.UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc
echo "KEYMAP=jp106" > /etc/vconsole.conf

#----- hostname -------------------------------------------------------------
echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

#----- users & sudo ---------------------------------------------------------
echo "## Creating user…"           # English comment
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i '/^# %wheel ALL=(ALL) ALL/s/^# //' /etc/sudoers

#----- network --------------------------------------------------------------
pacman -S --noconfirm networkmanager
systemctl enable NetworkManager

#----- gpu driver -----------------------------------------------------------
case $GPU in
  nvidia) pacman -S --noconfirm nvidia nvidia-utils ;;
  amd)    pacman -S --noconfirm mesa xf86-video-amdgpu ;;
  intel)  pacman -S --noconfirm mesa xf86-video-intel intel-media-driver ;;
esac

#----- Xorg base ------------------------------------------------------------
pacman -S --noconfirm xorg

#----- desktop environment --------------------------------------------------
declare -A DEPKG=(
  [gnome]="gnome"
  [plasma]="plasma kde-applications"
  [xfce]="xfce4 xfce4-goodies"
  [cinnamon]="cinnamon"
  [mate]="mate mate-extra"
)
pacman -S --noconfirm ${DEPKG[$DE]}

#----- display manager ------------------------------------------------------
case $DM in
  gdm)    pacman -S --noconfirm gdm    && systemctl enable gdm ;;
  sddm)   pacman -S --noconfirm sddm   && systemctl enable sddm ;;
  lightdm)pacman -S --noconfirm lightdm lightdm-gtk-greeter && systemctl enable lightdm ;;
  lxdm)   pacman -S --noconfirm lxdm   && systemctl enable lxdm ;;
  ly)     pacman -S --noconfirm ly     && systemctl enable ly ;;
esac

#----- autologin (only for getty or gdm/sddm) -------------------------------
if [[ $AUTOLOGIN == y ]]; then
  if [[ $DM == gdm ]]; then
    mkdir -p /var/lib/AccountsService/users
    cat > /var/lib/AccountsService/users/$USERNAME <<EOF
[User]
SystemAccount=false
AutomaticLogin=true
AutomaticLoginTimeout=0
EOF
  elif [[ $DM ==
