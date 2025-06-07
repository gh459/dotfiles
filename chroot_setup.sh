#!/bin/bash

# Exit on any error
set -e

# Load configuration
source /chroot_config.sh

echo ">>> Setting timezone to Asia/Tokyo"
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

echo ">>> Setting up locale"
echo "ja_JP.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen[7]
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf

echo ">>> Setting hostname"
echo "archlinux" > /etc/hostname
cat <<EOF >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   archlinux.localdomain   archlinux
EOF

echo ">>> Setting root password (same as user password for convenience)"
echo "root:${USER_PASSWORD}" | chpasswd

echo ">>> Creating user ${USER_NAME}"
useradd -m -G wheel -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
echo ">>> Granting sudo privileges to wheel group"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo ">>> Installing GRUB bootloader"
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

echo ">>> Enabling NetworkManager"
systemctl enable NetworkManager

# GPU Driver Installation
echo ">>> Detecting and installing graphics drivers"
if lspci | grep -E "VGA|3D" | grep -iq "intel"; then
    pacman -S --noconfirm mesa xf86-video-intel
elif lspci | grep -E "VGA|3D" | grep -iq "amd\|ati"; then
    pacman -S --noconfirm mesa xf86-video-amdgpu
elif lspci | grep -E "VGA|3D" | grep -iq "nvidia"; then
    pacman -S --noconfirm nvidia nvidia-utils
elif lspci | grep -E "VGA|3D" | grep -iq "virtualbox"; then
    pacman -S --noconfirm virtualbox-guest-utils[1]
else
    echo "!!! Could not detect GPU, installing generic mesa drivers"
    pacman -S --noconfirm mesa
fi

# Desktop Environment and Display Manager Installation
DE_PKG=""
DM_PKG=""
DM_SERVICE=""

case ${DE_CHOICE} in
    1)
        DE_PKG="gnome"
        DM_PKG="gdm"
        DM_SERVICE="gdm.service"
        ;;
    2)
        DE_PKG="plasma-meta konsole"
        DM_PKG="sddm"
        DM_SERVICE="sddm.service"
        ;;
    3)
        DE_PKG="xfce4 xfce4-goodies"
        DM_PKG="lightdm lightdm-gtk-greeter"
        DM_SERVICE="lightdm.service"
        ;;
    4)
        DE_PKG="cinnamon"
        DM_PKG="lightdm lightdm-gtk-greeter"
        DM_SERVICE="lightdm.service"
        ;;
    5)
        DE_PKG="mate mate-extra"
        DM_PKG="lightdm lightdm-gtk-greeter"
        DM_SERVICE="lightdm.service"
        ;;
    *)
        echo "!!! Invalid DE choice. Installing XFCE4 by default."
        DE_PKG="xfce4 xfce4-goodies"
        DM_PKG="lightdm lightdm-gtk-greeter"
        DM_SERVICE="lightdm.service"
        ;;
esac

echo ">>> Installing Desktop Environment and Display Manager"
pacman -S --noconfirm ${DE_PKG} ${DM_PKG}
systemctl enable ${DM_SERVICE}

# Autologin setup
if [ "${AUTOLOGIN_CHOICE}" = "y" ]; then
    echo ">>> Enabling autologin for ${USER_NAME}"
    if [ "${DM_SERVICE}" = "lightdm.service" ]; then
        groupadd -r autologin
        gpasswd -a "${USER_NAME}" autologin[8]
        sed -i "s/^#autologin-user=.*/autologin-user=${USER_NAME}/" /etc/lightdm/lightdm.conf
    elif [ "${DM_SERVICE}" = "gdm.service" ]; then
        # This is a simplified method for GDM autologin
        # For security reasons, consider manual configuration
        mkdir -p /etc/gdm/
        echo -e "[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=${USER_NAME}" > /etc/gdm/custom.conf
    elif [ "${DM_SERVICE}" = "sddm.service" ]; then
        mkdir -p /etc/sddm.conf.d
        echo -e "[Autologin]\nUser=${USER_NAME}\nSession=plasma.desktop" > /etc/sddm.conf.d/autologin.conf
    fi
fi

# Multilib repository for Steam
if [ "${STEAM_CHOICE}" = "y" ]; then
    echo ">>> Enabling multilib repository"
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf[3]
    pacman -Syu --noconfirm
fi

# Install yay AUR Helper
echo ">>> Installing yay AUR Helper"
sudo -u "${USER_NAME}" bash -c "cd /home/${USER_NAME} && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm"

# Install additional applications
echo ">>> Installing Google Chrome"
sudo -u "${USER_NAME}" yay -S --noconfirm google-chrome[6]

if [ "${STEAM_CHOICE}" = "y" ]; then
    echo ">>> Installing Steam and ProtonUp-Qt"
    pacman -S --noconfirm steam ttf-liberation[3]
    sudo -u "${USER_NAME}" yay -S --noconfirm protonup-qt[3]
fi

echo ">>> Chroot setup finished."

