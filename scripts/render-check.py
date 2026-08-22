#!/usr/bin/env python3
"""Render every role template against every profile and sanity-check output.

Catches Jinja errors, invalid waybar JSON, and duplicate Hyprland keybinds
without touching a VM. A template that fails here is a broken desktop.

    python3 scripts/render-check.py

Requires: pyyaml, jinja2.
"""
import glob
import json
import os
import re
import sys

import yaml
from jinja2 import Environment, FileSystemLoader

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_yaml(path):
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return {}
    with open(full) as fh:
        return yaml.safe_load(fh) or {}


def build_env(tdir):
    # Ansible's template module uses trim_blocks; `bool` is an Ansible filter,
    # not core Jinja2, so it has to be registered here.
    env = Environment(
        loader=FileSystemLoader(os.path.join(ROOT, tdir)),
        keep_trailing_newline=True,
        trim_blocks=True,
    )
    env.filters["bool"] = lambda v: v is True or str(v).lower() in (
        "true", "1", "yes", "on",
    )
    return env


def templates_in(tdir):
    base = os.path.join(ROOT, tdir)
    # Jinja2's FileSystemLoader only accepts "/" in template names, so the
    # native separator has to be normalised or every nested template fails
    # to load when this runs from Windows.
    return sorted(
        os.path.relpath(p, base).replace(os.sep, "/")
        for p in glob.glob(os.path.join(base, "**", "*.j2"), recursive=True)
    )


def check_keybinds(text):
    seen, dupes = set(), []
    for line in text.splitlines():
        m = re.match(r"\s*bind[elm]*\s*=\s*([^,]*),\s*([^,]+),", line)
        if not m:
            continue
        combo = (m.group(1).strip(), m.group(2).strip())
        if combo in seen:
            dupes.append(combo)
        seen.add(combo)
    return len(seen), dupes


def main():
    group_vars = load_yaml("group_vars/all.yml")
    profiles = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "profiles", "*.json"))):
        with open(path) as fh:
            profiles[os.path.basename(path)[:-5]] = json.load(fh)["nyx_profile"]

    roles = [
        d for d in sorted(os.listdir(os.path.join(ROOT, "roles")))
        if os.path.isdir(os.path.join(ROOT, "roles", d, "templates"))
    ]

    failures = []
    rendered = 0

    for role in roles:
        tdir = f"roles/{role}/templates"
        defaults = load_yaml(f"roles/{role}/defaults/main.yml")
        theme = load_yaml("roles/theme/defaults/main.yml")
        env = build_env(tdir)
        names = templates_in(tdir)
        if not names:
            continue

        for pname, profile in profiles.items():
            ctx = {**group_vars, **theme, **defaults, "nyx_profile": profile}
            for name in names:
                try:
                    out = env.get_template(name).render(**ctx)
                    rendered += 1
                except Exception as exc:  # noqa: BLE001
                    failures.append(f"{role}/{name} [{pname}]: {exc}")
                    continue

                if name.endswith("config.jsonc.j2"):
                    stripped = re.sub(r"^\s*//.*$", "", out, flags=re.M)
                    try:
                        json.loads(stripped)
                    except json.JSONDecodeError as exc:
                        failures.append(f"{role}/{name} [{pname}] bad JSON: {exc}")

                if "keybinds" in name:
                    count, dupes = check_keybinds(out)
                    if dupes:
                        failures.append(
                            f"{role}/{name} [{pname}] duplicate binds: {dupes}"
                        )

                if "windowrulev2" in re.sub(r"^\s*#.*$", "", out, flags=re.M):
                    failures.append(f"{role}/{name} [{pname}] uses deprecated windowrulev2")

        print(f"{role}: {len(names)} templates x {len(profiles)} profiles")

    print(f"\n{rendered} renders across {len(profiles)} profiles: "
          f"{sorted(profiles)}")

    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(f"  {f}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
