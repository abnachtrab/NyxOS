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
PRIMARY_USER="${NYX_USER:-abnac}"   # display only; group_vars/all.yml is authoritative

if [[ "${NYX_FORCE:-0}" != "1" ]] && ! grep -q 'nyxos.auto=1' /proc/cmdline; then
  echo "refusing to format ${DISK}: add nyxos.auto=1 to the kernel cmdline"
  echo "or set NYX_FORCE=1 to override."
  exit 1
fi

# Every mountpoint currently backed by a partition of $DISK.
disk_mounts() {
  findmnt -rno TARGET,SOURCE | awk -v d="$DISK" 'index($2, d) == 1 { print $1 }'
}

# Refuse before prompting for anything if the target is carrying the running
# system or the live medium. Checked read-only; nothing is unmounted here.
for mp in $(disk_mounts); do
  case "$mp" in
    / | /run/archiso/* | /run/initramfs/* )
      echo "refusing to touch ${DISK}: it is mounted at ${mp} and in use by"
      echo "the running system. Boot the ISO from other media, or set"
      echo "NYX_DISK to the disk you actually mean to install to."
      exit 1
      ;;
  esac
done

# When the script is piped (curl | bash) stdin is the script itself, so read
# would consume script text instead of keystrokes. Take input from the
# terminal explicitly.
if ! { exec 3< /dev/tty; } 2>/dev/null; then
  echo "no controlling terminal. Download the script and run it directly:"
  echo "  curl -sLO ${REPO}/raw/main/scripts/install.sh"
  echo "  NYX_DISK=${DISK} NYX_FORCE=1 bash install.sh"
  exit 1
fi
exec 3<&-

echo "About to erase ${DISK}."
lsblk "$DISK"
read -rp "type ERASE to continue: " confirm < /dev/tty
[[ "$confirm" == "ERASE" ]] || exit 1

# --- credentials ----------------------------------------------------------
# Asked here rather than by the playbook's vars_prompt, which only runs after
# pacstrap. Hashed immediately; the plaintext never leaves this shell and the
# hash is passed by file, not on a command line visible in ps.
while :; do
  read -rsp "Password for ${PRIMARY_USER:-the primary user}: " pw1 < /dev/tty; echo
  read -rsp "Confirm: " pw2 < /dev/tty; echo
  [[ -n "$pw1" && "$pw1" == "$pw2" ]] && break
  echo "empty or mismatched, try again."
done
PW_HASH="$(printf '%s' "$pw1" | openssl passwd -6 -stdin)"
unset pw1 pw2

# --- release the device ---------------------------------------------------
# A partition that is still mounted or in use as swap cannot be repartitioned
# cleanly: mkfs refuses, or partprobe declines to re-read the table and the
# kernel keeps the old geometry. Either way the failure surfaces much later
# as something that looks unrelated. A previous run of this script is the
# usual source.
if findmnt -rno TARGET /mnt >/dev/null 2>&1; then
  echo "unmounting existing /mnt tree"
  umount -R /mnt
fi

for mp in $(disk_mounts | sort -r); do
  echo "unmounting ${mp} (backed by ${DISK})"
  umount -R "$mp"
done

while read -r sdev _; do
  case "$sdev" in
    "$DISK"*) echo "swapoff ${sdev}"; swapoff "$sdev" ;;
  esac
done < <(tail -n +2 /proc/swaps)

# --- partition ------------------------------------------------------------
wipefs -a "$DISK"
sgdisk -Z "$DISK"
sgdisk -n1:0:+1G                -t1:ef00 -c1:ESP       "$DISK"
sgdisk -n2:0:+"${RECOVERY_GB}"G -t2:8300 -c2:recovery  "$DISK"
sgdisk -n3:0:0                  -t3:8304 -c3:nyxroot "$DISK"
partprobe "$DISK"

if [[ "$DISK" =~ (nvme|mmcblk|loop) ]]; then P="${DISK}p"; else P="$DISK"; fi

# sgdisk -Z zaps the partition table, not the filesystem superblocks inside
# the ranges it re-creates. On a re-install those survive at the same offsets,
# and an untyped mount probes the stale one: mkfs.btrfs succeeds, then
# `mount /dev/sda3 /mnt` reads the old ext4 super and reports the new
# filesystem as corrupt. Clear each partition before laying anything down.
wipefs -a "${P}1" "${P}2" "${P}3"

mkfs.fat -F32 -n ESP      "${P}1"
mkfs.ext4 -F -L recovery  "${P}2"   # rescue volume; kept simple on purpose
mkfs.btrfs -f -L nyxroot  "${P}3"   # LUKS goes under this in Phase 10

# Subvolume layout copied from CachyOS's Calamares, so a NyxOS install and a
# stock CachyOS install have the same shape and snapshot tooling written for
# one works on the other. @cache, @tmp and @log are separate so a root
# snapshot does not carry package caches or logs.
mount -t btrfs "${P}3" /mnt
for sv in @ @home @root @srv @cache @tmp @log; do
  btrfs subvolume create "/mnt/${sv}"
done
umount /mnt

# zstd:3 is the CachyOS default. noatime because atime on COW means a write
# for every read.
BTRFS_OPTS="noatime,compress=zstd:3"

mount -t btrfs -o "subvol=@,${BTRFS_OPTS}" "${P}3" /mnt
mkdir -p /mnt/home /mnt/root /mnt/srv /mnt/var/cache /mnt/var/tmp /mnt/var/log /mnt/boot
mount -t btrfs -o "subvol=@home,${BTRFS_OPTS}"  "${P}3" /mnt/home
mount -t btrfs -o "subvol=@root,${BTRFS_OPTS}"  "${P}3" /mnt/root
mount -t btrfs -o "subvol=@srv,${BTRFS_OPTS}"   "${P}3" /mnt/srv
mount -t btrfs -o "subvol=@cache,${BTRFS_OPTS}" "${P}3" /mnt/var/cache
mount -t btrfs -o "subvol=@tmp,${BTRFS_OPTS}"   "${P}3" /mnt/var/tmp
mount -t btrfs -o "subvol=@log,${BTRFS_OPTS}"   "${P}3" /mnt/var/log
mount -t vfat "${P}1" /mnt/boot

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
# rootflags=subvol=@ is required: the root filesystem is a subvolume, and
# without it the kernel mounts the top level, where there is no /sbin/init.
ROOT_UUID="$(blkid -s UUID -o value "${P}3")"
cat > /mnt/boot/refind_linux.conf <<EOF
"Boot with standard options"  "root=UUID=${ROOT_UUID} rw rootflags=subvol=@ ${CMDLINE}"
"Boot to single-user mode"    "root=UUID=${ROOT_UUID} rw rootflags=subvol=@ single"
"Boot with minimal options"   "root=UUID=${ROOT_UUID} rw rootflags=subvol=@"
EOF
echo "refind_linux.conf written for root=UUID=${ROOT_UUID} subvol=@"

# --- provision ------------------------------------------------------------
git clone "$REPO" /mnt/root/NyxOS

# Defining nyx_password as an extra var makes Ansible skip its vars_prompt.
install -m 600 /dev/null /mnt/root/.nyx-vars.yml
printf 'nyx_password: "%s"\n' "$PW_HASH" > /mnt/root/.nyx-vars.yml
unset PW_HASH

arch-chroot /mnt /bin/bash -euo pipefail -c '
  cd /root/NyxOS
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook site.yml -c local -i localhost, -e @/root/.nyx-vars.yml
'
# shred cannot guarantee anything on btrfs: copy-on-write means the
# overwrite lands in new extents and the original blocks stay until they are
# reclaimed. The file holds a hash rather than a plaintext password, so this
# removes it without claiming the data is unrecoverable.
rm -f /mnt/root/.nyx-vars.yml

# Unmount here rather than leaving it to the caller: the tree is nested seven
# subvolumes deep, and leaving it mounted is what a re-run then trips over.
if ! umount -R /mnt; then
  echo "warning: /mnt did not unmount cleanly. Something still holds it:"
  fuser -vm /mnt || true
  echo "The install is complete; unmount before rebooting."
fi

# Root stays locked (no password), matching Ubuntu/Fedora defaults. That
# makes systemd's emergency shell unusable, so recovery depends on the
# recovery partition or external media rather than single-user mode.
echo "done. reboot when ready."
