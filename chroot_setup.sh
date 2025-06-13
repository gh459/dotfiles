#!/bin/bash

echo "Setting timezone..."
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

echo "Creating user and setting password..."
echo "Enter username:"
read -r username
useradd -m "$username"
echo "Enter password for $username:"
passwd "$username"

echo "Enable automatic login? (yes/no)"
read -r auto_login
if [ "$auto_login" == "yes" ]; then
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  echo -e "[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin $username --noclear %I 38400 linux" > /etc/systemd/system/getty@tty1.service.d/autologin.conf
fi

echo "Installing desktop environment and display manager..."
echo "Choose a desktop environment:"
echo "1) GNOME 2) KDE Plasma 3) XFCE 4) Cinnamon 5) LXQt"
read -r de_choice
if [ "$de_choice" -eq 1 ]; then
  pacman -Sy --noconfirm gnome gdm
elif [ "$de_choice" -eq 2 ]; then
  pacman -Sy --noconfirm plasma sddm
elif [ "$de_choice" -eq 3 ]; then
  pacman -Sy --noconfirm xfce4 lightdm
elif [ "$de_choice" -eq 4 ]; then
  pacman -Sy --noconfirm cinnamon lightdm
elif [ "$de_choice" -eq 5 ]; then
  pacman -Sy --noconfirm lxqt lightdm
else
  echo "Invalid choice, skipping desktop environment installation."
fi

echo "Installing terminal emulator..."
echo "1) GNOME Terminal 2) Konsole 3) XFCE4 Terminal 4) LXTerminal 5) XTerm"
read -r terminal_choice
case "$terminal_choice" in
  1) pacman -Sy --noconfirm gnome-terminal ;;
  2) pacman -Sy --noconfirm konsole ;;
  3) pacman -Sy --noconfirm xfce4-terminal ;;
  4) pacman -Sy --noconfirm lxterminal ;;
  5) pacman -Sy --noconfirm xterm ;;
  *) echo "Invalid choice, skipping terminal emulator installation." ;;
esac

echo "Installing yay..."
pacman -Sy --noconfirm git base-devel
git clone https://aur.archlinux.org/yay.git
cd yay || exit
makepkg -si --noconfirm

echo "Installing Google Chrome..."
yay -Sy --noconfirm google-chrome

echo "Install Steam and ProtonUp-Qt? (yes/no)"
read -r steam_choice
if [ "$steam_choice" == "yes" ]; then
  yay -Sy --noconfirm steam protonup-qt
fi

echo "System setup complete!"
