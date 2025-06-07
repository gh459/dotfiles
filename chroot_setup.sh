#!/bin/bash
# This script is executed inside the chroot environment.

set -e # Exit immediately if a command exits with a non-zero status.

# --- Helper Functions ---
print_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

# --- System Configuration ---
print_info "Setting timezone to Asia/Tokyo..."
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime[2]
hwclock --systohc[2]

print_info "Setting locale..."
sed -i '/^#ja_JP.UTF-8/s/^#//' /etc/locale.gen
sed -i '/^#en_US.UTF-8/s/^#//' /etc/locale.gen
locale-gen[2]
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf[7]
echo "KEYMAP=jp106" > /etc/vconsole.conf[2]

print_info "Setting hostname..."
# Note: Variables like $HOSTNAME are passed from the parent install.sh script.
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

print_info "Setting passwords..."
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel "$USERNAME"
echo "$USERNAME:$USER_PASSWORD" | chpasswd
# Allow users in the wheel group to use sudo
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers[2]

print_info "Configuring pacman..."
# Enable multilib repository for 32-bit support (e.g., for Steam)
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
pacman -Syyu --noconfirm

# --- Bootloader ---
print_info "Installing GRUB bootloader..."
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH[2]
grub-mkconfig -o /boot/grub/grub.cfg[2][10]

# --- Graphics and Desktop Environment ---
print_info "Installing Xorg and basic drivers..."
pacman -S --noconfirm xorg-server[6]

print_info "Installing GPU drivers for $GPU_CHOICE..."
case "$GPU_CHOICE" in
    "NVIDIA") pacman -S --noconfirm nvidia-dkms nvidia-utils ;;
    "AMD") pacman -S --noconfirm mesa lib32-mesa xf86-video-amdgpu ;;
    "Intel") pacman -S --noconfirm mesa lib32-mesa xf86-video-intel ;;
esac

print_info "Installing Desktop Environment: $DE_CHOICE..."
DM="" # Display Manager variable
case "$DE_CHOICE" in
    "GNOME")
        pacman -S --noconfirm gnome gnome-terminal
        DM="gdm"
        ;;
    "KDE-Plasma")
        pacman -S --noconfirm plasma-meta konsole dolphin
        DM="sddm"
        ;;
    "XFCE")
        pacman -S --noconfirm xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xfce4-terminal
        DM="lightdm"
        ;;
    "Cinnamon")
        pacman -S --noconfirm cinnamon lightdm lightdm-gtk-greeter gnome-terminal
        DM="lightdm"
        ;;
    "Hyprland")
        pacman -S --noconfirm hyprland kitty dolphin sddm xdg-desktop-portal-hyprland
        DM="sddm"
        ;;
esac

# --- Japanese Language Support ---
print_info "Installing Japanese fonts and input method..."
pacman -S --noconfirm adobe-source-han-sans-jp-fonts noto-fonts-cjk fcitx5-im fcitx5-mozc[8]
# Set environment variables for the input method
cat <<ENV > /etc/environment
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
XMODIFIERS=@im=fcitx5
ENV

# --- Display Manager and Autologin ---
if [ -n "$DM" ]; then
    print_info "Enabling Display Manager: $DM..."
    systemctl enable $DM

    if [[ "$AUTOLOGIN" == "y" || "$AUTOLOGIN" == "Y" ]]; then
        print_info "Configuring autologin for $USERNAME..."
        case "$DM" in
            "gdm")
                sed -i "/^#.*AutomaticLoginEnable/s/^# //" /etc/gdm/custom.conf
                sed -i "/^#.*AutomaticLogin/s/^# //" /etc/gdm/custom.conf
                sed -i "s/user1/$USERNAME/" /etc/gdm/custom.conf
                ;;
            "lightdm")
                sed -i "s/^#autologin-user=.*/autologin-user=$USERNAME/" /etc/lightdm/lightdm.conf
                sed -i "s/^#autologin-session=.*/autologin-session=/" /etc/lightdm/lightdm.conf
                ;;
            "sddm")
                mkdir -p /etc/sddm.conf.d
                SESSION_DESKTOP="plasma.desktop" # Default to plasma
                if [ "$DE_CHOICE" == "Hyprland" ]; then
                    SESSION_DESKTOP="hyprland.desktop"
                elif [ "$DE_CHOICE" == "XFCE" ]; then
                    SESSION_DESKTOP="xfce.desktop"
                elif [ "$DE_CHOICE" == "Cinnamon" ]; then
                    SESSION_DESKTOP="cinnamon.desktop"
                fi
                echo -e "[Autologin]\nUser=$USERNAME\nSession=$SESSION_DESKTOP" > /etc/sddm.conf.d/autologin.conf
                ;;
        esac
    fi
fi

# --- Install yay AUR Helper ---
print_info "Setting up yay installation..."
# Run the installation as the new user to avoid permission issues in the home directory
runuser -l $USERNAME -c 'git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay'

# --- Install Additional Software ---
print_info "Installing additional software..."
runuser -l $USERNAME -c 'yay -S --noconfirm google-chrome'

if [[ "$INSTALL_STEAM" == "y" || "$INSTALL_STEAM" == "Y" ]]; then
    print_info "Installing Steam and ProtonUp-Qt..."
    pacman -S --noconfirm steam
    runuser -l $USERNAME -c 'yay -S --noconfirm protonup-qt'
fi

print_info "Cleaning up..."
# Remove this script after execution
rm /chroot_setup.sh

print_info "Chroot setup complete. Type 'exit' or press Ctrl+D to leave chroot."
