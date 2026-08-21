# Things to verify before trusting them

Written from memory during design. Verify each against upstream before
relying on it.

- **CachyOS repo section names and mirrorlist paths.** `roles/base` assumes
  `cachyos-v3`/`cachyos-v4` and `/etc/pacman.d/cachyos-v3-mirrorlist`. These have been reorganised in the past.
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

- `ansible_virtualization_type` returns `VirtualPC`. Other keys pruned.
- `ansible_form_factor` returns `Desktop`, so `is_laptop` string matching
  works and should behave on the Surface.
- `march` detection returns `x86-64-v4`; host CPU flags pass through.
- `has_tpm` true with the vTPM enabled.

## Known gaps

- No LUKS in `install.sh` yet — p3 is plain ext4 until Phase 10.
- `nyx_backup_paths` is a guess; set it to real directories.
- `session_hyprland`, `gpu_*`, `laptop`, `branding`, `backup_rclone` are
  stubs that print the profile and exit 0.
