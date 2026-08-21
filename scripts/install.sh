#!/usr/bin/env bash
# NyxOS unattended install. Run from a CachyOS/Arch live environment.
#
#   NYX_DISK=/dev/nvme0n1 ./install.sh
#
# Destructive. NYX_DISK has no default and must be set explicitly.
set -euo pipefail

DISK="${NYX_DISK:?set NYX_DISK explicitly, e.g. /dev/nvme0n1}"
HOST="${NYX_HOST:-nyxos}"
REPO="${NYX_REPO:-https://github.com/CHANGEME/nyxos-installer}"
RECOVERY_GB="${NYX_RECOVERY_GB:-8}"

# Safety rail for real hardware: only proceed if explicitly flagged at boot.
if [[ "${NYX_FORCE:-0}" != "1" ]] && ! grep -q 'nyxos.auto=1' /proc/cmdline; then
  echo "refusing to format ${DISK}: add nyxos.auto=1 to the kernel cmdline"
  echo "or set NYX_FORCE=1 to override."
  exit 1
fi

echo "About to erase ${DISK}."
lsblk "$DISK"
read -rp "type ERASE to continue: " confirm
[[ "$confirm" == "ERASE" ]] || exit 1

wipefs -a "$DISK"
sgdisk -Z "$DISK"
sgdisk -n1:0:+1G                 -t1:ef00 -c1:ESP        "$DISK"
sgdisk -n2:0:+"${RECOVERY_GB}"G  -t2:8300 -c2:recovery   "$DISK"
sgdisk -n3:0:0                   -t3:8304 -c3:nyxroot    "$DISK"
partprobe "$DISK"

if [[ "$DISK" =~ (nvme|mmcblk|loop) ]]; then P="${DISK}p"; else P="$DISK"; fi

mkfs.fat -F32 -n ESP       "${P}1"
mkfs.ext4 -F  -L recovery  "${P}2"
mkfs.ext4 -F  -L nyxroot   "${P}3"     # LUKS lands here later — Phase 10

mount "${P}3" /mnt
mount --mkdir "${P}1" /mnt/boot

pacstrap -K /mnt \
  base base-devel linux-firmware \
  linux-cachyos linux-cachyos-headers \
  networkmanager sudo git ansible-core openssh \
  fish kitty fastfetch

genfstab -U /mnt >> /mnt/etc/fstab
echo "$HOST" > /mnt/etc/hostname

git clone "$REPO" /mnt/root/nyxos-installer

arch-chroot /mnt /bin/bash -euo pipefail -c '
  cd /root/nyxos-installer
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook site.yml -c local -i localhost,
'

echo "done. umount -R /mnt && reboot"
