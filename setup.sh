#!/usr/bin/env bash
# Arch Linux automated installer (host side)
set -euo pipefail

#----- helper ---------------------------------------------------------------
pause() { read -rp ">>> $1 [Enter]"; }

#----- sanity ---------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

#----- collect basic information -------------------------------------------
echo
lsblk -dpno NAME,SIZE | grep -E "^/dev"
read -rp ">>> Select target disk (e.g. /dev/sda): " DISK

read -rp ">>> Create swap partition? (y/n) : " MAKE_SWAP
if [[ $MAKE_SWAP == y ]]; then
  read -rp ">>> Swap size in GiB (e.g. 4)   : " SWAPSIZE
fi

echo
echo "GPU driver:"
select GPU in nvidia amd intel; do
  [[ -n $GPU ]] && break
done

echo
read -rp ">>> Hostname                 : " HOSTNAME
read -rp ">>> New username             : " USERNAME
read -rsp ">>> Password (hidden)        : " PASSWORD; echo
read -rsp ">>> Confirm  (hidden)        : " PASSWORD2; echo
[[ "$PASSWORD" != "$PASSWORD2" ]] && { echo "Password mismatch"; exit 1; }

read -rp ">>> Enable autologin? (y/n)  : " AUTOLOGIN

echo
echo "Desktop Environment:"
select DE in gnome plasma xfce cinnamon mate; do
  [[ -n $DE ]] && break
done

echo
echo "Display Manager:"
select DM in gdm sddm lightdm lxdm ly; do
  [[ -n $DM ]] && break
done

echo
echo "Terminal Emulator:"
select TERMAPP in gnome-terminal konsole xfce4-terminal kitty alacritty; do
  [[ -n $TERMAPP ]] && break
done

echo
read -rp ">>> Install Steam? (y/n)     : " WANT_STEAM
read -rp ">>> Install ProtonUp-QT? (y/n): " WANT_PROTON

pause "All data on ${DISK} will be lost. Continue"

#----- partitioning ---------------------------------------------------------
echo "## Partitioning disk…"       # English comment
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on

START=513
if [[ $MAKE_SWAP == y ]]; then
  ENDSWAP=$((START + SWAPSIZE*1024))
  parted -s "$DISK" mkpart swap linux-swap "${START}MiB" "${ENDSWAP}MiB"
  parted -s "$DISK" set 2 swap on
  ROOTSTART=$ENDSWAP
  ROOTPART=3
else
  ROOTSTART=$START
  ROOTPART=2
fi
parted -s "$DISK" mkpart root ext4 "${ROOTSTART}MiB" 100%

ESP="${DISK}1"
ROOT="${DISK}${ROOTPART}"
[[ $MAKE_SWAP == y ]] && SWAPP="${DISK}2"

echo "## Formatting…"               # English comment
mkfs.fat -F32 "$ESP"
mkfs.ext4 -F "$ROOT"
[[ $MAKE_SWAP == y ]] && mkswap "$SWAPP"

echo "## Mounting…"                 # English comment
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$ESP" /mnt/boot
[[ $MAKE_SWAP == y ]] && swapon "$SWAPP"

#----- base system ----------------------------------------------------------
echo "## Installing base system…"   # English comment
pacstrap -K /mnt base linux linux-firmware sudo networkmanager base-devel git vim

genfstab -U /mnt >> /mnt/etc/fstab

#----- pass variables to chroot --------------------------------------------
install -Dm700 /dev/null /
