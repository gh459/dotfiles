#!/usr/bin/env bash
# ------------------------------------------------------------
# Arch Linux automated installer – chroot_setup.sh
# ------------------------------------------------------------
set -euo pipefail
source /root/install.conf

echo "==> Setting timezone ..."
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

echo "==> Generating locale ..."
sed -i 's/^#ja_JP.UTF-8/ja_JP.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf

echo "==> Setting hostname ..."
echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF

echo "==> Creating user ..."
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "Set password for $USERNAME"
passwd "$USERNAME"
echo "%wheel ALL=(ALL) ALL" | tee /etc/sudoers.d/99_wheel

# ------------------------------------------------------------
# GPU driver
# ------------------------------------------------------------
case "$GPUSEL" in
  1) pacman -S --noconfirm nvidia nvidia-utils lib32-nvidia-utils ;;
  2) pacman -S --noconfirm mesa vulkan-radeon lib32-mesa ;;
  3) pacman -S --noconfirm mesa vulkan-intel lib32-mesa ;;
esac

# ------------------------------------------------------------
# Xorg & Desktop
# ------------------------------------------------------------
pacman -S --noconfirm xorg xorg-xinit

case "$DESEL" in
  1) pacman -S --noconfirm gnome gnome-tweaks ;;
  2) pacman -S --noconfirm plasma kde-applications ;;
  3) pacman -S --noconfirm xfce4 xfce4-goodies ;;
  4) pacman -S --noconfirm cinnamon ;;
  5) pacman -S --noconfirm mate mate-extra ;;
esac

# ------------------------------------------------------------
# Display manager
# ------------------------------------------------------------
case "$DMSEL" in
  1) pacman -S --noconfirm gdm && systemctl enable gdm ;;
  2) pacman -S --noconfirm sddm && systemctl enable sddm ;;
  3) pacman -S --noconfirm lightdm lightdm-gtk-greeter && systemctl enable lightdm ;;
  4) pacman -S --noconfirm lxdm && systemctl enable lxdm ;;
  5) ;; # none
esac

# ------------------------------------------------------------
# Preferred shell & terminal
# ------------------------------------------------------------
case "$SHELSEL" in
  2) pacman -S --noconfirm zsh && chsh -s /bin/zsh "$USERNAME" ;;
  3) pacman -S --noconfirm fish && chsh -s /usr/bin/fish "$USERNAME" ;;
  4) pacman -S --noconfirm tcsh && chsh -s /bin/tcsh "$USERNAME" ;;
  5) pacman -S --noconfirm nushell && chsh -s /usr/bin/nu "$USERNAME" ;;
esac

case "$TERMSEL" in
  1) pacman -S --noconfirm gnome-terminal ;;
  2) pacman -S --noconfirm konsole ;;
  3) pacman -S --noconfirm xfce4-terminal ;;
  4) pacman -S --noconfirm tilix ;;
  5) pacman -S --noconfirm alacritty ;;
esac

# ------------------------------------------------------------
# Autologin
# ------------------------------------------------------------
if [[ $AUTOLOGIN =~ ^[yY]$ ]]; then
  if [[ $DMSEL -eq 5 ]]; then
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --noclear %I \$TERM
EOF
    systemctl enable getty@tty1
  else
    # DM autologin config (GDM & SDDM shown)
    if [[ $DMSEL -eq 1 ]]; then
      mkdir -p /var/lib/gdm
      echo "[daemon]" > /etc/gdm/custom.conf
      echo "AutomaticLoginEnable=True" >> /etc/gdm/custom.conf
      echo "AutomaticLogin=$USERNAME" >> /etc/gdm/custom.conf
    fi
    if [[ $DMSEL -eq 2 ]]; then
      mkdir -p /etc/sddm.conf.d
      cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USERNAME
Session=plasma.desktop
EOF
    fi
  fi
fi

# ------------------------------------------------------------
# yay & AUR packages
# ------------------------------------------------------------
echo "==> Installing yay ..."
pacman -S --noconfirm --needed git base-devel
sudo -u "$USERNAME" bash -c "
  cd /home/$USERNAME
  git clone https://aur.archlinux.org/yay.git
  cd yay && makepkg -si --noconfirm
" # yay install[8]

echo "==> Installing Google Chrome ..."
sudo -u "$USERNAME" yay -S --noconfirm google-chrome # AUR[4]

if [[ $WANT_STEAM =~ ^[yY]$ ]]; then
  echo "==> Enabling multilib & installing Steam ..."
  sed -i '/\[multilib\]/,/Include/{s/^#//}' /etc/pacman.conf
  pacman -Sy --noconfirm steam # Steam needs multilib[6]
fi

if [[ $WANT_PROTON =~ ^[yY]$ ]]; then
  echo "==> Installing ProtonUp-Qt ..."
  sudo -u "$USERNAME" yay -S --noconfirm protonup-qt # AUR[7]
fi

systemctl enable NetworkManager

echo "==> Chroot configuration finished."
