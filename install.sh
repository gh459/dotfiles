#!/usr/bin/env bash
# ------------------------------------------------------------
# Arch Linux automated installer (run on archiso) – setup.sh
# ------------------------------------------------------------
set -euo pipefail

echo "==> Gathering user input ..."
read -rp "Hostname: " HOSTNAME
read -rp "Username: " USERNAME
read -rp "Target drive (e.g. /dev/nvme0n1): " DRIVE
lsblk "$DRIVE"
read -rp "Proceed and destroy ALL data on $DRIVE? [yes/NO]: " ANS
[[ $ANS == yes ]] || { echo "Abort."; exit 1; }

read -rp "Create swap partition? [y/N]: " MAKE_SWAP
if [[ $MAKE_SWAP =~ ^[yY]$ ]]; then
  read -rp "Swap size (e.g. 4G): " SWAPSIZE
fi

echo "GPU driver: 1) nvidia  2) amd  3) intel"
read -rp "Select GPU [1-3]: " GPUSEL

echo "Desktop Env: 1) GNOME 2) KDE 3) XFCE 4) Cinnamon 5) MATE"
read -rp "Select DE [1-5]: " DESEL

echo "Display Mgr: 1) GDM 2) SDDM 3) LightDM 4) LXDM 5) None"
read -rp "Select DM [1-5]: " DMSEL

echo "Login Shell: 1) bash 2) zsh 3) fish 4) tcsh 5) nu"
read -rp "Select shell [1-5]: " SHELSEL

echo "Terminal EMU: 1) gnome-terminal 2) konsole 3) xfce4-terminal 4) tilix 5) alacritty"
read -rp "Select terminal [1-5]: " TERMSEL

read -rp "Enable autologin (graphical or tty) ? [y/N]: " AUTOLOGIN
read -rp "Install Steam ? [y/N]: " WANT_STEAM
read -rp "Install ProtonUp-Qt ? [y/N]: " WANT_PROTON

# ------------------------------------------------------------
# Partitioning
# ------------------------------------------------------------
echo "==> Partitioning drive ..."
sgdisk --zap-all "$DRIVE"
parted -s "$DRIVE" mklabel gpt
parted -s "$DRIVE" mkpart ESP fat32 1MiB 1025MiB
parted -s "$DRIVE" set 1 esp on
if [[ $MAKE_SWAP =~ ^[yY]$ ]]; then
  parted -s "$DRIVE" mkpart primary linux-swap 1025MiB "$((1025 + $(numfmt --from=iec "$SWAPSIZE") / 1024 / 1024))"MiB
  ROOT_START="$((1025 + $(numfmt --from=iec "$SWAPSIZE") / 1024 / 1024))"
else
  ROOT_START=1025
fi
parted -s "$DRIVE" mkpart primary ext4 "${ROOT_START}MiB" 100%

EFI="${DRIVE}1"
if [[ $MAKE_SWAP =~ ^[yY]$ ]]; then SWAPP="${DRIVE}2"; ROOTP="${DRIVE}3"; else ROOTP="${DRIVE}2"; fi

echo "==> Formatting ..."
mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOTP"
if [[ $MAKE_SWAP =~ ^[yY]$ ]]; then mkswap "$SWAPP"; swapon "$SWAPP"; fi

echo "==> Mounting ..."
mount "$ROOTP" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# ------------------------------------------------------------
# Base install
# ------------------------------------------------------------
echo "==> Installing base system ..."
pacstrap -K /mnt base base-devel linux linux-firmware linux-headers networkmanager sudo vim \
  git # base set[1][2]

genfstab -U /mnt >> /mnt/etc/fstab

# ------------------------------------------------------------
# Pass variables to chroot
# ------------------------------------------------------------
cat > /mnt/root/install.conf <<EOF
HOSTNAME=$HOSTNAME
USERNAME=$USERNAME
GPUSEL=$GPUSEL
DESEL=$DESEL
DMSEL=$DMSEL
SHELSEL=$SHELSEL
TERMSEL=$TERMSEL
AUTOLOGIN=$AUTOLOGIN
WANT_STEAM=$WANT_STEAM
WANT_PROTON=$WANT_PROTON
MAKE_SWAP=$MAKE_SWAP
EOF

cp "$(dirname "$0")/chroot_setup.sh" /mnt/root/
chmod +x /mnt/root/chroot_setup.sh

echo "==> Entering chroot ..."
arch-chroot /mnt /root/chroot_setup.sh

echo "==> Installation finished. You may reboot."
