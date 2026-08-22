# NyxOS

Ansible-based provisioning for my personal machines. CachyOS base, Hyprland
session, hardware detection at runtime so one playbook covers a Hyper-V VM,
an Intel desktop, an AMD desktop, and an NVIDIA desktop.

The NyxOS palette is pastel accents on a near-black base. It is defined once
in `roles/theme/defaults/main.yml` and rendered into shell, CSS, Hyprland,
kitty, and waybar formats; no other file contains a hex value.

## Design

`roles/detect` gathers facts and emits a single dict, `nyx_profile`. Every
other role gates on it. Nothing else calls `lspci` or reads DMI.

A profile can be supplied instead of detected:

```bash
ansible-playbook site.yml -e @profiles/nvidia-desktop-v4.json
```

This is how hardware paths are tested without the hardware — the NVIDIA role
can be exercised from a VM with no GPU.

## Detected facts

| key | source | drives |
|---|---|---|
| `cpu` | `ansible_processor` | microcode |
| `gpus` | `lspci -d ::0300 -d ::0302` | NVIDIA-specific KMS/cmdline work (chwd handles driver choice) |
| `march` | `ld-linux-x86-64.so.2 --help` | CachyOS v3/v4 repo tier |
| `virt` / `is_vm` | `ansible_virtualization_*` | software GL, sshd; skips GPU and backup roles |
| `has_tpm` | `/sys/class/tpm/tpm0` | LUKS TPM enrolment |
| `secureboot` | `sbctl status --json` | signing |

`march` is detected at runtime rather than baked in: v4 packages on a v3 CPU
produce SIGILL in arbitrary binaries rather than a clean failure.

## Layout

```
site.yml              entrypoint; role gating lives here, not inside roles
group_vars/all.yml    package lists, identity, kernel choice
roles/detect/         facts only, never mutates
roles/base/           repos, packages, user, AUR helper, sshd
roles/gpu/            chwd autoconfigure + KMS/cmdline integration
roles/theme/          NyxOS palette rendered into per-app formats
roles/session_hyprland/
roles/branding/       os-release et al
roles/backup_rclone/  OneDrive sync via systemd timer
profiles/             override dicts for untestable hardware
scripts/run.ps1       Hyper-V dev loop: revert, boot, run
scripts/install.sh    unattended bare-metal install
scripts/render-check.py  renders all templates x all profiles, offline
```

## Dev loop

The test VM is disposable. A checkpoint named `base-install` is the reset
point. From the Hyper-V host:

```powershell
.\scripts\run.ps1                 # full run from clean
.\scripts\run.ps1 -Tags session   # iterate on one role
.\scripts\run.ps1 -Profile profiles/nvidia-desktop-v4.json
```

About 30 seconds to a clean state versus ~15 minutes for a reinstall.

## Install

`install.sh` replaces Calamares, not the live ISO. Boot the stock CachyOS
ISO as normal, open a terminal, and run:

```bash
curl -sLO https://raw.githubusercontent.com/abnachtrab/NyxOS/main/scripts/install.sh
NYX_DISK=/dev/nvme0n1 NYX_FORCE=1 bash install.sh
```

Download rather than pipe. The script prompts for the ERASE confirmation and
the user password; piping makes stdin the script itself. It reads from
/dev/tty to work either way, but downloading also lets you read it before
running something that formats a disk.

It partitions, pacstraps, chroots, and runs the playbook. No user is created
by the installer; `roles/base` creates `nyx_user` and nothing else.

Destructive. `NYX_DISK` has no default, and the script refuses to run
unless `nyxos.auto=1` is on the kernel cmdline or `NYX_FORCE=1` is set, so
booting recovery media cannot wipe a machine by accident.

## Secrets

Nothing sensitive is committed. The user password is prompted at run time and
hashed by Ansible. The rclone OAuth token and sbctl keys are generated
per-machine and never leave it. `gitleaks` runs as a pre-commit hook.

## Status

- [x] detect
- [x] base
- [x] session_hyprland
- [ ] gpu
- [ ] theme
- [ ] branding
- [ ] backup_rclone
- [ ] archiso image
- [ ] LUKS + sbctl + UKI

See `docs/ROADMAP.md` for phase ordering and `docs/NOTES.md` for values that
still need verifying against upstream.
