# Notes

## Unverified — check before relying on these

Written from memory during design, and not confirmed against upstream. The
sections below this one record things that were actually run.

- **CachyOS signing key ID** for the archiso build host. Take it from the official install
  documentation.
- **`sbctl status --json` field names** — `roles/detect` reads `secure_boot`
  and nothing else. `setup_mode` and `installed` are unread; Phase 10 needs
  `setup_mode`, so confirm all three on the installed version. The failure
  path is verified: with sbctl absent the task fails soft and `secureboot`
  falls back to `false`.
- **Hyper-V framebuffer module** — `hyperv_drm` on current kernels,
  `hyperv_fb` on older. The `video=` cmdline param differs.
- **nvidia-open vs proprietary cutoff.** Turing and newer for open modules;
  recent driver branches dropped Maxwell/Pascal/Volta entirely.
  `nyx_nvidia_packages` names `nvidia-open-dkms` outright, so a pre-Turing
  card needs that list overridden — chwd would pick a legacy branch and
  pacman will not hold both.
- **Intel media driver split.** `intel-media-driver` for Gen8+,
  `libva-intel-driver` below. `i915` vs `xe` on the newest parts.

## Verified on Hyper-V (Gen 2, linux-cachyos, Zen 5 host)

- CachyOS repo sections on a Zen 5 install are `cachyos-znver4`,
  `cachyos-core-znver4`, `cachyos-extra-znver4`, plus generic `cachyos`.
  All four Include `/etc/pacman.d/cachyos-v4-mirrorlist` or
  `cachyos-mirrorlist`. Section names are Zen-generation-specific and do not
  derive from the x86-64-vN level, so `roles/base` reads them instead of
  generating them. The v3 naming on Intel hardware is still unconfirmed;
  check on real hardware.
- `ansible_virtualization_type` returns `VirtualPC`. Other keys pruned.
- `march` detection returns `x86-64-v4`; host CPU flags pass through.
- `has_tpm` true with the vTPM enabled.

## Idempotency traps found on the second base run

- `ansible.builtin.command` cannot run shell builtins. `command -v` there
  returns rc!=0 forever and silently re-runs whatever it guards.
- `vars_prompt` with `encrypt:` re-salts every run, so `user:` reports changed
  unless `update_password: on_create` is set.
- Create/revoke pairs (the temporary sudoers grant) always report changed
  unless gated on whether the work between them is actually needed.

## Open questions

- Two user accounts now exist: `adam` (from the CachyOS installer) and
  `abnac` (created by `roles/base` from `nyx_user`). Pick one. `run.ps1`
  defaults to `abnac@nyxos-test`, which only works if the checkpoint was
  made after that account existed.
- `/etc/sudoers.d/10-installer` was left by the CachyOS installer. Check its
  contents; if it grants passwordless sudo, `roles/base` should remove it.
- Ansible warns that `/home/<user>/.ansible/tmp` was created 0700. Benign
  when become_user owns it; breaks if the playbook runs as root against a
  different `nyx_user`.
- `nyx_hypr_wallpaper` is still empty and there is no dotfiles role, so a
  fresh session has no wallpaper and zsh prompts `zsh-newuser-install` on
  the first terminal.

## Theme

Palette and semantic role map live in `roles/theme/defaults/main.yml`.
Applications consume role names (primary, success, panel) rather than colour
names, so reassigning a role is one line.

Adding an application: write a template in `roles/theme/templates/`, add a
line to `nyx_theme_targets`. Do not put hex values anywhere else.

Primary is haze `#C7B8E8` (pastel purple), secondary is mist `#B4CDE6`
(pastel blue).

Still unthemed: the greetd greeter (tuigreet takes a TTY colour scheme, not
the palette), GTK, Qt (Kvantum), rEFInd, Plymouth, bat, fzf, zsh syntax
highlighting, btop. `hyprlock.conf` already reads `nyx_palette` directly.

## Verified by running

- `roles/detect` and `roles/theme` run clean; theme is idempotent on the
  second pass (changed=0).
- Rendered `colors.sh` sources into a shell with the expected role values.
- `-e @profiles/...` correctly reports OVERRIDE and skips detection.

Bug found and fixed: microarch detection originally shelled out to
`/lib/ld-linux-x86-64.so.2`. That path only exists where /lib is a symlink to
/usr/lib (Arch does this, Debian/Ubuntu do not), and the task failed soft —
reporting x86-64-v1 on a v4 machine. It now derives the level from
/proc/cpuinfo flags, which has no path dependency.

## Bugs found on the first real install

**refind_linux.conf built from the wrong cmdline.** `refind-install` runs
`mkrlconf`, which reads `/proc/cmdline`. `arch-chroot` bind-mounts the host's
`/proc` rather than creating a namespace, so inside the chroot that is the
live ISO's cmdline — `archisobasedir=arch archisosearchuuid=... cow_spacesize=10G`
with no `root=`. Result: the initramfs cannot switch root, and the machine
drops to an emergency shell on first boot. Fixed by writing
`refind_linux.conf` from `install.sh` after the chroot block, using
`blkid -s UUID -o value` on the real root partition.

Anything else that reads `/proc` or `/sys` inside `arch-chroot` has the same
exposure. `lspci` and DMI are fine (they describe hardware, which is shared);
`/proc/cmdline` and the UTS hostname are not.

**Hostname read from the live environment.** Same root cause —
`ansible_hostname` reflects the running UTS namespace. `roles/detect` now
reads `/etc/hostname` and falls back to the fact.

**Root is deliberately locked**, matching Ubuntu/Fedora. That makes systemd's
emergency shell unusable ("Cannot open access to console, the root account is
locked"), so recovery depends on the recovery partition or external media.
Worth pulling the recovery partition earlier than Phase 10 for this reason.

## curl | bash and read

Piping the installer makes stdin the script itself, so `read` consumes script
text rather than keystrokes — the ERASE prompt and the password loop both
misbehave. All three prompts now read from `/dev/tty` explicitly, and the
script exits with instructions if there is no controlling terminal.

Documented usage is download-then-run, which also lets the script be read
before it formats a disk.

## Password handling

`install.sh` prompts before partitioning, hashes with `openssl passwd -6`
immediately, and writes the hash to `/root/.nyx-vars.yml` (0600) in the
target. The playbook is invoked with `-e @/root/.nyx-vars.yml`, which makes
Ansible skip its own `vars_prompt` — verified. The file is removed after.

Plaintext never leaves the installer's shell, and the hash is passed by file
rather than on a command line where `ps` would expose it.

It is removed rather than shredded. `shred` guarantees nothing on btrfs:
copy-on-write puts the overwrite in new extents and leaves the original
blocks until they are reclaimed. What is written is a hash, not a password,
so this is a downgrade in a claim rather than in exposure.

The playbook's `vars_prompt` remains as the fallback for running
`ansible-playbook` by hand on an installed system.

`roles/base` uses `update_password: on_create`, so re-running the playbook
does not reset an existing password.

## Known gaps

- No LUKS in `install.sh` yet — p3 is bare btrfs until Phase 10.
- `nyx_backup_paths` is a guess; set it to real directories.
- `branding` and `backup_rclone` are
  stubs that print the profile and exit 0.

## Scope

Laptop support was removed entirely — no `is_laptop` fact, no `laptop` role,
no battery/backlight/lid handling. Targets are VMs and desktops only.

Desktop branching that remains:

- **CPU vendor** (`cpu`): detected but consumed by nothing yet. Intended for
  `intel-ucode` / `amd-ucode` selection and pstate; neither is implemented,
  so no role branches on it today.
- **GPU vendor** (`gpus`): chwd picks the driver; `roles/gpu` adds NVIDIA
  early-KMS and cmdline, and `conf.d/env.conf` sets VA-API/VDPAU per vendor
  (nvidia / radeonsi / iHD).
- **VM** (`is_vm`): software GL and sshd, and skipping `roles/gpu` and
  `roles/backup_rclone`. Nothing cosmetic — see "The VM is a design surface"
  below.

Override profiles: `hyperv`, `intel-desktop-v3`, `amd-desktop-v4`,
`nvidia-desktop-v4`, `nvidia-intel-desktop-v4` (hybrid, for the i915
ordering path).

## Wallpaper

`nyx_hypr_wallpaper` defaults to empty. `hyprlock.conf` then renders
`color = rgb(<base>)`; `hyprpaper.conf` renders no `preload`/`wallpaper`
pair at all, leaving the compositor's own background. A path pointing at a
file that does not exist makes hyprlock fail to draw a background rather
than falling back, so do not set it until roles/branding ships a real
image.

## Hyprland syntax drift (found on first boot)

Four config errors on the first real session, all fixed:

- `togglesplit` is a dwindle **layout message**, not a top-level dispatcher.
  `bind = $mod, S, layoutmsg, togglesplit`.
- `windowrulev2` was merged back into `windowrule` and now warns as
  deprecated. Same argument syntax.
- The session must launch via `start-hyprland`, not the bare `Hyprland`
  binary, which warns about not being started through a session manager.
  `/usr/bin/start-hyprland` is owned by the `hyprland` package, so it is
  always present — it was briefly assumed to come from hyprlogin-git and
  both launch paths were switched to the bare binary; `pacman -Qo` on a real
  install disproved that. Set in `files/hyprland.desktop` and the tuigreet
  `--cmd`.
- Hyprland warns that `.conf` support is removed in 0.57. Not addressed;
  the whole config set will need porting before that release.

`hyprctl configerrors` lists parse failures in a running session and is the
fastest way to catch these.

## The VM is a design surface, not a performance target

`is_vm` no longer changes anything cosmetic. `hyprland.conf` renders
byte-identical on Hyper-V and on bare metal — blur, shadows, rounding, and
animations are all on. The point of the VM is tuning how things look, which
is impossible if the VM turns the looks off.

`is_vm` still gates the things that are functional:

- **Software GL** (`WLR_RENDERER_ALLOW_SOFTWARE`, `LIBGL_ALWAYS_SOFTWARE` in
  `conf.d/env.conf`). Hyper-V exposes no DRI device, so without these
  Hyprland refuses to start. This is not a slow-vs-fast setting.
- **sshd** (`roles/base`) — enabled on test VMs only.

`nyx_hypr_effects` is the separate escape hatch: set it false if llvmpipe
becomes too slow to work in. It is not inferred from anything.

## No guest tooling

`roles/virt_guest` was removed. The VM is a disposable design surface, not
something that needs integration services, clipboard sharing, or a guest
agent. `is_vm` now gates exactly three things:

- software GL in `conf.d/env.conf` (required for Hyprland to start)
- sshd in `roles/base`
- skipping `roles/gpu` and `roles/backup_rclone`

`nyx_profile.virt` is still detected and reported. Nothing consumes it.

## Filesystem

p3 is btrfs with CachyOS's Calamares subvolume layout — `@`, `@home`,
`@root`, `@srv`, `@cache`, `@tmp`, `@log` — mounted `noatime,compress=zstd:3`.
Matching upstream means snapshot tooling written for CachyOS applies here
unchanged, and the test VM and a shipped install have the same shape.

`@cache`, `@tmp`, and `@log` are separate subvolumes so a root snapshot does
not drag package caches and journals along with it.

Two consequences already handled:

- The kernel cmdline needs `rootflags=subvol=@`. Without it the top-level
  subvolume is mounted, there is no `/sbin/init` there, and the boot fails
  in a way that looks like a missing root.
- `shred` is meaningless on COW; the password-hash file is removed instead.

p1 is FAT32 (ESP) and p2 stays ext4 — a rescue volume is worth keeping dull.

Unverified: whether a single-device btrfs root needs anything in
`mkinitcpio.conf`. The `filesystems` hook should pull the module in via
autodetect, and the `btrfs` hook is for multi-device arrays, but this has
not been booted yet.

## Stale superblocks survive sgdisk -Z

Found on the first btrfs install. `mkfs.btrfs` reported success — label,
UUID, profiles all normal — and the very next `mount /dev/sda3 /mnt` failed
with "cannot mount; probably corrupted filesystem".

The filesystem was fine. `mount -t btrfs /dev/sda3 /mnt` worked immediately.
`sgdisk -Z` zaps the partition table but not the filesystem superblocks
inside the ranges it then re-creates, so on a re-install the previous ext4
super was still sitting at its old offset. An untyped `mount` probes with
libblkid, found the stale ext4 signature first, and tried to mount the new
btrfs as ext4.

Only reproduces on a re-install, which is exactly the path the dev loop
takes. Two fixes, both applied: `wipefs -a` on each partition after
partprobe and before mkfs, and an explicit `-t` on every mount in the
script. Never let mount guess on a disk this script has already written.

## Mount state around install.sh

Same class of problem, handled in three places.

Before anything is prompted for, the script refuses outright if any
partition of `$DISK` is mounted at `/`, `/run/archiso/*`, or
`/run/initramfs/*` — that is the running system or the live medium, and the
only way to reach it is a wrong `NYX_DISK`. The check is read-only and
unmounts nothing.

After the ERASE confirmation and before the first write, it releases the
device: unmounts any existing `/mnt` tree, unmounts everything else backed
by `$DISK`, and swapoffs any swap on it. A mounted partition cannot be
repartitioned cleanly — mkfs refuses, or partprobe declines to re-read the
table and the kernel keeps the old geometry — and both failures surface much
later looking unrelated.

At the end it unmounts `/mnt` itself rather than telling the caller to. The
tree is seven subvolumes deep, and leaving it mounted is what the next run
trips over. If the unmount fails it reports `fuser -vm /mnt` and says the
install completed anyway.

Sources are matched by prefix against `findmnt -rno TARGET,SOURCE`, which
prints btrfs sources as `/dev/sda3[/@home]` — the prefix test handles that,
an equality test would not.

## NVIDIA requirements

From the Hyprland docs, implemented in `roles/gpu`:

- **Userspace**: `nvidia-open-dkms`, `nvidia-utils`, `lib32-nvidia-utils`,
  `egl-wayland`, `libva-nvidia-driver`, in `nyx_nvidia_packages`. chwd still
  runs and still owns driver selection for everything else, but it does not
  guarantee this set. `libva-nvidia-driver` is what makes the
  `LIBVA_DRIVER_NAME=nvidia` already set in `conf.d/env.conf` resolve to
  anything; without it VA-API decode silently falls back to software.
  `lib32-*` needs `[multilib]`; the role asserts it rather than enabling it,
  matching how `roles/base` treats the CachyOS sections.
- **`/etc/modprobe.d/nvidia.conf`** — `options nvidia_drm modeset=1`.
- **Early KMS** — `nvidia nvidia_modeset nvidia_uvm nvidia_drm` in
  mkinitcpio's `MODULES`.

`i915` is prepended when the profile also lists an Intel GPU: on hybrid
systems, loading the NVIDIA modules first makes Electron and Chromium apps
stall for up to a minute after boot. `profiles/nvidia-intel-desktop-v4.json`
exists to exercise that branch.

Early KMS can break resume from hibernation — the machine boots instead of
resuming. Drop the modules if that appears.

Verify after a reboot:

    cat /sys/module/nvidia_drm/parameters/modeset    # expect Y

The role reports this rather than asserting it, because the value is not
readable until the machine has booted with the new initramfs.

**`/etc/kernel/cmdline` is currently inert.** `roles/gpu` writes
`nvidia_drm.modeset=1` there, but nothing reads it: `install.sh` writes
`refind_linux.conf` directly, and the UKI that would consume a preset
cmdline is Phase 10. The modprobe.d file is what actually takes effect
today. Left in place because Phase 10 needs it, but do not count it as the
mechanism.

## Forcing Chromium and Electron onto Wayland

Three mechanisms, because none of them covers everything.

- `ELECTRON_OZONE_PLATFORM_HINT=auto` in `conf.d/env.conf`. Covers Electron
  28 and newer. Chromium itself ignores it.
- `~/.config/<name>-flags.conf`, rendered from `nyx_hypr_ozone_flags` for
  every entry in `nyx_hypr_flag_files`. Arch's launcher wrappers read these
  and append each line to the command. Only `electron` is listed today; add
  `chromium`, `brave`, or `code` when the matching package lands, since the
  file does nothing without the wrapper that reads it. VSCode is known not
  to honour its file.
- App-specific config where the launcher has its own format —
  `spotify-launcher.conf` is TOML with an `extra_arguments` array, not a
  flags file, because Spotify is CEF rather than Electron and comes through
  its own wrapper.

An unused flags file is harmless, unlike `nyx_hypr_wallpaper`: nothing reads
it until the corresponding wrapper exists.
