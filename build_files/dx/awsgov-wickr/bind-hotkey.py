#!/usr/bin/env python3
"""Idempotently manage a GNOME custom keyboard shortcut for this toolset.

Bind:    bind-hotkey.py --command CMD --name NAME --binding '<Super><Shift>c'
Unbind:  bind-hotkey.py --unbind CMD

Bind reuse rules (so re-runs never duplicate or leave conflicting bindings):
  1. reuse the slot already pointing at CMD;
  2. else, if a slot already uses BINDING and belongs to this toolset, repoint it
     (this is how install-daemon.sh "upgrades" the clear-all key to Wickr-only);
  3. else allocate a fresh custom slot.
A foreign binding collision is warned about, not silently clobbered.
"""
import argparse
import ast
import os
import subprocess

SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
CBASE = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/"
CBSCH = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
OURS = {"clear-notifications", "clear-wickr"}


def gget(schema, key, path=None):
    tgt = f"{schema}:{path}" if path else schema
    return subprocess.check_output(["gsettings", "get", tgt, key], text=True).strip()


def gset(schema, key, value, path=None):
    tgt = f"{schema}:{path}" if path else schema
    subprocess.check_call(["gsettings", "set", tgt, key, value])


def slot_prop(path, key):
    try:
        return ast.literal_eval(gget(CBSCH, key, path))
    except Exception:
        return None


def current_slots():
    raw = gget(SCHEMA, "custom-keybindings")
    return ast.literal_eval(raw) if raw.startswith("[") else []


def do_bind(command, name, binding):
    cur = current_slots()
    slot, action = None, ""

    for p in cur:  # 1) reuse by command
        if slot_prop(p, "command") == command:
            slot, action = p, "updated existing slot for this command"
            break
    if slot is None:  # 2) repoint one of ours that owns the binding
        for p in cur:
            b = slot_prop(p, "binding")
            if b and b.lower() == binding.lower():
                c = slot_prop(p, "command") or ""
                if os.path.basename(str(c)) in OURS:
                    slot, action = p, f"repointed {binding} from '{c}'"
                    break
                print(f"WARNING: {binding} is already bound to '{c}'. "
                      f"Adding a second binding; consider changing one.")
    if slot is None:  # 3) new slot
        i = 0
        while f"{CBASE}custom{i}/" in cur:
            i += 1
        slot = f"{CBASE}custom{i}/"
        cur.append(slot)
        gset(SCHEMA, "custom-keybindings", str(cur))
        action = "created new slot"

    gset(CBSCH, "name", name, slot)
    gset(CBSCH, "command", command, slot)
    gset(CBSCH, "binding", binding, slot)
    print(f"bound {binding} -> {command}  ({action}; {slot})")


def do_unbind(command):
    cur = current_slots()
    keep, removed = [], []
    for p in cur:
        if slot_prop(p, "command") == command:
            removed.append(p)
        else:
            keep.append(p)
    if not removed:
        print(f"no keybinding slot pointed at {command}")
        return
    gset(SCHEMA, "custom-keybindings", str(keep))
    print(f"removed {len(removed)} keybinding slot(s) for {command}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--command")
    ap.add_argument("--name")
    ap.add_argument("--binding")
    ap.add_argument("--unbind", metavar="CMD")
    a = ap.parse_args()
    if a.unbind:
        do_unbind(a.unbind)
    else:
        if not (a.command and a.name and a.binding):
            ap.error("--command, --name and --binding are required to bind")
        do_bind(a.command, a.name, a.binding)


if __name__ == "__main__":
    main()
