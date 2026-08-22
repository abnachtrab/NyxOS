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

## Phase 5 — session_hyprland  *(booting in Hyper-V)*

`hyprland.conf` sources `conf.d/theme.conf` (owned by roles/theme) plus
monitors, env, autostart, keybinds, rules. Monitors and env are templated per
profile; keybinds and rules are static.

- **greetd + hyprlogin.** hyprlogin is a hyprlock fork sharing its config
  format, so login and lock are one theme. tuigreet stays installed as a
  one-variable fallback; hyprlogin is WIP and AUR-only.
- **Both portals installed**, with `hyprland-portals.conf` setting the
  preference explicitly. Without it the backend is chosen by filename sort
  order and screenshare breaks non-deterministically.
- **VM branch**: no blur, shadows, or animations; `no_direct_scanout`;
  software GL. Hyprland's defaults are unusable under llvmpipe.
- **GPU branch** in `conf.d/env.conf`: nvidia / radeonsi / iHD.
  `WLR_NO_HARDWARE_CURSORS` deliberately omitted — obsolete since 555.

Verified: 15 templates render against all 4 profiles, waybar config parses as
JSON, keybind collision check passes (53 binds, no duplicates). Boots to
hyprlogin, authenticates, and starts Hyprland with waybar under llvmpipe.

Config syntax drift found on that first boot is written up in NOTES.md —
`togglesplit`, `windowrulev2`, and `start-hyprland`.

Still to do: a dotfiles role with a real `.zshrc` (zsh prompts
`zsh-newuser-install` on first login), and a wallpaper — `nyx_hypr_wallpaper`
points at a file that does not exist yet.

## Phase 6 — gpu

Collapsed from three roles into one. `chwd -a` picks the driver profile; the
role only adds early KMS modules and `nvidia_drm.modeset=1`, and
`roles/session_hyprland` writes the compositor env vars.

Headers must match `nyx_kernel` or DKMS produces no module without erroring.
Untestable in Hyper-V (no PCI GPU) — use `-e @profiles/...` or wait for
hardware.

## Phase 6b — theme

Palette renders cleanly to shell/CSS/Hyprland/kitty/waybar. Remaining
consumers are the ones that need a real theme package rather than a colour
file: SDDM, GTK, Kvantum, rEFInd, Plymouth.

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

Desktop after December. No laptop target.
