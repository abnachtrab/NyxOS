# Things to verify before trusting them

Written from memory during design. Verify each against upstream before
relying on it.

- **CachyOS signing key ID** for the archiso build host. Take it from the official install
  documentation.
- **`sbctl status --json` field names** — `setup_mode`, `secure_boot`,
  `installed` are what `roles/detect` reads. Confirm on the installed version.
  The failure path is verified: with sbctl absent the task fails soft and
  `secureboot` falls back to `false`.
- **Hyper-V framebuffer module** — `hyperv_drm` on current kernels,
  `hyperv_fb` on older. The `video=` cmdline param differs.
- **nvidia-open vs proprietary cutoff.** Turing and newer for open modules;
  recent driver branches dropped Maxwell/Pascal/Volta entirely.
- **Intel media driver split.** `intel-media-driver` for Gen8+,
  `libva-intel-driver` below. `i915` vs `xe` on the newest parts.

## Verified on Hyper-V (Gen 2, linux-cachyos, Zen 5 host)

- CachyOS repo sections on a Zen 5 install are `cachyos-znver4`,
  `cachyos-core-znver4`, `cachyos-extra-znver4`, plus generic `cachyos`.
  All four Include `/etc/pacman.d/cachyos-v4-mirrorlist` or
  `cachyos-mirrorlist`. Section names are Zen-generation-specific and do not
  derive from the x86-64-vN level, so `roles/base` reads them instead of
  generating them. The v3 naming on Intel hardware is still unconfirmed;
  check on the Surface.
- `ansible_virtualization_type` returns `VirtualPC`. Other keys pruned.
- `ansible_form_factor` returns `Desktop`, so `is_laptop` string matching
  works and should behave on the Surface.
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
  still SSHes as whichever the checkpoint was made with.
- `/etc/sudoers.d/10-installer` was left by the CachyOS installer. Check its
  contents; if it grants passwordless sudo, `roles/base` should remove it.
- Ansible warns that `/home/<user>/.ansible/tmp` was created 0700. Benign
  when become_user owns it; breaks if the playbook runs as root against a
  different `nyx_user`.

## Theme

Palette and semantic role map live in `roles/theme/defaults/main.yml`.
Applications consume role names (primary, success, panel) rather than colour
names, so reassigning a role is one line.

Adding an application: write a template in `roles/theme/templates/`, add a
line to `nyx_theme_targets`. Do not put hex values anywhere else.

Primary is haze `#C7B8E8` (pastel purple), secondary is mist `#B4CDE6`
(pastel purple).

Still unthemed: SDDM/greeter, GTK, Qt (Kvantum), rEFInd, Plymouth, bat, fzf,
zsh syntax highlighting, btop.

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

## Known gaps

- No LUKS in `install.sh` yet — p3 is plain ext4 until Phase 10.
- `nyx_backup_paths` is a guess; set it to real directories.
- `session_hyprland`, `gpu_*`, `laptop`, `branding`, `backup_rclone` are
  stubs that print the profile and exit 0.
