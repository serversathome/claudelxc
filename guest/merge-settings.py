#!/usr/bin/env python3
"""Merge claudelxc's managed settings into an existing settings.json in place.

Usage: merge-settings.py <managed-template.json> <target-settings.json> [retired.json]

converge owns a handful of keys (auto mode, the deny security floor, required
env, the curated plugins) and must enforce them on every run. But it must NOT
clobber what the user added through the UI — extra enabled plugins, their own
permission rules, a statusLine, hooks, a model override, etc. A wholesale
overwrite silently disables a user's own plugins every night; this merge
enforces the managed keys while preserving everything else.

Rules (managed applied over the user's current file):
  - dicts   -> merged recursively (managed wins at conflicting leaves;
               user-only keys are kept). Covers env and enabledPlugins: the
               managed entries are forced, the user's extras survive.
  - lists   -> union, user order first (covers permissions.deny: the floor is
               always present, and the user can ADD denies but not drop the floor).
  - scalars -> managed value wins (e.g. permissions.defaultMode = auto).
  - any key present only in the user's file is left untouched.

Because the merge only ever ADDS, a managed key or list item that a later
claudelxc release drops from the template would otherwise live on forever in
every deployed box. The optional retired.json names those: it mirrors the
settings shape, where a list under a dict key is the set of KEYS to delete
from that dict (e.g. "env": ["OLD_VAR"]) and a list under a list key is the
set of ITEMS to drop (e.g. "permissions": {"deny": ["Bash(old:*)"]}). Retired
entries are stripped BEFORE the managed template is applied. Keys starting
with "_" are ignored (comments).

On any error the target file is left exactly as it was (exit non-zero), so a
bad parse never wipes a working config.
"""
import json
import os
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


def retire(base, spec):
    """Strip retired keys/items described by `spec` from `base` in place."""
    if not isinstance(base, dict) or not isinstance(spec, dict):
        return
    for key, sval in spec.items():
        if key.startswith("_") or key not in base:
            continue
        cur = base[key]
        if isinstance(cur, dict) and isinstance(sval, dict):
            retire(cur, sval)
        elif isinstance(cur, dict) and isinstance(sval, list):
            for k in sval:
                cur.pop(k, None)
        elif isinstance(cur, list) and isinstance(sval, list):
            base[key] = [item for item in cur if item not in sval]


def load_object(path):
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("%s is not a JSON object" % path)
    return data


def main():
    if len(sys.argv) not in (3, 4):
        sys.stderr.write("usage: merge-settings.py <managed.json> <target.json> [retired.json]\n")
        return 2
    managed_path, target_path = sys.argv[1], sys.argv[2]
    retired_path = sys.argv[3] if len(sys.argv) == 4 else None

    managed = load_object(managed_path)
    retired = load_object(retired_path) if retired_path and os.path.exists(retired_path) else {}

    # Load the user's current settings; tolerate missing/empty/corrupt by
    # starting from {} (managed becomes the whole file, same as a fresh box).
    try:
        current = load_object(target_path)
    except (FileNotFoundError, ValueError):
        current = {}

    retire(current, retired)
    merged = merge(current, managed)

    # Write atomically-ish: temp file in the same dir, then replace.
    tmp = target_path + ".merge.tmp"
    with open(tmp, "w") as f:
        json.dump(merged, f, indent=2)
        f.write("\n")
    os.replace(tmp, target_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
