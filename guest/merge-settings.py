#!/usr/bin/env python3
"""Merge claudelxc's managed settings into an existing settings.json in place.

Usage: merge-settings.py <managed-template.json> <target-settings.json>

converge owns a handful of keys (auto mode, the deny security floor, required
env, the curated plugins, alwaysThinkingEnabled) and must enforce them on every
run. But it must NOT clobber what the user added through the UI — extra enabled
plugins, their own permission rules, a statusLine, hooks, a model override, etc.
A wholesale overwrite silently disables a user's own plugins every night; this
merge enforces the managed keys while preserving everything else.

Rules (managed applied over the user's current file):
  - dicts   -> merged recursively (managed wins at conflicting leaves;
               user-only keys are kept). Covers env and enabledPlugins: the
               managed entries are forced, the user's extras survive.
  - lists   -> union, user order first (covers permissions.deny: the floor is
               always present, and the user can ADD denies but not drop the floor).
  - scalars -> managed value wins (e.g. permissions.defaultMode = auto).
  - any key present only in the user's file is left untouched.

On any error the target file is left exactly as it was (exit non-zero), so a bad
parse never wipes a working config.
"""
import json
import sys


def merge(base, over):
    """Apply `over` (managed) onto `base` (user's current); return `base`."""
    for key, oval in over.items():
        if key in base and isinstance(base[key], dict) and isinstance(oval, dict):
            merge(base[key], oval)
        elif key in base and isinstance(base[key], list) and isinstance(oval, list):
            for item in oval:
                if item not in base[key]:
                    base[key].append(item)
        else:
            base[key] = oval
    return base


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: merge-settings.py <managed.json> <target.json>\n")
        return 2
    managed_path, target_path = sys.argv[1], sys.argv[2]

    with open(managed_path) as f:
        managed = json.load(f)
    if not isinstance(managed, dict):
        sys.stderr.write("managed template is not a JSON object\n")
        return 2

    # Load the user's current settings; tolerate missing/empty/corrupt by
    # starting from {} (managed becomes the whole file, same as a fresh box).
    try:
        with open(target_path) as f:
            current = json.load(f)
        if not isinstance(current, dict):
            current = {}
    except (FileNotFoundError, ValueError):
        current = {}

    merged = merge(current, managed)

    # Write atomically-ish: temp file in the same dir, then replace.
    tmp = target_path + ".merge.tmp"
    with open(tmp, "w") as f:
        json.dump(merged, f, indent=2)
        f.write("\n")
    import os
    os.replace(tmp, target_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
