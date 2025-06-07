#!/bin/bash
# chroot_setup.sh - Arch Linux System Configuration Script

# Stop on any error
set -e

# Load variables from install.sh
source /install_vars.sh

echo "INFO (chroot): Setting up timezone and locale..."
# --- Timezone and Locale ---
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf

echo "INFO (chroot): Setting up hostname..."
# --- Hostname ---
echo "$HOSTNAME" > /etc/hostname
cat <<EOF >> /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "INFO (chroot): Setting root password (locking account)..."
# Set root password (same as user for simplicity, but locked)
echo "root:$USER_PASSWORD" | chpasswd
passwd -l root

echo "INFO (chroot): Creating user $USERNAME..."
# --- User Setup ---
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
# Allow users in wheel group to use sudo
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "INFO (chroot): Installing bootloader (GRUB)..."
# --- Bootloader ---
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH --recheck
grub-mkconfig -o /boot/grub/grub.cfg

echo "INFO (chroot): Enabling NetworkManager..."
systemctl enable NetworkManager

echo "INFO (chroot): Installing graphics drivers and desktop environment..."
# --- Graphics and Desktop ---
pacman -S --noconfirm $GFX_PACKAGE $DE_PACKAGES

echo "INFO (chroot): Enabling display manager ($DM)..."
systemctl enable "$DM.service"

# --- Autologin Configuration ---
if [[ "$AUTOLOGIN" == "yes" ]]; then
    echo "INFO (chroot): Configuring automatic login for $DM..."
    case $DM in
        "gdm")
            mkdir -p /etc/gdm
            cat > /etc/gdm/custom.conf <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=$USERNAME
EOF
            ;;
        "sddm")
            mkdir -p /etc/sddm.conf.d
            cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USERNAME
Session=plasma.desktop
EOF
            ;;
        "lightdm")
            sed -i "s/^#autologin-user=.*/autologin-user=$USERNAME/" /etc/lightdm/lightdm.conf
            sed -i "s/^#autologin-session=.*/autologin-session=lightdm-xsession/" /etc/lightdm/lightdm.conf
            ;;
    esac
fi


# --- Install yay and additional packages as the new user ---
echo "INFO (chroot): Installing AUR helper (yay)..."
sudo -u "$USERNAME" bash -c 'git clone https://aur.archlinux.org/yay.git /tmp/yay && cd /tmp/yay && makepkg -si --noconfirm && cd / && rm -rf /tmp/yay'

echo "INFO (chroot): Installing Google Chrome..."
sudo -u "$USERNAME" yay -S --noconfirm google-chrome[3]

if [[ "$INSTALL_STEAM" == "yes" ]]; then
    echo "INFO (chroot): Installing Steam and ProtonUp-Qt..."
    # Enable multilib repository for Steam
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Sy --noconfirm
    pacman -S --noconfirm steam
    sudo -u "$USERNAME" yay -S --noconfirm protonup-qt[5]
fi

echo "INFO (chroot): System configuration finished."
