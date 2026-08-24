# Notes

What has been verified against real hardware, what is still assumed, and the
traps that cost a debugging session. Rewritten after the switch to
illogical-impulse; anything about the old NyxOS palette and hand-written
Hyprland config is gone with it.

## Verified by running

On Hyper-V (Gen 2, `linux-cachyos`, Zen 5 host) unless stated otherwise.

- `roles/detect` runs clean and is safe standalone.
- `ansible_virtualization_type` returns `VirtualPC`; `march` returns
  `x86-64-v4`; `has_tpm` true with the vTPM enabled; `secureboot` false via
  soft-failed sbctl. `profiles/hyperv.json` matches.
- `-e @profiles/...` reports OVERRIDE and skips detection.
- CachyOS repo sections on a Zen 5 install are `cachyos-znver4`,
  `cachyos-core-znver4`, `cachyos-extra-znver4`, plus generic `cachyos`. All
  four Include `cachyos-v4-mirrorlist` or `cachyos-mirrorlist`. Names are
  Zen-generation-specific and do not derive from the x86-64-vN level, so
  `roles/base` reads them instead of generating them. **v3 naming on Intel
  hardware is unconfirmed.**
- `roles/base`: repo assert reads all four sections, `7zip` resolves, yay
  bootstraps, the temporary sudoers grant is revoked.
- A full install boots, reaches tuigreet, authenticates, and starts
  Hyprland. That was on the pre-ii config; the shell has been replaced
  since, so see "Not yet verified".

## Not yet verified

The switch to illogical-impulse is unrun. Everything in this section is
reasoning, not observation.

- **`./setup install` completing unattended.** Still unproven; the pty fix
  below is untested. See "The installer needs a pty".
- **`NOPASSWD: ALL` covering the installer.** It runs `sudo_init_keepalive`
  and touches permissions and services, not just pacman. If it reaches for
  something outside the grant it prompts, and that hangs too.
- **`hypr/custom/env.lua` actually being sourced.** ii's docs describe
  `custom/` as the override directory and name `env.lua`. If the path is
  wrong the file is inert, and under Hyper-V that means no software GL and
  no session.
- **`roles/gpu` on real hardware.** Untestable in Hyper-V — no PCI GPU. Use
  `-e @profiles/...` for the render path, but nothing there proves DKMS
  builds or that modeset takes.
- **btrfs root booting.** `rootflags=subvol=@` is written but has not been
  booted from. If the machine drops to an initramfs shell, that line in
  `refind_linux.conf` is the first suspect.
- **Whether single-device btrfs needs anything in `mkinitcpio.conf`.** The
  `filesystems` hook should pull the module in via autodetect and the
  `btrfs` hook is for multi-device arrays, but this is untested.

## Check against upstream before relying on it

- **CachyOS signing key ID** for the archiso build host. Take it from the
  official install documentation.
- **`sbctl status --json` field names.** `roles/detect` reads `secure_boot`
  and nothing else. `setup_mode` and `installed` are unread; Phase 10 needs
  `setup_mode`, so confirm all three. The failure path is verified: with
  sbctl absent the task fails soft and `secureboot` falls back to `false`.
- **Hyper-V framebuffer module** — `hyperv_drm` on current kernels,
  `hyperv_fb` on older. The `video=` cmdline param differs.
- **nvidia-open vs proprietary cutoff.** Turing and newer for the open
  modules; recent branches dropped Maxwell/Pascal/Volta entirely.
  `nyx_nvidia_packages` names `nvidia-open-dkms` outright, so a pre-Turing
  card needs that list overridden — chwd would pick a legacy branch and
  pacman will not hold both.
- **Intel media driver split.** `intel-media-driver` for Gen8+,
  `libva-intel-driver` below. `i915` vs `xe` on the newest parts.

## illogical-impulse

ii owns the shell: Quickshell bar, notifications, launcher, OSD, session
menu, the Hyprland config set, and the fish config with its starship prompt.
It themes with matugen, deriving the scheme from the wallpaper at runtime.
`roles/theme`, `nyx_palette` and `nyx_roles` were deleted for that reason —
matugen and a fixed palette cannot both own colour.

**The config format is Lua.** `hyprland.lua` loads internal libraries, then
ii's environment and defaults, then `custom/`. NyxOS environment goes in
`custom/env.lua` as `hl.env()` calls. A hyprlang `.conf` file in `custom/`
is silently never read — that cost a commit, and the file that failed to
load was the one carrying the VM software-GL block.

### The installer needs a pty

The first real run sat for the full 90-minute timeout and then failed. The
log was a loop of:

    sudo: a terminal is required to read the password; either use the -S
    option to read from standard input or configure an askpass helper
    sudo: a password is required
     -> exit status 1

It was never compiling. `sudo_init_keepalive` could not authenticate, the
script retried, and it spun until `async` cut it off. A working install takes
a couple of minutes on a fast link, so `nyx_ii_setup_timeout` is a spin
detector rather than a build budget.

Two separate things were wrong. With no controlling terminal sudo cannot
prompt even when it decides it must — handled by running under `script
-qec`, which allocates a pty, with stdin still `/dev/null` so a prompt that
does appear reads EOF instead of waiting on a pty nobody is typing into.

And sudo wanted a password at all, despite the grant. That recurred once the
pty was in place: the installer reached `install-local-pkgbuild`, whose
`makepkg` shells out to `sudo pacman -U`, and got `[sudo] password for
<user>`. The grant was present and had passed `visudo -cf`.

The rule was being overridden rather than missed. Two changes, either of
which is sufficient:

- `Defaults:<user> !authenticate` alongside the `NOPASSWD: ALL` line. A
  per-user default is not subject to the last-matching-Cmnd_Spec-wins
  resolution that lets a `%wheel ... ALL` rule elsewhere beat a NOPASSWD
  line in `sudoers.d`.
- the file is `zz-nyx-ii-temp`, not `99-nyx-ii-temp`, so it sorts after
  everything. Digits sort before letters, so `99-` loses to any
  letter-prefixed file. Names containing a dot or ending in `~` are ignored
  by sudo entirely.

A `sudo -n true` check runs as the user immediately after the grant is
written, so a grant that does not apply fails there with a clear reason
instead of at an invisible password prompt forty minutes into the installer.

What overrode it is still unconfirmed. `sudo -l -U <user>` while the grant
is in place, and the tail of `/etc/sudoers`, would settle it — a `%wheel`
rule parsed after `@includedir` would explain it exactly.

Diagnosing a stuck run: output is appended to `nyx_ii_setup_log`, which is
in **`nyx_user`'s** home, not root's — the play runs as root but this task
becomes the user. `ps -eo pid,stat,etime,args | grep -E
'setup|pacman|makepkg|cc1plus'` distinguishes a real build from a spin.

### pacman's own prompts are out of reach

With the pty in place the installer got as far as `sudo pacman -Syu` and
stopped at:

    :: Replace zlib with cachyos/zlib-ng-compat? [Y/n]

No `setup` flag reaches that — it is pacman asking, not the script. A
replacement prompt on a pty with nobody typing is a stall.

So Ansible does the upgrade instead: `--skip-sysupdate` on the installer,
and a `community.general.pacman` task with `upgrade: true` ahead of it. The
module passes `--noconfirm`, which answers replacement questions rather than
asking them.

The upgrade is not skipped, only moved. ii installs packages built against
current libraries and Arch has no supported partial-upgrade state.

That task runs **first** in the role, before the greetd and app packages, so
those land on an already-upgraded system. `IgnoreGroup` is set before it, so
a re-run does not pull ii's own packages out from under the installer.

`roles/base` still installs `nyx_packages_base` without a preceding full
upgrade, which is the same partial-upgrade exposure one role earlier. Not
addressed.

**`./setup install` prompts by default**, which under Ansible is a hang, not
a failure. `-f` is the unattended path. Flags from
`sdata/subcmd-install/options.sh`: `--core` (skips fish, fontconfig,
plasma-browser-integration), `--skip-backup`, `--skip-quickshell`,
`--skip-hyprland`, `--skip-hyprland-entry`, `-s/--skip-sysupdate`,
`-c/--clean`, `-F/--firstrun`, `--fontset <set>`.

Current flags are `-f --skip-backup`. `-s` is deliberately unused: ii
installs packages built against current libraries and Arch has no supported
partial-upgrade state, so skipping the upgrade trades a slow run for a
broken one.

Upstream post-install steps, all handled in the role:

- conflicting notification daemons removed. Only one process can own
  `org.freedesktop.Notifications`; the loser silently shows nothing.
- `IgnoreGroup = illogical-impulse` in `pacman.conf`. Upstream calls editing
  it automatically risky, but `roles/base` already manages `NoUpgrade`
  there.

**Do not select UWSM** at a greeter. ii says so explicitly: it does not break
the dotfiles but pulls in autostarted junk from other desktop environments,
such as duplicate authentication dialogs. tuigreet runs `--cmd
start-hyprland`, which bypasses session selection, so this only matters if
the greeter changes.

Updating is manual upstream — `git stash`, `git pull`, `./setup install`.
The role re-runs the installer every play against `nyx_ii_version`, which
tracks `main`. Pin it to a tag or commit once the desktop is one worth
keeping.

### Testing this

The desktop is being brought up by reinstalling from the live ISO each time,
not by re-running the playbook on a machine. So the loop is: download
`install.sh` fresh, run it, and it clones the repo itself. There is no
`git pull` step, and no state carried between attempts — which also means
every attempt starts from a stock pacstrap, with no leftover `sudoers.d`
files or half-applied config from the previous one.

That is worth knowing when reading a failure: anything blamed on "a re-run"
or "leftover state" does not apply here.

NyxOS tweaks go in `files/ii-overlay/`, copied after ii so they win, mirroring
the `~/.config` tree shape.

## Traps found the hard way

**`arch-chroot` shares the host's `/proc`.** It bind-mounts rather than
making a namespace, so anything reading `/proc/cmdline` or the UTS hostname
inside it sees the **live ISO**. `refind-install` runs `mkrlconf`, which
builds `refind_linux.conf` from `/proc/cmdline` — producing entries with
`archisobasedir=...` and no `root=`, and a machine that drops to an
emergency shell on first boot. `install.sh` now writes that file itself
after the chroot block, from `blkid` on the real root partition.
`roles/detect` reads `/etc/hostname` for the same reason. `lspci` and DMI
are fine — they describe hardware, which is shared.

**Stale superblocks survive `sgdisk -Z`.** It zaps the partition table, not
the filesystem superblocks inside the ranges it re-creates. On a re-install
the previous ext4 super sat at its old offset, `mkfs.btrfs` reported success,
and the next `mount /dev/sda3 /mnt` failed with "probably corrupted
filesystem" — libblkid probed the stale signature first. `mount -t btrfs`
worked immediately. Fixed with `wipefs -a` per partition after `partprobe`,
plus an explicit `-t` on every mount. Only reproduces on a re-install, which
is exactly what the dev loop does.

**Microarch detection must come from `/proc/cpuinfo` flags**, not
`/lib/ld-linux-x86-64.so.2`. That path only exists where `/lib` symlinks to
`/usr/lib`, and the task failed soft — reporting v1 on a v4 machine. Getting
it wrong selects the wrong CachyOS repo tier, which means SIGILL in
arbitrary binaries rather than a clean error.

**`curl | bash` makes stdin the script**, so `read` consumes script text
instead of keystrokes. All three prompts in `install.sh` read from
`/dev/tty`, and it exits with instructions when there is no controlling
terminal. Documented usage is download-then-run anyway, which also lets the
script be read before it formats a disk.

**Idempotency traps, found on the second `base` run.**
`ansible.builtin.command` cannot run shell builtins — `command -v` there
returns rc!=0 forever and silently re-runs whatever it guards.
`vars_prompt` with `encrypt:` re-salts every run, so `user:` reports changed
unless `update_password: on_create` is set. Create/revoke pairs, such as the
temporary sudoers grant, always report changed unless gated on whether the
work between them is needed.

**`start-hyprland` is owned by the `hyprland` package**, not by anything
else. It was briefly assumed to come from a removed AUR package and both
launch paths were switched to the bare `Hyprland` binary, which warns about
not being started through a session manager. `pacman -Qo` on a real install
disproved that. Set in `files/hyprland.desktop` and the tuigreet `--cmd`.

## Filesystem

p3 is btrfs with CachyOS's Calamares subvolume layout — `@`, `@home`,
`@root`, `@srv`, `@cache`, `@tmp`, `@log` — mounted
`noatime,compress=zstd:3`. Matching upstream means snapshot tooling written
for CachyOS applies unchanged, and the test VM and a shipped install have
the same shape. `@cache`, `@tmp` and `@log` are separate so a root snapshot
does not drag package caches and journals along.

The kernel cmdline needs `rootflags=subvol=@`. Without it the top-level
subvolume is mounted, there is no `/sbin/init` there, and the failure looks
like a missing root.

`shred` is meaningless on copy-on-write — the overwrite lands in new extents
and the original blocks stay until reclaimed — so the password-hash file is
removed rather than shredded. It holds a hash, not a password, so this is a
weaker claim rather than weaker exposure.

p1 is FAT32 (ESP) and p2 stays ext4; a rescue volume is worth keeping dull.
No LUKS yet — p3 is bare btrfs until Phase 10.

## Mount state around install.sh

Before anything is prompted for, the script refuses if a partition of
`$DISK` is mounted at `/`, `/run/archiso/*` or `/run/initramfs/*` — the
running system or the live medium, reachable only via a wrong `NYX_DISK`.
Read-only; it unmounts nothing.

After the ERASE confirmation and before the first write it releases the
device: unmounts any existing `/mnt` tree, unmounts everything else backed by
`$DISK`, and swapoffs any swap on it. A mounted partition cannot be
repartitioned cleanly — mkfs refuses, or partprobe declines to re-read the
table and the kernel keeps the old geometry — and both surface much later
looking unrelated.

At the end it unmounts `/mnt` itself. The tree is seven subvolumes deep and
leaving it mounted is what the next run trips over.

Sources are matched by prefix against `findmnt -rno TARGET,SOURCE`, which
prints btrfs sources as `/dev/sda3[/@home]`. An equality test would miss
every subvolume mount.

## Password handling

`install.sh` prompts before partitioning, hashes with `openssl passwd -6`
immediately, and writes the hash to `/root/.nyx-vars.yml` (0600) in the
target. The playbook is invoked with `-e @/root/.nyx-vars.yml`, which makes
Ansible skip its own `vars_prompt` — verified. The file is removed after.

Plaintext never leaves the installer's shell, and the hash is passed by file
rather than on a command line where `ps` would expose it. The playbook's
`vars_prompt` remains the fallback for running `ansible-playbook` by hand.
`roles/base` uses `update_password: on_create`, so re-running does not reset
an existing password.

## NVIDIA

From the Hyprland docs, implemented in `roles/gpu`:

- **Userspace**: `nvidia-open-dkms`, `nvidia-utils`, `lib32-nvidia-utils`,
  `egl-wayland`, `libva-nvidia-driver`, in `nyx_nvidia_packages`. chwd still
  owns driver selection but does not guarantee this set.
  `libva-nvidia-driver` is what makes the `LIBVA_DRIVER_NAME=nvidia` set in
  `hypr/custom/env.lua` resolve to anything; without it VA-API decode
  silently falls back to software. `lib32-*` needs `[multilib]`, which the
  role asserts rather than enables.
- **`/etc/modprobe.d/nvidia.conf`** — `options nvidia_drm modeset=1`.
- **Early KMS** — the four nvidia modules in mkinitcpio's `MODULES`.

`i915` is prepended when the profile also lists an Intel GPU: on hybrid
systems, loading the NVIDIA modules first makes Electron and Chromium apps
stall for up to a minute after boot. `profiles/nvidia-intel-desktop-v4.json`
exercises that branch.

Early KMS can break resume from hibernation — the machine boots instead of
resuming. Drop the modules if that appears.

Verify after a reboot: `cat /sys/module/nvidia_drm/parameters/modeset`
should read `Y`. The role reports rather than asserts, since it is
unreadable until the machine has booted with the new initramfs.

**`/etc/kernel/cmdline` is inert.** `roles/gpu` writes
`nvidia_drm.modeset=1` there, but nothing reads it: `install.sh` writes
`refind_linux.conf` directly, and the UKI that would consume a preset
cmdline is Phase 10. The modprobe.d file is what takes effect. Left in place
because Phase 10 needs it; do not count it as the mechanism.

Suspend and hibernate services (`nvidia-suspend`, `nvidia-hibernate`,
`nvidia-resume`) and `NVreg_PreserveVideoMemoryAllocations=1` are handled by
Arch's packaging per the Hyprland docs, so the role does not set them.
**Unconfirmed**, along with whether a package already owns
`/etc/modprobe.d/nvidia.conf` — if one does, this role is clobbering it and
should write `nyxos-nvidia.conf` instead. Check with
`pacman -Qo /etc/modprobe.d/nvidia.conf`.

## Forcing Chromium and Electron onto Wayland

Three mechanisms, because none covers everything.

- `ELECTRON_OZONE_PLATFORM_HINT=auto` in `hypr/custom/env.lua`. Covers
  Electron 28 and newer. Chromium itself ignores it.
- `~/.config/<name>-flags.conf`, rendered from `nyx_hypr_ozone_flags` for
  every entry in `nyx_hypr_flag_files`. Arch's launcher wrappers read these.
  Only `electron` is listed; add `chromium` or `brave` when the package
  lands, since the file does nothing without the wrapper that reads it.
  VSCode is known not to honour its file.
- App-specific config where the launcher has its own format.
  `spotify-launcher.conf` is TOML with an `extra_arguments` array, because
  Spotify is CEF rather than Electron and comes through its own wrapper.

An unused flags file is harmless — nothing reads it until the wrapper exists.

## The VM is a design surface

`is_vm` gates functional things only:

- **Software GL** (`WLR_RENDERER_ALLOW_SOFTWARE`, `LIBGL_ALWAYS_SOFTWARE` in
  `hypr/custom/env.lua`). Hyper-V exposes no DRI device, so without these
  Hyprland refuses to start. Not a slow-vs-fast setting.
- **sshd** in `roles/base`, on test VMs only.
- **skipping `roles/gpu` and `roles/backup_rclone`** in `site.yml`.
- **the greetd restart handler**, which is skipped on VMs.

It changes nothing cosmetic. Effects have to render in the VM or they cannot
be tuned there. `nyx_hypr_effects` was the manual escape hatch and is gone
with the hand-written Hyprland config; ii owns those settings now.

`roles/virt_guest` was removed — no integration services, clipboard sharing,
or guest agent. `nyx_profile.virt` is still detected and reported. Nothing
consumes it.

## Scope

Laptop support was removed entirely — no `is_laptop` fact, no `laptop` role,
no battery, backlight or lid handling. VMs and desktops only.

Branching that remains:

- **CPU vendor** (`cpu`): detected, consumed by nothing. Intended for
  `intel-ucode`/`amd-ucode` and pstate; neither is implemented.
- **GPU vendor** (`gpus`): chwd picks the driver; `roles/gpu` adds NVIDIA
  early KMS, modprobe.d and cmdline; `env.lua` sets VA-API/VDPAU per vendor.
- **VM** (`is_vm`): as above.

Override profiles: `hyperv`, `intel-desktop-v3`, `amd-desktop-v4`,
`nvidia-desktop-v4`, `nvidia-intel-desktop-v4`.

## Open questions

- Two user accounts exist on the old VM: `adam` (CachyOS installer) and
  `abnac` (`roles/base` from `nyx_user`). Pick one. `run.ps1` defaults to
  `abnac@nyxos-test`, which only works if the checkpoint was made after that
  account existed. A fresh `install.sh` install creates only `abnac`.
- `/etc/sudoers.d/10-installer` was left by the CachyOS installer. Check its
  contents; if it grants passwordless sudo, `roles/base` should remove it.
- Ansible warns that `/home/<user>/.ansible/tmp` was created 0700. Benign
  when become_user owns it; breaks if the playbook runs as root against a
  different `nyx_user`.
- `nyx_hypr_wallpaper` is empty, so matugen has nothing to derive a scheme
  from and ii keeps its built-in colours.
- `render-check.py` covers four templates now that ii owns the config. The
  waybar-JSON and duplicate-keybind checks were deleted with their inputs; a
  cheap Lua screen replaced them.

## Known gaps

- `branding` and `backup_rclone` are stubs that print the profile and exit 0.
- `nyx_backup_paths` is a guess; set it to real directories.
- Root is deliberately locked, matching Ubuntu and Fedora. That makes
  systemd's emergency shell unusable ("Cannot open access to console, the
  root account is locked"), so recovery depends on the recovery partition or
  external media. Worth populating that partition earlier than Phase 10.

## Firefox policy

`/etc/firefox/policies/policies.json`, rendered from `nyx_firefox_policies`.

Reference is **https://firefox-admin-docs.mozilla.org/reference/policies/**.
The old `mozilla/policy-templates` README now only points there, and its
rendered site is behind the current docs — check names against the admin
docs, not against a search result.

It is a YAML dict rendered through `to_nice_json` rather than a static JSON
file, so the reasoning for each setting can live in comments. `to_nice_json`
is an Ansible filter, not core Jinja2, so `render-check.py` registers it —
along with a JSON-validity check on any `.json.j2` output.

Applied system-wide and before first launch, so a fresh install never shows
sponsored shortcuts or the onboarding tour and none of it needs re-clicking
after a reinstall. Root-owned, since it overrides user settings.

`Locked: true` is deliberately not used anywhere. It greys the setting out in
the UI, which is right for a managed fleet and wrong for one machine — a
locked policy that turns out to be wrong is just an obstacle.

Mozilla removed "we never sell your data" from the Firefox FAQ in February
2025, alongside introducing a Terms of Use with a broad content licence. The
licence was narrowed after backlash and the FAQ now reads "Mozilla doesn't
sell data about you". The stated reason for dropping the absolute claim is
real — CCPA defines "sale" as disclosure for any valuable consideration, and
sponsored shortcuts arguably qualify — but it landed while Mozilla was
building an ad business, having acquired Anonym in mid-2024 and shipped
Privacy-Preserving Attribution enabled by default in Firefox 128.

This policy file turns off the surfaces that made the claim awkward. It is
the reason Firefox is preferable to a hardened fork here: the hardening is
version-controlled and reproducible, while the browser still gets Mozilla's
security patches first rather than after a fork rebases.

### Corrections found by reading the real reference

The `mozilla/policy-templates` README and its rendered site are both behind
the admin docs. Reading the wrong one produced two wrong claims in this repo,
both since fixed:

- `DisableFeedbackCommands` was used as crash reporting. It is the "report
  broken site" menus. `CrashReportsSubmit: false` is crash reporting.
- The `Preferences` policy was said to reject `browser.*` and `dom.*`. It
  does not — both are allowed prefixes. `privacy.*` is the one that is not
  blanket-allowed: only `baselineFingerprintingProtection`,
  `fingerprintingProtection`, `globalprivacycontrol.enabled`,
  `userContext.enabled` and `userContext.ui.enabled` are permitted.

So Privacy-Preserving Attribution *is* settable, via
`dom.private-attribution.submission.enabled`, and is set here.

`about:policies` after first launch shows which policies applied and which
were rejected. Worth checking rather than assuming — a misspelled key or a
bad extension URL is ignored, not reported.

### DNS is deliberately untouched

`DNSOverHTTPS` is not set, so DNS keeps going to the Pi-hole.

**That is not the same as DoH being off.** Firefox enables DoH by itself in
some regions, and when it does, queries bypass the Pi-hole entirely — no
blocking, no local records, nothing in its query log. Firefox's heuristics
are supposed to detect a local resolver and back off, but they are
heuristics.

If the Pi-hole ever looks like it has stopped seeing Firefox traffic, check
`about:networking#dns` before suspecting the Pi-hole. Pinning it off is
`DNSOverHTTPS: {Enabled: false}`, deliberately not set here.

### Unverified in this policy set

- **The Wayback Machine extension URL.** AMO "latest" URLs resolve by slug;
  uBlock Origin's is stable, the Internet Archive one is a guess. A bad URL
  fails silently.
- **`SearchEngines.Remove` names.** They match the engine's display name,
  which is locale-dependent. If an engine survives, check
  `about:preferences#search` for its exact name.
- **`VisualSearchEnabled: true` alongside `GenerativeAI: false`.** Both are
  set as asked, but visual search may depend on the AI features the other
  policy disables. If it does not appear, that pairing is the first suspect.
