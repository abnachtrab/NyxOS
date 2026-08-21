# Roadmap

Ordered so nothing risky lands before the foundation is proven. Each phase
ends with `.\run.ps1` passing from a clean revert.

---

## Phase 1 — VM + base install  *(done by hand, once)*

External vSwitch. Gen 2 VM, 8GB static, 6 vCPU, 60GB, **Secure Boot off**,
**TPM on**, Standard checkpoints, automatic checkpoints off, nested virt on.

CachyOS install: **no desktop environment**, systemd-boot, no LUKS,
`linux-cachyos`, "CachyOS Packages" yes, "Shell Configuration" **no**,
base-devel yes.

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

Verified on Hyper-V: `virt=VirtualPC`, `chassis=Desktop`, `march=x86-64-v4`,
`has_tpm=true`, `secureboot=false` via soft-failed sbctl. `profiles/hyperv.json`
matches. Dead hypervisor keys pruned from `roles/virt_guest/defaults`.

## Phase 4 — base

Before running, inspect what the CachyOS installer already wrote:

    grep -A2 '^\[cachyos' /etc/pacman.conf
    ls /etc/pacman.d/ | grep -i cachy

`roles/base` assumes `/etc/pacman.d/cachyos-v4-mirrorlist`. Correct the
blockinfile to match reality first, or it appends duplicate sections with
broken Include paths. Then confirm the tier written matches
`nyx_profile.march`. Then check the AUR bootstrap: `yay --version` as `nyx_user`,
and confirm `/etc/sudoers.d/99-nyx-aur-temp` is gone at the end.

---

## Phase 5 — session_hyprland

Packages: hyprland, xdg-desktop-portal-hyprland **and** -gtk, hyprpolkitagent,
hyprlock, hypridle, hyprpaper, waybar, fuzzel, swaync, cliphist, wl-clipboard,
hyprshot, qt5-wayland, qt6-wayland, pipewire, wireplumber, brightnessctl,
playerctl.

Config split under `~/.config/hypr/conf.d/` — monitors and env templated per
profile, keybinds and rules static. The portal preference file is required; without it screenshare selects the
wrong backend without reporting an error.

Ship a fallback session (plain foot, or Plasma) in the display manager. A
broken Hyprland config on a machine with no other session requires TTY
recovery.

VM branch: blur and animations off, `misc:no_direct_scanout`, forced
resolution. Hyprland's default effects perform poorly under llvmpipe.

## Phase 6 — gpu_*

- **nvidia** — Turing+ → `nvidia-open-dkms`, older → proprietary/legacy branch.
  `nvidia_drm.modeset=1`, early KMS modules, env vars in Hyprland config.
  `WLR_NO_HARDWARE_CURSORS` is obsolete on current drivers; do not set it.
- **amd** — mesa, vulkan-radeon, lib32-*.
- **intel** — vulkan-intel, intel-media-driver (Gen8+) vs libva-intel-driver.

Headers must match `nyx_kernel` or DKMS produces no module without erroring.
Only testable via `-e @profiles/...` until deployed to hardware.

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

1. LUKS on p3
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

Surface first: v3, Intel iGPU, laptop, requires `linux-surface`. Desktop
after December.
