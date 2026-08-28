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
#
# Failure policy: every failure is loud and names the stage it happened in.
# Nothing is retried silently, nothing is ignored without saying so. The
# target stays mounted at /mnt when something goes wrong, so the half-built
# system can be inspected rather than vanishing.
set -Eeuo pipefail   # -E so the ERR trap fires inside functions and subshells

STAGE="startup"

on_err() {
    local rc=$? line=$1
    echo                                                              >&2
    echo "==============================================================" >&2
    echo " INSTALL FAILED"                                            >&2
    echo "   stage:    ${STAGE}"                                      >&2
    echo "   line:     ${line}"                                       >&2
    echo "   command:  ${BASH_COMMAND}"                               >&2
    echo "   exit:     ${rc}"                                         >&2
    echo "==============================================================" >&2
    case "$STAGE" in
        startup|preflight)
            echo " Nothing was written. The disk is untouched."       >&2
            ;;
        partition|format)
            echo " The partition table and/or filesystems were being" >&2
            echo " rewritten. The disk is NOT usable as it stands."   >&2
            echo " Re-running this script starts over cleanly."       >&2
            ;;
        *)
            echo " The target is partially built and still mounted"   >&2
            echo " at /mnt so it can be inspected. Release it with:"  >&2
            echo "   umount -R /mnt"                                  >&2
            echo " Re-running this script wipes and starts over."     >&2
            ;;
    esac
}
trap 'on_err $LINENO' ERR

# The vars file holds the password hash. Without this it survives any failure
# between writing it and the explicit removal after provisioning.
cleanup() {
    if [[ -n "${VARS_FILE:-}" && -f "$VARS_FILE" ]]; then
        rm -f "$VARS_FILE"
        echo "removed ${VARS_FILE}" >&2
    fi
}
trap cleanup EXIT

# Retry with backoff, and FAIL if every attempt fails. A bare
# `for ... do cmd && break; done` cannot trip errexit — the failing command is
# the left operand of &&, which errexit exempts — so a 5-of-5 failure would
# continue silently and surface as something unrelated much later.
retry() {
    local n=0 max=5
    until "$@"; do
        n=$((n + 1))
        if (( n >= max )); then
            echo "FAILED after ${n} attempts: $*" >&2
            return 1
        fi
        echo "attempt ${n}/${max} failed, retrying in $((n * 5))s: $*" >&2
        sleep $((n * 5))
    done
}

DISK="${NYX_DISK:?set NYX_DISK explicitly, e.g. /dev/nvme0n1}"
HOST="${NYX_HOST:-nyxos}"
REPO="${NYX_REPO:-https://github.com/abnachtrab/NyxOS}"
# Branch to provision from. Lets an unproven branch be installed on a
# throwaway machine without merging it to main first.
BRANCH="${NYX_BRANCH:-main}"
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
#
# findmnt exits 1 when nothing matches, which is a legitimate "no mounts", but
# any other failure would make this return empty — and an empty result makes
# the safety check below pass without checking anything. Distinguish them.
disk_mounts() {
  local out rc
  out=$(findmnt -rno TARGET,SOURCE); rc=$?
  if (( rc > 1 )); then
    echo "findmnt failed (exit ${rc}); cannot determine what is mounted." >&2
    echo "Refusing to touch ${DISK} without knowing that." >&2
    exit 1
  fi
  printf '%s\n' "$out" | awk -v d="$DISK" 'index($2, d) == 1 { print $1 }'
}

STAGE="preflight"

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

echo "About to erase ${DISK}. Provisioning from ${REPO} (${BRANCH})."
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

STAGE="release"
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

STAGE="partition"
# --- partition ------------------------------------------------------------
wipefs -a "$DISK"
sgdisk -Z "$DISK"
sgdisk -n1:0:+1G                -t1:ef00 -c1:ESP       "$DISK"
sgdisk -n2:0:+"${RECOVERY_GB}"G -t2:8300 -c2:recovery  "$DISK"
sgdisk -n3:0:0                  -t3:8304 -c3:nyxroot "$DISK"
partprobe "$DISK"

if [[ "$DISK" =~ (nvme|mmcblk|loop) ]]; then P="${DISK}p"; else P="$DISK"; fi

# partprobe issues BLKRRPART and returns; udev creates the partition nodes
# asynchronously. Without waiting, the wipefs below can run before
# /dev/<disk>3 exists and abort with "No such file or directory", which reads
# like a wrong NYX_DISK rather than a race. Intermittent, and worse on a
# loaded host.
udevadm settle || echo "WARNING: udevadm settle failed; polling for nodes" >&2
for dev in "${P}1" "${P}2" "${P}3"; do
  for _ in {1..20}; do [[ -b "$dev" ]] && break; sleep 0.5; done
  if [[ ! -b "$dev" ]]; then
    echo "partition node ${dev} never appeared after partprobe." >&2
    echo "The partition table was written but the kernel has not published" >&2
    echo "the nodes. Re-running the script is safe." >&2
    exit 1
  fi
done

# sgdisk -Z zaps the partition table, not the filesystem superblocks inside
# the ranges it re-creates. On a re-install those survive at the same offsets,
# and an untyped mount probes the stale one: mkfs.btrfs succeeds, then
# `mount /dev/sda3 /mnt` reads the old ext4 super and reports the new
# filesystem as corrupt. Clear each partition before laying anything down.
wipefs -a "${P}1" "${P}2" "${P}3"

STAGE="format"
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

STAGE="keyring"
# --- initialize_pacman ----------------------------------------------------
# Calamares ranks mirrors and builds the keyring on the live system, then
# copies both into the target. Copying /etc/pacman.d/gnupg avoids a second
# pacman-key --init inside the chroot.
pacman-key --init
retry pacman -Sy --noconfirm --needed cachyos-keyring
retry pacman -Sy --noconfirm --needed archlinux-keyring
pacman-key --populate

STAGE="pacstrap"
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
  fish kitty

# --- copy pacman state into the target ------------------------------------
mkdir -p /mnt/etc/pacman.d
cp /etc/pacman.conf                  /mnt/etc/pacman.conf
cp /etc/pacman.d/mirrorlist          /mnt/etc/pacman.d/
cp /etc/pacman.d/cachyos*-mirrorlist /mnt/etc/pacman.d/
cp -a /etc/pacman.d/gnupg            /mnt/etc/pacman.d/
# Only so the chroot has DNS for pacstrap and the playbook. Removed again
# after provisioning — see below. arch-chroot does not bind-mount this,
# so copying it is the usual technique, but leaving it behind gives the
# installed system the ISO's nameservers as a static file.
cp /etc/resolv.conf                  /mnt/etc/

STAGE="configure"
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

# A heredoc would make the chroot script itself stdin, so anything inside that
# reads stdin — a pacman confirmation prompt from chwd on a machine that has a
# real GPU — consumes the remaining lines. They never run, and the block still
# exits 0. That would leave a system with no initramfs and no bootloader while
# reporting success. Use -c and give it /dev/null instead.
#
# TZ is exported rather than interpolated because single quotes do not expand;
# arch-chroot passes the environment through.
STAGE="chroot" TZ="$TZ" arch-chroot /mnt /bin/bash -Eeuo pipefail -c '
  locale-gen
  ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  hwclock --systohc

  # chwd runs before package installation in the Calamares sequence. Its
  # failure is not fatal — a machine with no matching profile is normal — but
  # it is reported rather than discarded, because on real hardware this is the
  # only step that configures graphics drivers.
  if ! chwd -a </dev/null; then
      echo "WARNING: chwd -a failed; no driver profile was applied." >&2
      echo "         roles/gpu runs later and may still fix this."   >&2
  fi

  mkinitcpio -P
  systemctl enable NetworkManager fstrim.timer

  refind-install </dev/null
' </dev/null

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

STAGE="provision"
# --- provision ------------------------------------------------------------
git clone --branch "$BRANCH" "$REPO" /mnt/root/NyxOS

# Defining nyx_password_hash as an extra var makes Ansible skip its
# vars_prompt, and tells roles/base the value is already hashed rather than
# plaintext for it to hash.
# VARS_FILE is what the EXIT trap removes, so the hash does not survive a
# failure between here and the explicit removal below.
VARS_FILE=/mnt/root/.nyx-vars.yml
install -m 600 /dev/null "$VARS_FILE"
printf 'nyx_password_hash: "%s"\n' "$PW_HASH" > "$VARS_FILE"
unset PW_HASH

# No become password: this runs as root in the chroot. ansible.cfg no longer
# sets become_ask_pass, which used to prompt at startup — before any variable
# was considered, so -e ansible_become_password could not suppress it and the
# prompt accepted anything non-empty. Running the playbook by hand passes
# --ask-become-pass explicitly instead.
arch-chroot /mnt /bin/bash -Eeuo pipefail -c '
  cd /root/NyxOS
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook site.yml -c local -i localhost, \
    -e @/root/.nyx-vars.yml
' </dev/null

# shred cannot guarantee anything on btrfs: copy-on-write means the
# overwrite lands in new extents and the original blocks stay until they are
# reclaimed. The file holds a hash rather than a plaintext password, so this
# removes it without claiming the data is unrecoverable.
rm -f "$VARS_FILE"
unset VARS_FILE

# The ISO's resolv.conf was only needed for DNS inside the chroot. Left in
# place it is a static file holding the ISO's nameservers, sitting where
# NetworkManager and systemd-resolved both expect to own the path.
# NetworkManager writes its own on the first connection after boot.
rm -f /mnt/etc/resolv.conf

STAGE="finish"
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
