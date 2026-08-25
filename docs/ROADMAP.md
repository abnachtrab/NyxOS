# Roadmap

Ordered so nothing risky lands before the foundation is proven. Each phase
ends with `.\run.ps1` passing from a clean revert.

---

## Phase 1 — VM + base install  *(done by hand, once)*

External vSwitch. Gen 2 VM, 8GB static, 6 vCPU, 60GB, **Secure Boot off**,
**TPM on**, Standard checkpoints, automatic checkpoints off, nested virt on.

CachyOS install: **no desktop environment**, systemd-boot, no LUKS,
**btrfs** (the installer default), `linux-cachyos`, "CachyOS Packages" yes,
"Shell Configuration" **no**, base-devel yes.

The filesystem matters: `install.sh` builds btrfs with the same subvolume
layout, so a checkpoint made on ext4 or XFS tests a different disk shape
than the one that ships.

Then `pacman -S openssh git ansible-core`, enable sshd, push key from Windows,
verify passwordless, harden sshd, DHCP reservation, hosts entry.

Record the baseline before snapshotting:

    pacman -Qe > ~/baseline-packages.txt

Anything in that list not installed by the `pacstrap` line in `install.sh`
is a silent dependency. Diff the two when building the ISO.

**Checkpoint: `base-install`.**

## Phase 2 — repo + loop

Clone, `ansible-galaxy collection install -r requirements.yml`, VS Code
Remote-SSH. Confirm `.\run.ps1 -Tags detect` runs without manual intervention before
proceeding.

## Phase 3 — detect  *(done)*

Verified on Hyper-V: `virt=VirtualPC`, `march=x86-64-v4`,
`has_tpm=true`, `secureboot=false` via soft-failed sbctl. `profiles/hyperv.json`
matches.

## Phase 4 — base  *(done)*

Repo handling is read-only: the CachyOS installer owns the sections in
`pacman.conf` and `roles/base` asserts they exist rather than writing them.

Verified: repo assert reads all four sections on Zen 5
(`cachyos-znver4`, `cachyos-core-znver4`, `cachyos-extra-znver4`, `cachyos`),
`7zip` resolves, yay bootstraps, temp sudoers grant is revoked.

Second-run idempotency required three fixes; see docs/NOTES.md. Re-run
`--tags base` twice after any change to this role — the second run is the
test that matters.

---

## Phase 5 — session_hyprland  *(done)*

The shell is illogical-impulse: Quickshell bar, notifications, launcher,
OSD, session menu, its own Hyprland config in Lua, and fish with starship.
`./setup install` does the work; this role runs it non-interactively and
layers NyxOS on top.

- **greetd + tuigreet.** Both from the repos. tuigreet runs
  `--cmd start-hyprland`, bypassing session selection — which also sidesteps
  ii's "do not select UWSM" warning.
- **Portal preference is explicit.** ii installs the KDE portal alongside
  Hyprland's and GTK's; without a stated preference the backend is chosen by
  filename sort order and screenshare breaks non-deterministically.
- **VM branch is functional only**: software GL in `hypr/custom/env.lua`, so
  Hyprland can start at all under Hyper-V. Nothing cosmetic is disabled.
- **GPU branch** in the same file: nvidia / radeonsi / iHD.
  `WLR_NO_HARDWARE_CURSORS` deliberately omitted — obsolete since 555.

Verified on a real install: boots, reaches tuigreet, authenticates, and
starts Hyprland running end4-pC. Firefox policy and extensions apply. What
that run did not cover is listed under "Not yet verified" in NOTES.md — most
notably whether `hypr/custom/env.lua` is the thing supplying software GL.

Still to do: a wallpaper. `nyx_hypr_wallpaper` is empty and matugen has
nothing to derive a scheme from without one.

## Phase 6 — gpu

Collapsed from three roles into one. `chwd -a` picks the driver profile; the
role adds the userspace Hyprland needs (`nyx_nvidia_packages`), early KMS
modules, `/etc/modprobe.d/nvidia.conf`, and the cmdline flag.
`roles/session_hyprland` writes the compositor env vars.

`i915` goes first in `MODULES` on hybrid Intel+NVIDIA, or Electron apps
stall after boot. `lib32-nvidia-utils` requires `[multilib]`, which the role
asserts. See docs/NOTES.md for the full list and the hibernation caveat.

Headers must match `nyx_kernel` or DKMS produces no module without erroring.
Untestable in Hyper-V (no PCI GPU) — use `-e @profiles/...` or wait for
hardware.

## Phase 6b — theme  *(dropped)*

There is no theme role. illogical-impulse themes with matugen, deriving the
scheme from the wallpaper at runtime, so `roles/theme`, `nyx_palette` and
`nyx_roles` were removed rather than fought.

What matugen does not reach still needs doing, and now needs doing ii's way:
rEFInd and Plymouth. GTK and Qt are covered by ii's own theme packages.

## Phase 7 — branding

`/etc/os-release` (retain `arch` in `ID_LIKE`; third-party scripts branch on it),
`/etc/lsb-release`, logo at `/usr/share/pixmaps/`, fastfetch config, loader
entry title, `/etc/machine-info`. `NoUpgrade` already set in base.

## Phase 8 — backup_rclone

Register a private Entra app rather than using rclone's shared client ID:
better throughput, no shared throttling. Personal tenant, not Visory.

One-way `rclone sync` with `--backup-dir` pointing at a dated folder so
deletes are recoverable. `--tpslimit 10` to avoid 429s on first sync.
systemd timer, not cron.

Token is configured by hand once per machine (`rclone config`) and never
committed. A `crypt` remote wraps the LUKS header backup.

## Phase 9 — archiso

`releng` profile. CachyOS repos + keyring on the **build host** or signature
verification fails. Thin package list — live env only. Playbook bundled in
`airootfs/root/`, `install.sh` autostarted from `.zprofile`.

Script should `git pull` when network is up and fall back to the bundled copy,
so old media still installs current config.

Build on a CachyOS host, not plain Arch.

## Phase 10 — encryption + boot chain

**Required order:**

1. LUKS on p3, with btrfs inside the container rather than the reverse
2. recovery partition populated; its UKI must also be signed, or it cannot
   boot when Secure Boot is the thing that failed
3. `sbctl create-keys` then `enroll-keys --microsoft` (requires firmware
   Setup Mode; omitting the Microsoft certs can break option ROMs)
4. UKI via mkinitcpio preset
5. `sbctl sign -s` everything; verify the pacman hook exists
6. `systemd-cryptenroll --tpm2-with-pin` **last**

Enrolment changes PCR 7, invalidating any TPM-sealed keyslot. Sealing before
signing requires redoing it.

Keep a plain passphrase in a separate LUKS keyslot. `luksHeaderBackup` to the
crypt remote: a corrupt header renders the data unrecoverable on an otherwise
healthy disk.

Test in **QEMU + OVMF**, not Hyper-V: `cp OVMF_VARS.4m.fd vars.fd` gives a
fresh firmware in Setup Mode every run. Hyper-V has Secure Boot but no
firmware UI, so custom key enrolment can't be exercised there.

## Phase 11 — metal

Desktop after December. No laptop target.
