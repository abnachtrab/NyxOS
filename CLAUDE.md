# Working on this repo

Ansible provisioning for NyxOS: CachyOS base, Hyprland session, hardware
detected at runtime. Targets are **VMs and desktops only** — laptop support
was removed deliberately and should not come back.

## Architecture

`roles/detect` gathers facts into one dict, `nyx_profile`. Every other role
gates on it. Nothing else calls `lspci` or reads DMI.

A profile can be supplied instead of detected:

    ansible-playbook site.yml -e @profiles/nvidia-desktop-v4.json

That is how hardware paths are tested without the hardware. Keep it working.

Role gating lives in `site.yml`, not inside roles.

## Conventions

- **Colour is matugen's, not ours.** illogical-impulse derives the whole
  scheme from the wallpaper at runtime. `roles/theme`, `nyx_palette` and
  `nyx_roles` were removed; there is no fixed NyxOS palette any more. Set
  `nyx_hypr_wallpaper` and let matugen follow it.
- **`is_vm` gates functional things only** — software GL in `env.lua`,
  sshd, the greetd restart handler, and skipping the gpu and backup roles.
  Nothing cosmetic: the VM is where the desktop is looked at, so it has to
  look like the real thing. ii owns the effect settings now.
- **ii owns the Hyprland config, and it is Lua.** `hyprland.lua` loads
  internal libraries, ii's environment and defaults, then `custom/`. Do not
  write `hyprland.conf` or hyprlang parts — `./setup install` rsyncs
  upstream's over them, and a `.conf` file in `custom/` is silently never
  read. NyxOS additions go in `files/ii-overlay/` (copied after ii, so they
  win) or, when they need profile branching, a template rendered into
  `custom/` like `env.lua.j2`. Filenames there are upstream's: `env.lua`,
  `general.lua`.
- Prose in docs and comments is plain and factual. No taglines, no
  editorialising, no second-person asides.

## Verify before claiming anything works

    ansible-playbook site.yml --syntax-check
    ansible-playbook site.yml --tags detect -e nyx_password=skip -e ansible_become=false

Render templates against every profile — a Jinja error is a broken desktop:

    python3 scripts/render-check.py

That renders all templates against all profiles and screens the generated
Lua. It covers much less than it used to — ii owns the config, so only the
NyxOS overlay is templated — but a template that raises still leaves the
machine without the file, and for `env.lua` that means no session in the VM.

**Second-run idempotency is the test that matters**, not first-run success:

    ansible-playbook site.yml --tags base --ask-become-pass   # twice

## Traps already hit, do not repeat

- `ansible.builtin.command` cannot run shell builtins. `command -v` there
  returns rc!=0 forever and silently re-runs whatever it guards.
- `vars_prompt` with `encrypt:` re-salts every run — needs
  `update_password: on_create` or `user:` always reports changed.
- `arch-chroot` bind-mounts the host's `/proc` rather than making a
  namespace. Anything reading `/proc/cmdline` or the hostname inside it sees
  the **live ISO**, not the target. This produced an unbootable install once
  (`refind_linux.conf` built from the archiso cmdline).
- Microarch detection must come from `/proc/cpuinfo` flags, not
  `/lib/ld-linux-x86-64.so.2` — that path only exists where /lib symlinks to
  /usr/lib, and the failure is silent (reports v1 on a v4 machine).
- `curl | bash` makes stdin the script, so `read` eats script text. All
  prompts in `install.sh` read from `/dev/tty`.
- One failing AUR package aborts the whole run. Left fatal deliberately.
- `sgdisk -Z` does not wipe filesystem superblocks inside the partitions it
  re-creates, so an untyped `mount` on a re-install probes the stale one and
  reports the new filesystem as corrupt.
- `./setup install` prompts unless given `-f`. Under Ansible stdin is
  closed, so a surviving prompt hangs the play instead of failing it.

## Known open items

- **`hypr/custom/env.lua` may not be doing anything.** The session starts
  under Hyper-V, but nothing has confirmed that file is what supplies
  software GL rather than ii doing it another way. `hyprctl getenv` settles
  it. It also carries the GPU vendor branching real hardware depends on.
- greetd runs tuigreet, `nyx_packages_aur` is empty, and there is no greeter
  switch. Both launch paths call `start-hyprland`, owned by the `hyprland`
  package.
- No dotfiles role, deliberately: ii owns the shell. fish is the login shell
  and its config, including the starship prompt, comes from
  `./setup install`.
- `nyx_hypr_wallpaper` is empty, so matugen has nothing to derive a scheme
  from and ii keeps its built-in colours.
- `nyx_profile.cpu` is detected but unconsumed — no explicit
  `intel-ucode`/`amd-ucode` selection yet.
- `/etc/kernel/cmdline` is written by `roles/gpu` but read by nothing until
  Phase 10; `modprobe.d` is what actually sets modeset.

See `docs/ROADMAP.md` for phase ordering and `docs/NOTES.md` for everything
verified against real hardware versus still assumed.
