#!/usr/bin/env python3
"""Render every role template against every profile and sanity-check output.

Catches Jinja errors without touching a VM. Since illogical-impulse took over
the Hyprland and shell config, the templates left here are the small NyxOS
overlay — env.lua, the Ozone flag files, greetd, portals — so this checks far
less than it used to. It still catches the failure that matters: a template
that raises during render leaves the machine without the file, and for
env.lua that means no software GL and no session under Hyper-V.

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
    env.filters["to_nice_json"] = lambda v: json.dumps(v, indent=4, sort_keys=True)
    env.filters["basename"] = os.path.basename
    return env


def resolve_vars(env, ctx, passes=4):
    """Resolve variables that reference other variables.

    Ansible templates var values recursively, so `nyx_ii_checkout:
    "/home/{{ nyx_user }}/..."` arrives at a task fully expanded. Rendering a
    template with the raw dict instead leaves the inner {{ }} intact, which
    silently produces output that looks fine and is wrong. Iterate until
    nothing changes.
    """
    for _ in range(passes):
        changed = False
        for key, value in list(ctx.items()):
            if isinstance(value, str) and "{{" in value:
                try:
                    rendered = env.from_string(value).render(**ctx)
                except Exception:  # noqa: BLE001 - unresolvable here is fine
                    continue
                if rendered != value:
                    ctx[key] = rendered
                    changed = True
        if not changed:
            break
    return ctx


def templates_in(tdir):
    base = os.path.join(ROOT, tdir)
    # Jinja2's FileSystemLoader only accepts "/" in template names, so the
    # native separator has to be normalised or every nested template fails
    # to load when this runs from Windows.
    return sorted(
        os.path.relpath(p, base).replace(os.sep, "/")
        for p in glob.glob(os.path.join(base, "**", "*.j2"), recursive=True)
    )


def check_lua(text):
    """Cheap syntax screen for rendered Lua.

    Not a parser. Catches the two ways a Jinja conditional mangles hl.env()
    output: an unbalanced call, or a key rendered empty because a fact was
    missing.
    """
    problems = []
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line.startswith("hl."):
            continue
        if line.count("(") != line.count(")"):
            problems.append(f"line {n}: unbalanced parens: {line}")
        if re.search(r'\(\s*""', line) or re.search(r',\s*""\s*\)', line):
            problems.append(f"line {n}: empty argument: {line}")
    return problems


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
        env = build_env(tdir)
        names = templates_in(tdir)
        if not names:
            continue

        for pname, profile in profiles.items():
            ctx = resolve_vars(env, {**group_vars, **defaults,
                                     "nyx_profile": profile})
            for name in names:
                try:
                    out = env.get_template(name).render(**ctx)
                    rendered += 1
                except Exception as exc:  # noqa: BLE001
                    failures.append(f"{role}/{name} [{pname}]: {exc}")
                    continue

                if name.endswith(".json.j2"):
                    try:
                        json.loads(out)
                    except json.JSONDecodeError as exc:
                        failures.append(f"{role}/{name} [{pname}] bad JSON: {exc}")

                if name.endswith(".lua.j2"):
                    for problem in check_lua(out):
                        failures.append(f"{role}/{name} [{pname}] {problem}")

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
