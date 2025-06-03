#!/bin/bash

set -e

# ==========================
# Configuration Section
# ==========================
DISK="/dev/sda" # Installation disk
EFI_PARTITION="${DISK}1" # EFI system partition
ROOT_PARTITION="${DISK}2" # Root partition
SWAP_PARTITION="${DISK}3" # Swap partition

HOSTNAME="myarch" # Hostname
TIMEZONE="Asia/Tokyo" # Timezone
LOCALE_LANG="ja_JP.UTF-8" # Locale
KEYMAP="jp106" # Keyboard map

EXTRA_PACKAGES="xorg-server xorg-xinit xorg-apps xf86-input-libinput \
lxqt lxqt-arch-config lxqt-policykit lxqt-session lxqt-admin \
openbox obconf sddm pcmanfm-qt qterminal featherpad \
ttf-dejavu ttf-liberation noto-fonts pipewire pipewire-pulse pavucontrol"
# ==========================

# Username and password input
echo -n "Enter the username to create: "
read USERNAME
while true; do
    echo -n "Enter password for ${USERNAME}: "
    read -s PASSWORD
    echo
    echo -n "Re-enter password: "
    read -s PASSWORD_CONFIRM
    echo
    if [ "$PASSWORD" == "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo "Passwords do not match. Please try again."
    fi
done

# Confirmation
echo "-------------------------"
echo "Please confirm the installation settings:"
echo "Disk: ${DISK}"
echo "EFI Partition: ${EFI_PARTITION}"
echo "Root Partition: ${ROOT_PARTITION}"
echo "Swap Partition: ${SWAP_PARTITION}"
echo "Hostname: ${HOSTNAME}"
echo "Timezone: ${TIMEZONE}"
echo "Locale: ${LOCALE_LANG}"
echo "Keymap: ${KEYMAP}"
echo "Extra Packages: ${EXTRA_PACKAGES}"
echo "Username: ${USERNAME}"
echo "-------------------------"
echo "All data on ${DISK} will be erased. Do you want to continue? (yes/no)"
read confirmation
if [ "$confirmation" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# System clock
timedatectl set-ntp true

# Mirrorlist optimization
pacman -Sy reflector --noconfirm --needed
reflector --country Japan --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Partition formatting
mkfs.fat -F32 "${EFI_PARTITION}"
mkfs.ext4 "${ROOT_PARTITION}"
mkswap "${SWAP_PARTITION}"
swapon "${SWAP_PARTITION}"

# Mount
mount "${ROOT_PARTITION}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PARTITION}" /mnt/boot/efi

# Base system installation
pacstrap /mnt base base-devel linux linux-firmware grub efibootmgr networkmanager sudo git vim

# fstab generation
genfstab -U /mnt >> /mnt/etc/fstab

# Create chroot setup script
cat <<EOF > /mnt/root/chroot-setup.sh
#!/bin/bash

set -e

USERNAME="${USERNAME}"
PASSWORD="${PASSWORD}"
HOSTNAME="${HOSTNAME}"
TIMEZONE="${TIMEZONE}"
LOCALE_LANG="${LOCALE_LANG}"
KEYMAP="${KEYMAP}"
EXTRA_PACKAGES="${EXTRA_PACKAGES}"

ln -sf /usr/share/zoneinfo/\${TIMEZONE} /etc/localtime
hwclock --systohc

echo "\${LOCALE_LANG} UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=\${LOCALE_LANG}" > /etc/locale.conf
echo "KEYMAP=\${KEYMAP}" > /etc/vconsole.conf

echo "\${HOSTNAME}" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
HOSTS

mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

useradd -m -G wheel -s /bin/bash "\${USERNAME}"
echo "\${USERNAME}:\${PASSWORD}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

pacman -S --noconfirm --needed \${EXTRA_PACKAGES}

systemctl enable sddm
systemctl enable NetworkManager

sudo -u "\${USERNAME}" bash -c '
cd ~
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay
yay -S --noconfirm google-chrome
'

echo "Chroot setup complete."
EOF

chmod +x /mnt/root/chroot-setup.sh

# Run chroot setup
arch-chroot /mnt /root/chroot-setup.sh

# Final step
echo "Installation is complete. Unmount and reboot? (yes/no)"
read reboot_confirmation
if [ "$reboot_confirmation" == "yes" ]; then
    umount -R /mnt
    reboot
else
    echo "Please run 'umount -R /mnt && reboot' manually."
fi
