#!/bin/bash
# chroot_setup.sh - System Configuration Script (run inside chroot)

# Exit on any error
set -e

# --- Timezone and Locale ---
echo "Setting timezone to Asia/Tokyo"
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
hwclock --systohc

echo "Generating locales (ja_JP.UTF-8 and en_US.UTF-8)"[13]
sed -i 's/^#ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

echo "LANG=ja_JP.UTF-8" > /etc/locale.conf
echo "KEYMAP=jp106" > /etc/vconsole.conf

# --- Hostname and Network ---
read -p "Enter your hostname: " HOSTNAME
echo "${HOSTNAME}" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# --- User Setup ---
echo "Set the root password:"
passwd

read -p "Enter your username: " USERNAME
useradd -m -G wheel "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"

echo "Configuring sudo for 'wheel' group"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- Bootloader ---
echo "Installing GRUB bootloader for UEFI"
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

# --- Enable Services ---
echo "Enabling NetworkManager"
systemctl enable NetworkManager

# --- Japanese Fonts and Input Method ---
echo "Installing Japanese fonts and Fcitx5-Mozc"[4]
pacman -S --noconfirm noto-fonts-cjk fcitx5-mozc fcitx5-im fcitx5-configtool
cat <<EOT >> /etc/environment
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOT

# --- Graphics Drivers ---
echo "Detecting graphics card..."
GPU_VENDOR=$(lspci | grep -E "VGA|3D" | grep -o -E "NVIDIA|AMD|Intel|VMware")
DRIVER_PACKAGES=""
if [[ "$GPU_VENDOR" == "NVIDIA" ]]; then
    DRIVER_PACKAGES="nvidia nvidia-utils lib32-nvidia-utils"
elif [[ "$GPU_VENDOR" == "AMD" ]]; then
    DRIVER_PACKAGES="xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon"
elif [[ "$GPU_VENDOR" == "Intel" ]]; then
    DRIVER_PACKAGES="xf86-video-intel vulkan-intel lib32-vulkan-intel"
elif [[ "$GPU_VENDOR" == "VMware" ]]; then
    DRIVER_PACKAGES="xf86-video-vmware"
fi

if [ -n "$DRIVER_PACKAGES" ]; then
    echo "Detected GPU: $GPU_VENDOR"
    read -p "Install graphics drivers ($DRIVER_PACKAGES)? (Y/n): " INSTALL_GPU
    if [[ ! "$INSTALL_GPU" =~ ^[nN]$ ]]; then
        pacman -S --noconfirm $DRIVER_PACKAGES
    fi
fi

# --- GUI Environment Selection ---
echo "------------------------------------------------"
echo "Select a Desktop Environment:"
echo "1) KDE Plasma"
echo "2) GNOME"
echo "3) XFCE4"
echo "4) Cinnamon"
echo "5) Hyprland (Tiling Window Manager)"
echo "------------------------------------------------"
read -p "Enter your choice [1-5]: " DE_CHOICE

DE_PACKAGES=""
DM_PACKAGE=""
DM_SERVICE=""

case $DE_CHOICE in
    1) DE_PACKAGES="plasma-meta konsole"; DM_PACKAGE="sddm"; DM_SERVICE="sddm.service" ;;
    2) DE_PACKAGES="gnome gnome-terminal"; DM_PACKAGE="gdm"; DM_SERVICE="gdm.service" ;;
    3) DE_PACKAGES="xfce4 xfce4-goodies"; DM_PACKAGE="lightdm lightdm-gtk-greeter"; DM_SERVICE="lightdm.service" ;;
    4) DE_PACKAGES="cinnamon"; DM_PACKAGE="lightdm lightdm-gtk-greeter"; DM_SERVICE="lightdm.service" ;;
    5) DE_PACKAGES="hyprland kitty polkit-kde-agent"; DM_PACKAGE=""; DM_SERVICE="" ;;
    *) echo "Invalid choice. Exiting."; exit 1 ;;
esac

echo "Installing selected environment..."
pacman -S --noconfirm $DE_PACKAGES $DM_PACKAGE
if [ -n "$DM_SERVICE" ]; then
    systemctl enable $DM_SERVICE
fi

# --- Autologin Setup ---
read -p "Enable autologin for ${USERNAME}? (y/N): " AUTOLOGIN_CHOICE
if [[ "$AUTOLOGIN_CHOICE" =~ ^[yY]$ ]]; then
    echo "Configuring autologin..."
    case $DE_CHOICE in
        1) # SDDM
            mkdir -p /etc/sddm.conf.d
            echo -e "[Autologin]\nUser=${USERNAME}\nSession=plasma.desktop" > /etc/sddm.conf.d/autologin.conf
            ;;
        2) # GDM
            sed -i "/\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=${USERNAME}" /etc/gdm/custom.conf
            ;;
        3|4) # LightDM[6]
            sed -i "s/^#autologin-user=.*/autologin-user=${USERNAME}/" /etc/lightdm/lightdm.conf
            groupadd -r autologin
            gpasswd -a "${USERNAME}" autologin
            ;;
        5) # Hyprland (TTY Autologin)[2]
            mkdir -p "/etc/systemd/system/getty@tty1.service.d"
            cat > "/etc/systemd/system/getty@tty1.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USERNAME} --noclear %I \$TERM
EOF
            echo -e '\nif [ -z "$DISPLAY" ] && [ "$(fgconsole)" -eq 1 ]; then\n  exec Hyprland\nfi' >> "/home/${USERNAME}/.bash_profile"
            ;;
    esac
fi

# --- AUR Helper (yay) ---
echo "Installing AUR helper (yay)..."
sudo -u "${USERNAME}" bash -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

# --- Additional Software ---
echo "Installing Google Chrome..."[9]
sudo -u "${USERNAME}" yay -S --noconfirm google-chrome

read -p "Install Steam and ProtonUp-QT? (y/N): " INSTALL_GAMING
if [[ "$INSTALL_GAMING" =~ ^[yY]$ ]]; then
    echo "Enabling multilib repository for Steam..."[3]
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
    pacman -Sy --noconfirm
    echo "Installing Steam..."
    pacman -S --noconfirm steam
    echo "Installing ProtonUp-QT..."[7]
    sudo -u "${USERNAME}" yay -S --noconfirm protonup-qt
fi

# --- Cleanup ---
rm /chroot_setup.sh

echo "------------------------------------------------"
echo "Chroot setup is complete."
echo "You can now exit chroot by typing 'exit'."
echo "------------------------------------------------"

