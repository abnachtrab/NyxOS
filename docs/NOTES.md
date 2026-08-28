# Notes

What has been verified by running it, what is still assumed, and the traps
that cost a debugging session. The illogical-impulse switch has been through
a full install, boot and login; the sections below say which parts that
actually covered.

## Verified by running

On Hyper-V (Gen 2, `linux-cachyos`, Zen 5 host) unless stated otherwise.
A full install from the live ISO, boot, login and desktop have all been done
on the current configuration.

**Install and boot**

- `install.sh` partitions, pacstraps, chroots and provisions unattended.
- btrfs root boots. `rootflags=subvol=@` in `refind_linux.conf` is correct,
  and a single-device btrfs root needs nothing added to `mkinitcpio.conf` —
  the `filesystems` hook covers it via autodetect.
- The temporary `NOPASSWD` grant is revoked on the target: after a completed
  install `/etc/sudoers.d/` holds only `10-wheel`.

**detect and base**

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

**Session**

- greetd reaches tuigreet, authenticates, and starts Hyprland.
- `./setup install` completes unattended — with `-f`, `--skip-allgreeting`,
  `--skip-sysupdate`, a pty from `script -qec`, stdin from `/dev/null`, and
  the `zz-` sudoers grant. Every one of those was needed; see below.
- end4-pC clones to `~/.config/quickshell/end4-pC`, the `qsConfig` lineinfile
  takes, and `pgrep -a qs` shows `qs -c end4-pC` after login.

**Firefox**

- All five extensions install from policy: uBlock Origin, Wayback Machine,
  Multi-Account Containers, Enhancer for YouTube, Dashlane.
- The policy file applies. `about:policies#errors` had exactly one entry,
  `CrashReportsSubmit`, since removed.
- Reapplying with `--tags firefox` and restarting the browser moves every
  value except ones changed by hand.

## Not yet verified

- **`hypr/custom/env.lua` actually being sourced.** ii's docs name `custom/`
  as the override directory and `env.lua` as the file, and the session does
  start under Hyper-V — but nothing has confirmed the file is what supplies
  software GL rather than ii doing it some other way. `hyprctl getenv | grep
  LIBGL_ALWAYS_SOFTWARE` settles it. Matters because the same file carries
  the GPU vendor branching that real hardware will depend on.
- **`roles/gpu` on real hardware.** Untestable in Hyper-V — no PCI GPU.
  `-e @profiles/...` exercises the render path, but nothing there proves DKMS
  builds or that modeset takes.
- **Whether a package owns `/etc/modprobe.d/nvidia.conf`.** If one does, the
  gpu role is clobbering packaged config and should write
  `nyxos-nvidia.conf` instead. `pacman -Qo` settles it.
- **What overrode the sudoers grant.** `99-nyx-ii-temp` lost to something
  with `NOPASSWD: ALL` in place and `visudo -cf` passing. Renaming to `zz-`
  and adding `Defaults:<user> !authenticate` fixed it, but the cause is
  still unknown — `sudo -l -U <user>` while the grant exists would say.

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

### Every value verified against firefox-admin-docs

Checked one page at a time rather than from recall. Structural errors found
and fixed:

- **CrashReportsSubmit is an object**, not a boolean. It takes an Enabled
  key.
- **GenerativeAI is an object** with Enabled / Chatbot / LinkPreviews /
  TabGroups / SmartWindow. It was set to a bare false.
- **AIChatbot is not an on/off switch.** It configures chatbot providers and
  prompts. GenerativeAI.Chatbot is what disables the feature, so AIChatbot
  is not set at all.
- **DefaultSerialGuardSetting has no ask value.** 2 blocks, 3 allows. Any
  policy at all blocks WebSerial by default, so 3 must be stated explicitly.
- **PopupBlocking.Default true means popups are ALLOWED.** Blocking is
  false.
- **Cookies: partition-foreign** is the Firefox 153 name.
  reject-tracker-and-partition-foreign is deprecated — renamed, same
  behaviour.
- **FirefoxHome.Snippets** was deprecated in 122 and is not set.
  Stories/SponsoredStories replaced Pocket/SponsoredPocket in 141; both
  pairs are set so the file works either side of that. Weather is new in 152
  and fetches by location.
- **UserMessaging.WhatsNew** is deprecated and not set.
- **SearchEngines** works on release Firefox since 139; it is not ESR-only.
- Both extension slugs confirmed on addons.mozilla.org.
- **VisualSearchEnabled is independent of GenerativeAI**, so the two
  settings do not conflict. It only works while Google is the default
  engine, which it is.

Earlier claims in this file that were wrong and are now corrected: the
Preferences policy does allow browser.* and dom.* prefixes, so PPA is
settable; privacy.* is the restricted one, with five individually permitted
prefs. And DisableFeedbackCommands is the report-broken-site menus, not
crash reporting.

Five extensions are installed by policy, every slug confirmed on AMO:
uBlock Origin, Wayback Machine, Multi-Account Containers, Enhancer for
YouTube, Dashlane.

The built-in **Containers policy is not set** — Multi-Account Containers
manages them instead. The two are complementary rather than alternatives:
the extension is a management UI over the same contextual identities the
policy would pre-create, so restoring the policy would seed named containers
with set icons and colours rather than taking the extension defaults.
`privacy.userContext.enabled` and `privacy.userContext.ui.enabled` are set so
the underlying feature is on either way.

`DisableRemoteImprovements` is deliberately **false**. The channel that
delivers remote config also delivers stability and performance fixes between
releases, and losing those costs more than the callbacks are worth.

`SearchEngines.Remove` matches each engine's display name, which Mozilla does
not publish. It was read off `about:preferences#search` on a real install
rather than guessed: the set is Bing, DuckDuckGo, Perplexity and
Wikipedia (en). Amazon.com and eBay are no longer shipped; Perplexity is new.

A `Remove` entry that matches nothing is silently ignored — removing an
absent engine is a legitimate no-op, not a policy error — so
`about:policies` will not flag a stale name. That page cannot verify this
value; only the preferences page can.

about:policies after first launch shows what applied and what was rejected.
A misspelled key is ignored, not reported.

### DNS

DNSOverHTTPS is set to Enabled false, which sets network.trr.mode=5. That
turns DoH off *and* stops Firefox enabling it on its own, so DNS keeps
reaching the Pi-hole. Locked is omitted, so it can still be switched on by
hand later.

## end4-pC

A second Quickshell config, from pctrade/end4-pC, cloned into
`~/.config/quickshell/end4-pC`. It sits beside ii's own rather than
replacing it, and needs illogical-impulse installed and running, so the role
fetches it after the installer block.

Which one Hyprland launches is `hl.env("qsConfig", ...)` in
`hypr/hyprland/variables.lua`. Upstream documents editing that by hand, but
it is ii's file and `./setup install` rsyncs over it — so the edit is
reapplied by lineinfile after the installer on every play instead. It
self-heals rather than surviving.

`custom/env.lua` would be the tidier home for that variable, since custom/
loads last and would win. It is not used because qsConfig is read when the
shell launches and custom/ loads late; patching the file ii actually reads is
the version known to work. Worth revisiting if it turns out custom/ is early
enough.

The settings panel bind goes in `custom/general.lua` — one of the files ii
documents as loaded from custom/, unlike an arbitrary filename there. That
panel is an overlay rather than a window, so SUPER+Q does not close it; the
same bind toggles it and Escape dismisses it.

`nyx_qs_config` switches back to "ii" in one line, and
`nyx_end4pc_enabled: false` drops the clone and the bind together.

## SSH keys

`nyx_ssh_authorized_keys` is defaulted to an empty list in
`roles/base/defaults` and given its real value in `group_vars/all.yml`.

That split is deliberate. NyxOS is a public repo: a key hardcoded in a role
would be installed on the machine of anyone who ran this playbook, handing
its owner SSH access to a stranger box. group_vars is the layer a fork is
expected to replace, so the role stays safe by construction and a fresh ISO
install still gets the key with no manual step.

A public key in a public repo is otherwise fine — the private key cannot be
derived from it, and GitHub already publishes yours at
`github.com/<user>.keys`. Trim the trailing `user@host` comment if you
care about leaking a machine name; it is not load-bearing.

The task is not `exclusive`, so keys added by hand on a machine survive.
Set exclusive if the repo should be the only source of truth.

It runs after the user is created and before sshd is hardened. On a VM that
hardening sets `PasswordAuthentication no`, so a missing or wrong key here
means no SSH at all — and VMConnect cannot paste, it synthesises keystrokes
and mangles them.

## Shell settings

end4-pC writes its settings to ii path, `~/.config/illogical-impulse/config.json`,
not to one of its own — a fork inheriting a hardcoded path. So the two shells
share one settings file. Flipping `nyx_qs_config` back to "ii" means ii
reads whatever end4-pC last wrote, which is fine if the schemas match and
confusing if the fork added keys.

The file is committed as `templates/config.json.j2` rather than dropped in
the overlay, because it carries absolute paths under the home directory that
have to follow `nyx_user`. Two of them: the wallpaper, and the screen
recording save path. render-check validates the rendered JSON, which is worth
having for a 23KB file edited through a GUI rather than by hand.

**It is a seed, not a source of truth.** The shell rewrites it at runtime, so
the committed copy drifts the moment the settings panel is touched, and
nothing reports that. Re-copy it whenever the running state is worth keeping:

    scp <user>@<host>:/home/<user>/.config/illogical-impulse/config.json       roles/session_hyprland/templates/config.json.j2

then re-apply the two `nyx_user` substitutions.

Checked before committing, since the repo is public: no credentials. The
`ai.extraModels` entries carry endpoint and key-retrieval URLs plus a
`key_id`, but no key material. `workSafety.triggerCondition.fileKeywords`
is ii own NSFW filter list and reads oddly out of context — it is upstream
default content, not a personal setting.

## Wallpapers, matugen and live wallpapers

`scripts/colors/switchwall.sh` in end4-pC is the single entry point for every
wallpaper change. It lives under `colors/` because setting a wallpaper is also
what regenerates the matugen scheme — the two are one operation.

Flags: `--mode` dark/light, `--image`, `--start-dir`, `--type` (scheme
variant), `--color` (hex or clear), `--noswitch` (reprocess colours without
changing wallpaper), `--colors_lock`.

It writes the chosen path back into
`$XDG_CONFIG_HOME/illogical-impulse/config.json` with jq, setting
`.background.wallpaperPath`. That is the concrete reason the committed
`config.json.j2` is a seed rather than a source of truth: the shell rewrites
it on every wallpaper change.

The picker, when no image is given, is **kdialog** — part of why ii pulls the
KDE stack.

**Live wallpapers are an end4-pC feature.** `liveWallpapersPath` appears
nowhere under `ii/`. The QML side is thin: the desktop right-click menu has a
"Live Wallpaper" entry calling `Wallpapers.openFallbackPicker`, which execs
switchwall.sh with `--start-dir` set to that path. No file-type branching
happens in QML at all. The script does the real work — it detects mp4, webm,
mkv, avi and mov, plays them through **mpvpaper**, thumbnails via ffmpeg, and
writes `__restore_video_wallpaper.sh` so the wallpaper survives a restart.

`mpvpaper` is not in the Arch repos, but CachyOS ships `cachyos/mpvpaper`, so
it is a plain repo install and `nyx_packages_aur` stays empty. Nothing else
pulls it in: ii does not know about the feature, and end4-pC is a cloned
config directory rather than a package, so it declares no dependencies.

### How the wallpaper is deployed

`nyx_hypr_wallpaper` names a source image; it is copied into
`~/Pictures/Wallpapers`, the picker directory, and
`background.wallpaperPath` in the config template follows it. Empty leaves
ii's bundled default in place.

It used to copy to `~/.config/background`, which nothing reads — latent only
because the variable was empty, and silently useless the moment it was set.

Colours are deliberately not regenerated during provisioning. matugen runs
from switchwall.sh, which also sets the live wallpaper and so needs a running
compositor; provisioning has none. The scheme updates the first time a
wallpaper is chosen from the shell. `switchwall.sh --noswitch` is the
candidate for doing it headlessly and is untested.

### Video wallpaper playback options (parked)

switchwall.sh runs mpvpaper with a hardcoded option string and no
environment override:

    no-audio loop hwdec=auto scale=bilinear interpolation=no
    video-sync=display-resample panscan=1.0 video-scale-x=1.0
    video-scale-y=1.0 video-align-x=0.5 video-align-y=0.5 load-scripts=no

For playback at the display refresh rate rather than the source rate,
interpolation=no becomes yes. video-sync=display-resample is already set,
which is the prerequisite; tscale=oversample is a cheaper kernel than the
default. Nothing can exceed the source framerate without interpolation.

Changing it means editing the script inside the end4-pC clone, which dirties
the git tree — and ansible.builtin.git refuses to update a repo with local
modifications, so the next run fails at Fetch end4-pC. The durable form is a
lineinfile rewriting VIDEO_OPTS after the clone, self-healing like the
qsConfig patch. Not implemented.

Not worth tuning in the VM: LIBGL_ALWAYS_SOFTWARE means hwdec finds no
decoder and interpolation runs on llvmpipe. Judge this on hardware.

The restore script it generates, __restore_video_wallpaper.sh, pkills
mpvpaper and relaunches one instance per monitor from hyprctl monitors -j.

### What a real install taught that the docs did not

Two policies were correct against the documentation and wrong in practice.
Both surfaced only on a fresh profile, and `about:policies` is what found
them.

**`CrashReportsSubmit` is unknown to this Firefox.** It is listed in the
current admin docs, but `about:policies#errors` reports
`Unknown policy: CrashReportsSubmit` — the build predates it. An
unrecognised policy is silently inert, so the errors tab is the only place
it shows up. Removed. `DisableTelemetry` covers most of what it would have
done; anything more specific would go through `Preferences`, where
`browser.*` is an allowed prefix.

**`PopupBlocking.Default` is documented backwards.** The docs say it
"determines whether or not pop-up windows and third-party redirects are
allowed by default", which reads as `false` = blocked. On a fresh install
`false` produced *unblocked* — and stock Firefox blocks popups, so the
policy actively turned the blocker off. It is set to `true` here, from
observation rather than documentation. Re-test if it ever seems wrong.

### about:policies is the only way to check any of this

`#active` lists what Firefox parsed, `#errors` lists what it rejected. A
policy with a bad key or an unknown name is ignored silently — nothing logs,
nothing warns, and the setting simply keeps its old value.

Two things it does *not* tell you, both of which cost time here:

- An unlocked policy sets the **default**. It applies cleanly to a fresh
  profile, but anything changed by hand afterwards wins and the policy sits
  underneath doing nothing. A setting that "did not apply" is often one that
  was clicked later.

  Confirmed by reapplying the policy on a running install: every value moved
  to match except the one that had been changed manually, which kept the hand
  set value. To recover one of those, either set it in the UI to the value
  you want — it then agrees and stays — or reset the underlying pref in
  about:config so the policy default applies again.
- `#active` shows the value Firefox parsed, not the value in effect. Those
  differ whenever the point above applies.

`Locked: true` removes that ambiguity by greying the setting out, at the cost
of not being able to change it at all. Not used here — this is one machine,
not a fleet — but it is the lever if a policy keeps losing to manual changes.

## Remote access

`roles/remote`, gated on `nyx_remote_enabled`. Two servers pointed at one
headless output.

The headless output is the whole point. The physical display is 5120x1440 and
a laptop or phone is not, so mirroring it scales badly in both directions. A
headless output is a monitor that exists only over the network, at whatever
size the client actually has. `/usr/local/bin/nyx-headless up|down|name`
creates and removes it; `nyx-rdp` wraps that plus the server and tears the
output down on exit.

Hyprland assigns the output name — `HEADLESS-2` and so on — rather than
accepting one, so the script discovers it by diffing `hyprctl monitors -j`
before and after `hyprctl output create headless`. Creation is asynchronous,
so it polls rather than sleeping a fixed amount. The name being dynamic is
also why `output` is passed to hypr-rdp on the command line rather than
pinned in its config file.

Two things the first version got wrong, both about hyprctl outside a session.
It prints `HYPRLAND_INSTANCE_SIGNATURE not set!` as plain text on stdout and
still exits 0, so piping it to jq produced `Invalid numeric literal at line
1, column 28` rather than anything useful. The script now checks the shape of
the output before parsing, and reports what hyprctl actually said. It also
finds the running instance itself from `$XDG_RUNTIME_DIR/hypr` rather than
requiring three exported variables — which matters because sunshine prep
commands run with none of the session environment.

### RDP rather than VNC

This started as wayvnc, which is a repo package. It was replaced by
**hypr-rdp** — AUR, MIT, Rust on IronRDP — because VNC loses on every axis
that matters here: no audio, no hardware encoding, frame diffing instead of
H.264, and a third-party client needed on every platform. RDP clients ship
with Windows and macOS and are first-party on iOS and Android, which is the
whole "any random device" requirement.

hypr-rdp captures through `wlr-screencopy-v1` and `ext-image-copy-capture-v1`,
encodes H.264 through VA-API with an OpenH264 fallback, forwards audio over
PipeWire via RDPSND, and syncs the clipboard both ways.

That is the reason `nyx_packages_aur` is no longer empty. It is conditional —
`['hypr-rdp'] if nyx_remote_enabled else []` — so the AUR surface exists only
on machines that asked for remote access. No repo packages a VNC or RDP
server for Hyprland, so there was no way to have this and an empty AUR list.

**Do not forward to port 3389 on the client.** Windows Remote Desktop listens
on `0.0.0.0:3389`, which already covers `127.0.0.1:3389`, so `ssh -L 3389:...`
cannot bind — and mstsc pointed at `localhost:3389` then reaches the client
machine itself and reports "you already have a console session in progress",
which reads like a server problem and is not one. `nyx_rdp_local_port` is
13389 for that reason:

    ssh -L 13389:localhost:3389 <user>@<host>

**The password is not in the repo.** `nyx_rdp_password` defaults to empty and
the config file is only written when it has a value, at mode 0600. Supply it
with `-e nyx_rdp_password=...` or from `host_vars/`, which `.gitignore`
excludes. Binding is `127.0.0.1` so an SSH tunnel is still the transport —
RDP encrypts itself, unlike VNC, so that is defence in depth rather than the
only protection.

**sunshine** (cachyos) stays for anything where latency is the point, with
Moonlight clients on phones, tablets, Steam Deck and TVs. Its own TLS and PIN
pairing mean it does not need the tunnel. Configured through a web UI at
`https://localhost:47990` on first run, including the prep commands:

    do:   /usr/local/bin/nyx-headless up
    undo: /usr/local/bin/nyx-headless down

Deliberately not automated: sunshine's config format has not been verified
here, and writing one blind is exactly how a silently-ignored file happens.

**Neither server is started by the role.** Both attach to a running
compositor, which does not exist during provisioning, and ii deliberately
does not use uwsm, so there is no `graphical-session.target` for a systemd
user unit to hang off.

`roles/base` used to enable sshd on VMs only, which left a physical machine
with no way in at all. It is now `nyx_sshd_enabled`, defaulting to
`is_vm or nyx_remote_enabled`.

For reaching any of this from outside the LAN, a mesh VPN — Tailscale,
WireGuard — is the right layer rather than forwarding ports. Not provisioned.

### Untested

None of this has been run. hypr-rdp appeared around March 2026 and its
maturity is unknown; whether it works against this Hyprland version is the
first thing to find out.

The games half cannot be evaluated in the VM at all: sunshine wants hardware
encoding and Hyper-V has no GPU. hypr-rdp has the same problem — VA-API with
no GPU falls back to OpenH264 software encoding, which will run and will tell
you nothing about quality or latency. Both belong in the same bucket as
`roles/gpu`: written from documentation, to be proven on metal.

## Web apps, and why they are not PWAs

Firefox removed Site Specific Browser support and never replaced it, so there
is no install-as-app to hook into. `nyx_web_apps` renders one .desktop file
per entry into `~/.local/share/applications`, each running
`firefox --new-window <url>`. They appear in the launcher with a name and
icon and open the site — but in a normal Firefox window, browser chrome and
all.

PWAsForFirefox is the option that gives real app windows with isolated
profiles. It needs a native messaging host, an extension and a second Firefox
runtime, which is a lot of moving parts for what is mostly a window
decoration difference. Not used.

Written to the user applications directory rather than `/usr/share`, since
they are a personal choice rather than something the system provides.

OnlyOffice was installed and then dropped — the Office web apps cover the
same ground without a desktop suite. LibreOffice remains the repo option if
an offline editor is ever wanted.

`render-check` renders every template against the flat variable context,
which has no `item`, so a template used inside a loop failed as undefined. It
now carries a `LOOP_TEMPLATES` map from template name to the variable
supplying `item`, and renders once per entry — verified to still catch a bad
attribute reference inside one rather than passing everything blindly.

## mpvpaper is uninstallable, and took greetd with it

A real install failed at session_hyprland's package task:

    :: unable to satisfy dependency libbluray.so=3-64 required by mpv-git
    :: unable to satisfy dependency libmpv.so=2-64 required by mpvpaper

cachyos/mpvpaper needs libmpv.so=2-64. Pacman resolves that to
cachyos/mpv-git, which needs libbluray.so=3-64, and nothing in the repos
provides that soname. Upstream repo skew rather than anything here, so it
will probably fix itself; re-add the package and check with
pacman -S --print mpvpaper.

Video wallpapers do not work without it. Static wallpapers are unaffected —
those go through matugen and swww, neither of which touches mpv.

The second half of this is ours. greetd, greetd-tuigreet and every
application were installed in one pacman transaction, so one unsatisfiable
optional package aborted all of it and the machine got no display manager.
Login packages are now their own transaction, ahead of the applications: an
app that cannot be resolved still fails the play loudly, but it fails after
the machine can reach a login rather than instead of it.

The install.sh error output did its job here — stage: provision, the exact
arch-chroot command, exit 2, and pacman naming both unsatisfied sonames.

## The become password prompt was never suppressible

`ansible.cfg` set `become_ask_pass = True`. That prompts at *startup*, before
any variable is considered, so `-e ansible_become_password=""` in install.sh
never suppressed it — it only overrode the value afterwards. The prompt
appeared on every unattended install and accepted anything non-empty, which
is exactly the kind of thing that looks like it works and is meaningless.

It was also redundant. Everything that runs the playbook by hand already
passes `--ask-become-pass` itself: `scripts/run.ps1` and the verify commands
in CLAUDE.md. So the setting is removed rather than worked around, and
install.sh no longer passes an override it did not need.

Running by hand as a non-root user without `--ask-become-pass` now fails with
"sudo password required", which is clear.

## Second full install: clean

A complete run after the mpvpaper fix: **80 ok, 48 changed, 19 skipped, 0
failed, 0 unreachable, 0 rescued, 0 ignored**.

That is the first time the current configuration has executed end to end. It
covered 27 commits that had never run, including the whole of `roles/remote`,
the split login/application package transactions, the user-creation rewrite,
the RDP password service, the fish MOTD drop-in, the gaming stack, the
Firefox web-app launchers, podman, and the ufw/rclone/jq/sbctl/chwd
additions.

Still unverified by this, because installing is not the same as running:

- hypr-rdp actually serving a session, and the headless output it serves
- the RDP password service firing on a real boot, and the MOTD printing it
- sunshine, which needs hardware encoding the VM does not have
- `hypr/custom/env.lua` being sourced at all
- `custom/general.lua` being loaded, and the SUPER+escape bind working
- `roles/gpu`, which the VM skips entirely

## Suppressing the first-run wizard

end4-pC FirstRunExperience.qml gates on a marker file:

    firstRunFilePath: Directories.state + /user/first_run.txt

Present means already greeted; absent means show the dialog. The
Show next time toggle in the dialog rm -f s the file to bring the wizard
back and writes it to suppress it, so creating the file is the entire
mechanism. Confirmed by toggling it on a real install.

Directories.state resolves to ~/.local/state/quickshell, so the marker is
~/.local/state/quickshell/user/first_run.txt. That path was verified rather
than assumed — a wrong one fails silently, since the only symptom is the
dialog appearing.

The role writes it AFTER ./setup install. The installer has its own opinion:
a --firstrun / -F flag and a gen_firstrun() in
sdata/subcmd-install/3.files.sh that decides whether this counts as a first
run, plus a setup resetfirstrun subcommand that deletes the marker. Writing
it afterwards means the repo wins regardless of what the installer decided.

The file is written with the same content the QML writes rather than being
touched empty — it reloads and reads the file, and an empty one has not been
shown to satisfy it.

nyx_ii_suppress_firstrun turns this off if the wizard is ever wanted back.

## The ISO resolv.conf does not belong on the installed system

install.sh copies /etc/resolv.conf from the live environment into the target,
because arch-chroot does not bind-mount it and the chroot needs DNS for
pacstrap and the playbook. It is now removed again after provisioning.

Left in place it is a static file holding the ISO nameservers, sitting exactly
where NetworkManager and systemd-resolved both expect to own the path.
NetworkManager usually replaces it on the first connection after boot, so this
is minor rather than breaking — but it does not self-heal when rc-manager is
set to file or unmanaged, and a static file shadows the systemd-resolved stub
symlink outright.

Found while investigating an unmanaged eth0 that turned out to be unrelated
and did not recur.

## Idle suspend takes eth0 down on Hyper-V

Reported as an unmanaged eth0 with no network. It is reproducible: leave the
machine idle long enough that the screen blanks, come back, and the interface
is down. An earlier occurrence looked like a one-off and was dismissed; it is
not.

illogical-impulse ships a hypridle config with a suspend listener, so an idle
session blanks the screen and then suspends the machine. A Hyper-V guest does
not survive that cleanly — hv_netvsc does not reinitialise on resume, so
NetworkManager finds a device it can no longer manage and the network is gone
until it is told to take it back:

    sudo nmcli device set eth0 managed yes

Fixed by masking the sleep targets rather than editing hypridle.conf, which
./setup install rewrites on every run. See nyx_inhibit_sleep in
roles/base/defaults/main.yml. DPMS blanking is unaffected; only the
transition to sleep is refused.

The same masking applies to any machine with remote access enabled, VM or
not. A desktop that suspends itself is unreachable over RDP exactly when it
is wanted, which is a policy decision independent of the Hyper-V bug.

The trigger is hypridle, confirmed against upstream rather than inferred.
dots/.config/hypr/hypridle.conf in end-4/dots-hyprland defines
$suspend_cmd = systemctl suspend || loginctl suspend and three listeners:

    300s   loginctl lock-session
    600s   dpms disable / enable on resume
    900s   $suspend_cmd

That matches the reported timings exactly. The screen blanking before the
suspend is the 600s listener firing five minutes ahead of the 900s one, and
the observed resume at 20:33:44 to suspend request at 20:48:47 is 900s to the
minute. hypridle is started from ii's Hyprland config — hl.exec_cmd("hypridle")
in hypr/hyprland/execs.lua — not from a systemd user unit.

The journal line names a client: "suspend requested from client PID 3037
('systemctl') (unit session-3.scope)". That is logind logging a userspace
caller of its Suspend() method from inside the graphical session, which rules
out logind's own IdleAction (defaults to ignore, and would not name a client)
and any host-side or ACPI event.

The battery path is not involved. config.json sets battery.automaticSuspend
true with suspend at 3%, but ii's Battery.qml gates that on UPower reporting a
battery, and a Hyper-V Gen2 guest exposes none. It cannot fire here, and it
cannot fire on a batteryless desktop either.

Masking the action targets, not just sleep.target, is what makes this work.
logind checks the load state of the action target before emitting
PrepareForSleep(true), so a masked suspend.target is refused up front. Masking
sleep.target alone would let the whole pre-sleep sequence run — including the
NetworkManager sleep handling that unmanages the interface — and fail only at
the final job. That is worse than no fix. sleep.target stays in the list to
close the systemctl start systemd-suspend.service path, since that service
has Requires=sleep.target.

Two consequences worth knowing. The Suspend entry in ii's session menu is now
a dead control: it runs the same systemctl suspend and fails the same way.
And the mask does not block the low-level paths — systemd-sleep suspend, echo
mem > /sys/power/state, or a host-side Hyper-V save-state — so the underlying
hv_netvsc resume fragility is avoided rather than repaired. If the interface
is ever found unmanaged again, that is the thing to check first:

    sudo nmcli device set eth0 managed yes
    journalctl -b -1 -g 'suspend|Reached target Sleep|hv_netvsc'

ii is tracked at an unpinned branch (nyx_ii_version: main), so the timeout
values above are what upstream had when this was diagnosed, not a contract.
