# NyxOS

Ansible-based provisioning for my personal machines. CachyOS base, Hyprland
session, hardware detection at runtime so one playbook covers a Hyper-V VM,
an Intel laptop, and an NVIDIA desktop.

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
| `gpus` | `lspci -d ::0300 -d ::0302` | driver role selection (list; hybrid laptops have two) |
| `march` | `ld-linux-x86-64.so.2 --help` | CachyOS v3/v4 repo tier |
| `virt` / `is_vm` | `ansible_virtualization_*` | guest tooling; skips GPU and power roles |
| `is_laptop` | `ansible_form_factor` | power management, sensors |
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
roles/virt_guest/     per-hypervisor guest tooling
roles/gpu_*/          driver stacks
roles/session_hyprland/
roles/branding/       os-release et al
roles/backup_rclone/  OneDrive sync via systemd timer
profiles/             override dicts for untestable hardware
scripts/run.ps1       Hyper-V dev loop: revert, boot, run
scripts/install.sh    unattended bare-metal install
```

## Dev loop

The test VM is disposable. A checkpoint named `base-install` is the reset
point. From the Hyper-V host:

```powershell
.\scripts\run.ps1                 # full run from clean
.\scripts\run.ps1 -Tags session   # iterate on one role
.\scripts\run.ps1 -Profile profiles/intel-laptop-v3.json
```

About 30 seconds to a clean state versus ~15 minutes for a reinstall.

## Install

```bash
NYX_DISK=/dev/nvme0n1 ./scripts/install.sh
```

Destructive. No default disk, and gated behind `nyxos.auto=1` on the kernel
cmdline so recovery media cannot wipe a machine by accident.

## Secrets

Nothing sensitive is committed. The user password is prompted at run time and
hashed by Ansible. The rclone OAuth token and sbctl keys are generated
per-machine and never leave it. `gitleaks` runs as a pre-commit hook.

## Status

- [x] detect
- [x] base
- [x] virt_guest
- [ ] session_hyprland
- [ ] gpu_nvidia / gpu_amd / gpu_intel
- [ ] laptop
- [ ] branding
- [ ] backup_rclone
- [ ] archiso image
- [ ] LUKS + sbctl + UKI

See `docs/ROADMAP.md` for phase ordering and `docs/NOTES.md` for values that
still need verifying against upstream.
