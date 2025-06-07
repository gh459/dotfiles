# install.sh
# Main script to start the Arch Linux installation.
# RUN THIS SCRIPT FROM THE ARCH LINUX INSTALLATION MEDIA.

set -e # Exit immediately if a command exits with a non-zero status.

# --- Helper Functions ---
print_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

print_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1"
}

print_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
    exit 1
}

# --- Pre-installation Setup ---
print_info "Setting up keyboard layout to jp106..."
loadkeys jp106
print_info "Keyboard layout set to jp106."[7][9]

print_info "Updating system clock with NTP..."
timedatectl set-ntp true
print_info "System clock updated."[11]

# --- Disk Partitioning ---
print_info "Available disks:"
lsblk -d -o NAME,SIZE,MODEL

echo ""
read -p "Enter the disk to install Arch Linux on (e.g., /dev/sda, /dev/nvme0n1): " TARGET_DISK
if [ ! -b "$TARGET_DISK" ]; then
    print_error "Disk $TARGET_DISK not found."
fi

print_warning "THIS WILL DELETE ALL DATA ON $TARGET_DISK."
read -p "Are you sure you want to continue? (y/N): " CONFIRM_DELETE
if [[ "$CONFIRM_DELETE" != "y" && "$CONFIRM_DELETE" != "Y" ]]; then
    print_error "Installation aborted by user."
fi

read -p "Do you want to create a swap partition? (y/N): " CREATE_SWAP
if [[ "$CREATE_SWAP" == "y" || "$CREATE_SWAP" == "Y" ]]; then
    read -p "Enter swap size in GB (e.g., 8 for 8GB): " SWAP_SIZE
fi

print_info "Partitioning $TARGET_DISK..."
umount -R /mnt 2>/dev/null || true
sgdisk --zap-all "$TARGET_DISK"

sgdisk -n 1:0:+550M -t 1:ef00 -c 1:"EFI System Partition" "$TARGET_DISK"
EFI_PARTITION="${TARGET_DISK}1"
if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
    EFI_PARTITION="${TARGET_DISK}p1"
fi

if [[ "$CREATE_SWAP" == "y" || "$CREATE_SWAP" == "Y" ]]; then
    sgdisk -n 2:0:+${SWAP_SIZE}G -t 2:8200 -c 2:"Linux swap" "$TARGET_DISK"
    sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux root" "$TARGET_DISK"
    SWAP_PARTITION="${TARGET_DISK}2"
    ROOT_PARTITION="${TARGET_DISK}3"
    if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
        SWAP_PARTITION="${TARGET_DISK}p2"
        ROOT_PARTITION="${TARGET_DISK}p3"
    fi
else
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$TARGET_DISK"
    ROOT_PARTITION="${TARGET_DISK}2"
    if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
        ROOT_PARTITION="${TARGET_DISK}p2"
    fi
fi

print_info "Formatting partitions..."
mkfs.fat -F32 "$EFI_PARTITION"
mkfs.ext4 "$ROOT_PARTITION"
if [[ "$CREATE_SWAP" == "y" || "$CREATE_SWAP" == "Y" ]]; then
    mkswap "$SWAP_PARTITION"
fi

print_info "Mounting file systems..."
mount "$ROOT_PARTITION" /mnt
mkdir -p /mnt/boot
mount "$EFI_PARTITION" /mnt/boot
if [[ "$CREATE_SWAP" == "y" || "$CREATE_SWAP" == "Y" ]]; then
    swapon "$SWAP_PARTITION"
fi

# --- User and System Configuration ---
print_info "Gathering user and system information..."
read -p "Enter a hostname for the new system: " HOSTNAME
read -p "Enter a username: " USERNAME
read -sp "Enter a password for the user '$USERNAME': " USER_PASSWORD
echo ""
read -sp "Confirm password: " USER_PASSWORD_CONFIRM
echo ""
if [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
    print_error "Passwords do not match."
fi
read -sp "Enter the root password: " ROOT_PASSWORD
echo ""

read -p "Do you want to enable automatic login? (y/N): " AUTOLOGIN

# --- Desktop Environment Selection ---
print_info "Select a Desktop Environment:"
PS3="Enter a number: "
DE_OPTIONS=("GNOME" "KDE-Plasma" "XFCE" "Cinnamon" "Hyprland")
select DE_CHOICE in "${DE_OPTIONS[@]}"; do
    [[ -n "$DE_CHOICE" ]] && break || echo "Invalid choice. Please try again."
done

# --- GPU Driver Selection ---
print_info "Select your GPU vendor for driver installation:"
PS3="Enter a number: "
GPU_OPTIONS=("NVIDIA" "AMD" "Intel")
select GPU_CHOICE in "${GPU_OPTIONS[@]}"; do
    [[ -n "$GPU_CHOICE" ]] && break || echo "Invalid choice. Please try again."
done

# --- Additional Software ---
read -p "Install Steam and ProtonUp-Qt? (y/N): " INSTALL_STEAM

# --- Install Base System ---
print_info "Updating mirrorlist for Japan..."
reflector --country Japan --sort rate --save /etc/pacman.d/mirrorlist
print_info "Installing base system (this may take a while)..."
pacstrap /mnt base base-devel linux linux-firmware amd-ucode intel-ucode git vim[4][7]

print_info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab[9]

# --- Create Chroot Setup Script ---
print_info "Creating chroot setup script..."
cat <<EOF > /mnt/chroot_setup.sh
#!/bin/bash
set -e

# --- Helper Functions ---
print_info() {
    echo -e "\e[34m[INFO]\e[0m \$1"
}

# --- System Configuration ---
print_info "Setting timezone to Asia/Tokyo..."
ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime[9]
hwclock --systohc[9]

print_info "Setting locale..."
sed -i '/^#ja_JP.UTF-8/s/^#//' /etc/locale.gen
sed -i '/^#en_US.UTF-8/s/^#//' /etc/locale.gen
locale-gen[9]
echo "LANG=ja_JP.UTF-8" > /etc/locale.conf[7]
echo "KEYMAP=jp106" > /etc/vconsole.conf[9]

print_info "Setting hostname..."
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
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

print_info "Configuring pacman..."
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
pacman -Syyu --noconfirm

# --- Bootloader ---
print_info "Installing GRUB bootloader..."
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH[9]
grub-mkconfig -o /boot/grub/grub.cfg[9]

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
DM=""
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
pacman -S --noconfirm adobe-source-han-sans-jp-fonts noto-fonts-cjk fcitx5-im fcitx5-mozc[5][8]
cat <<ENV > /etc/environment
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
XMODIFIERS=@im=fcitx5
ENV

# --- Display Manager and Autologin ---
if [ -n "\$DM" ]; then
    print_info "Enabling Display Manager: \$DM..."
    systemctl enable \$DM

    if [[ "$AUTOLOGIN" == "y" || "$AUTOLOGIN" == "Y" ]]; then
        print_info "Configuring autologin for $USERNAME..."
        case "\$DM" in
            "gdm")
                sed -i "/^#.*AutomaticLoginEnable/s/^# //" /etc/gdm/custom.conf
                sed -i "/^#.*AutomaticLogin/s/^# //" /etc/gdm/custom.conf
                sed -i "s/user1/\$USERNAME/" /etc/gdm/custom.conf
                ;;
            "lightdm")
                sed -i "s/^#autologin-user=.*/autologin-user=\$USERNAME/" /etc/lightdm/lightdm.conf
                sed -i "s/^#autologin-session=.*/autologin-session=/" /etc/lightdm/lightdm.conf
                ;;
            "sddm")
                mkdir -p /etc/sddm.conf.d
                echo -e "[Autologin]\nUser=\$USERNAME\nSession=plasma.desktop" > /etc/sddm.conf.d/autologin.conf
                if [ "$DE_CHOICE" == "Hyprland" ]; then
                    echo -e "[Autologin]\nUser=\$USERNAME\nSession=hyprland.desktop" > /etc/sddm.conf.d/autologin.conf
                fi
                ;;
        esac
    fi
fi

# --- Install yay AUR Helper ---
print_info "Setting up yay installation..."
runuser -l \$USERNAME -c 'git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay'

# --- Install Additional Software ---
print_info "Installing additional software..."
runuser -l \$USERNAME -c 'yay -S --noconfirm google-chrome'

if [[ "$INSTALL_STEAM" == "y" || "$INSTALL_STEAM" == "Y" ]]; then
    print_info "Installing Steam and ProtonUp-Qt..."
    pacman -S --noconfirm steam
    runuser -l \$USERNAME -c 'yay -S --noconfirm protonup-qt'
fi

print_info "Cleaning up..."
rm /chroot_setup.sh

print_info "Chroot setup complete."
EOF

# --- Execute Chroot Script ---
chmod +x /mnt/chroot_setup.sh
print_info "Entering chroot and executing setup script..."
arch-chroot /mnt /bin/bash /chroot_setup.sh "$HOSTNAME" "$USERNAME" "$USER_PASSWORD" "$ROOT_PASSWORD" "$AUTOLOGIN" "$DE_CHOICE" "$GPU_CHOICE" "$INSTALL_STEAM"

# --- Finalization ---
print_info "Installation finished successfully!"
umount -R /mnt
print_warning "Please remove the installation media and reboot your system."
read -p "Reboot now? (y/N): " REBOOT_NOW
if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
    reboot
fi
