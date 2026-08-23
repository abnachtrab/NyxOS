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
- **`is_vm` gates functional things only** — software GL, sshd. It must NOT
  disable blur, shadows, or animations: the VM is where the theme is tuned,
  so it has to look like the real thing. `nyx_hypr_effects` is the separate
  manual toggle.
- **ii owns the Hyprland config.** Do not add templates that write
  `~/.config/hypr/hyprland.conf` or its parts — `./setup install` rsyncs
  them from upstream and would overwrite anything put there. NyxOS additions
  go in `files/ii-overlay/` (copied after ii, so they win) or, for anything
  needing profile branching, a template into `hypr/custom/` like
  `env.conf.j2`.
- Prose in docs and comments is plain and factual. No taglines, no
  editorialising, no second-person asides.

## Verify before claiming anything works

    ansible-playbook site.yml --syntax-check
    ansible-playbook site.yml --tags detect -e nyx_password=skip -e ansible_become=false

Render templates against every profile — a Jinja error is a broken desktop:

    python3 scripts/render-check.py

That checks all templates against all profiles, validates waybar's JSON, and
looks for duplicate keybinds. Two real collisions were caught this way.

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
- Hyprland syntax drifts: `togglesplit` is a `layoutmsg`, `windowrulev2` is
  now `windowrule`.
- One failing AUR package aborts the whole run. Left fatal deliberately.

## Known open items

- Hyprland warns `.conf` support is removed in 0.57; the whole config set
  needs porting to the Lua format. **Adam is doing this himself** — do not
  start it unasked.
- greetd runs tuigreet, `nyx_packages_aur` is empty, and there is no
  greeter switch. Both launch paths call `start-hyprland`, owned by the
  `hyprland` package. Verified on a real install: boots, greets,
  authenticates, and starts Hyprland.
- No dotfiles role yet, so zsh prompts `zsh-newuser-install` on first login.
- `nyx_hypr_wallpaper` is empty on purpose. A path to a nonexistent file
  makes hyprlock fail to draw a background rather than falling back, so do
  not set it until roles/branding ships a real image.
- `nyx_profile.cpu` is detected but unconsumed — no explicit
  `intel-ucode`/`amd-ucode` selection yet.

See `docs/ROADMAP.md` for phase ordering and `docs/NOTES.md` for everything
verified against real hardware versus still assumed.
