#!/usr/bin/env bash
# NyxOS unattended install. Run from a stock CachyOS live environment.
#
#   NYX_DISK=/dev/nvme0n1 ./install.sh
#
# Replaces Calamares, not the live ISO. Boot the CachyOS ISO as normal, open a
# terminal, and run this instead of the graphical installer.
#
# Mirrors the module order in /usr/share/calamares/settings_online.conf:
#   partition -> mount -> initialize_pacman -> pacstrap -> fstab -> locale
#   -> chwd -> initcpio -> bootloader -> services -> provision
#
# No bootstrap user is created; roles/base creates nyx_user and nothing else.
set -euo pipefail

DISK="${NYX_DISK:?set NYX_DISK explicitly, e.g. /dev/nvme0n1}"
HOST="${NYX_HOST:-nyxos}"
REPO="${NYX_REPO:-https://github.com/abnachtrab/NyxOS}"
KERNEL="${NYX_KERNEL:-linux-cachyos}"
RECOVERY_GB="${NYX_RECOVERY_GB:-8}"
TZ="${NYX_TZ:-America/Phoenix}"
LOCALE="${NYX_LOCALE:-en_US.UTF-8}"
KEYMAP="${NYX_KEYMAP:-us}"
CMDLINE="${NYX_CMDLINE:-quiet nowatchdog}"

if [[ "${NYX_FORCE:-0}" != "1" ]] && ! grep -q 'nyxos.auto=1' /proc/cmdline; then
  echo "refusing to format ${DISK}: add nyxos.auto=1 to the kernel cmdline"
  echo "or set NYX_FORCE=1 to override."
  exit 1
fi

echo "About to erase ${DISK}."
lsblk "$DISK"
read -rp "type ERASE to continue: " confirm
[[ "$confirm" == "ERASE" ]] || exit 1

# --- partition ------------------------------------------------------------
wipefs -a "$DISK"
sgdisk -Z "$DISK"
sgdisk -n1:0:+1G                -t1:ef00 -c1:ESP       "$DISK"
sgdisk -n2:0:+"${RECOVERY_GB}"G -t2:8300 -c2:recovery  "$DISK"
sgdisk -n3:0:0                  -t3:8304 -c3:nyxroot "$DISK"
partprobe "$DISK"

if [[ "$DISK" =~ (nvme|mmcblk|loop) ]]; then P="${DISK}p"; else P="$DISK"; fi

mkfs.fat -F32 -n ESP       "${P}1"
mkfs.ext4 -F  -L recovery  "${P}2"
mkfs.ext4 -F  -L nyxroot "${P}3"    # LUKS lands here in Phase 10

mount "${P}3" /mnt
mount --mkdir "${P}1" /mnt/boot

# --- initialize_pacman ----------------------------------------------------
# Calamares ranks mirrors and builds the keyring on the live system, then
# copies both into the target. Copying /etc/pacman.d/gnupg avoids a second
# pacman-key --init inside the chroot.
pacman-key --init
for _ in {1..5}; do pacman -Sy --noconfirm --needed cachyos-keyring && break; done
for _ in {1..5}; do pacman -Sy --noconfirm --needed archlinux-keyring && break; done
pacman-key --populate

# --- pacstrap -------------------------------------------------------------
# Base list from /etc/calamares/modules/pacstrap.conf, minus tools for
# filesystems this install does not create.
pacstrap -K /mnt \
  base base-devel \
  "$KERNEL" "${KERNEL}-headers" linux-firmware \
  cachyos-hooks cachyos-keyring cachyos-settings \
  cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist \
  cachyos-rate-mirrors chwd \
  mkinitcpio cryptsetup device-mapper lvm2 mdadm \
  btrfs-progs dosfstools e2fsprogs exfatprogs xfsprogs \
  efibootmgr efitools sbctl refind \
  plymouth cachyos-plymouth-theme cachyos-plymouth-bootanimation \
  networkmanager sudo git ansible-core openssh \
  diffutils inetutils less logrotate lsb-release \
  man-db man-pages perl python texinfo usbutils which \
  zsh kitty

# --- copy pacman state into the target ------------------------------------
mkdir -p /mnt/etc/pacman.d
cp /etc/pacman.conf                  /mnt/etc/pacman.conf
cp /etc/pacman.d/mirrorlist          /mnt/etc/pacman.d/
cp /etc/pacman.d/cachyos*-mirrorlist /mnt/etc/pacman.d/
cp -a /etc/pacman.d/gnupg            /mnt/etc/pacman.d/
cp /etc/resolv.conf                  /mnt/etc/

# --- fstab / hostname -----------------------------------------------------
genfstab -U /mnt >> /mnt/etc/fstab
echo "$HOST" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST}.localdomain ${HOST}
EOF

# --- locale / keyboard ----------------------------------------------------
# English UI only. Glyph coverage for other scripts is a package concern
# (the noto-* set in group_vars), not a locale concern.
echo "${LOCALE} UTF-8"  > /mnt/etc/locale.gen
echo "LANG=${LOCALE}"   > /mnt/etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /mnt/etc/vconsole.conf

arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
locale-gen
ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
hwclock --systohc

# chwd runs before package installation in the Calamares sequence.
chwd -a || true

mkinitcpio -P
systemctl enable NetworkManager fstrim.timer

refind-install
CHROOT

# --- bootloader cmdline ---------------------------------------------------
# refind-install's mkrlconf builds refind_linux.conf from /proc/cmdline.
# arch-chroot does not create a new UTS/proc namespace, so inside the chroot
# that is the LIVE ISO's cmdline (archisobasedir=..., no root=), which
# produces entries that drop to an initramfs emergency shell on first boot.
# Write it here instead, where the real root UUID is known.
ROOT_UUID="$(blkid -s UUID -o value "${P}3")"
cat > /mnt/boot/refind_linux.conf <<EOF
"Boot with standard options"  "root=UUID=${ROOT_UUID} rw ${CMDLINE}"
"Boot to single-user mode"    "root=UUID=${ROOT_UUID} rw single"
"Boot with minimal options"   "root=UUID=${ROOT_UUID} rw"
EOF
echo "refind_linux.conf written for root=UUID=${ROOT_UUID}"

# --- provision ------------------------------------------------------------
git clone "$REPO" /mnt/root/NyxOS
arch-chroot /mnt /bin/bash -euo pipefail -c '
  cd /root/NyxOS
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook site.yml -c local -i localhost,
'

# Root stays locked (no password), matching Ubuntu/Fedora defaults. That
# makes systemd's emergency shell unusable, so recovery depends on the
# recovery partition or external media rather than single-user mode.
echo "done. umount -R /mnt && reboot"
