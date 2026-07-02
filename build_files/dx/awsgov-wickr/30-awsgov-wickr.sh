#!/usr/bin/env bash
# dx4homelab per-user first-login hook: bind the two notification-clear hotkeys for the
# AWS WickrGov dock-badge fix. Runs in the user session (has dconf/D-Bus), so it configures
# the pre-existing primary user too. bind-hotkey.py MERGES into the custom-keybindings array
# (reuses its own slot, never clobbers foreign shortcuts) — unlike a dconf-db default, which
# GNOME would silently overwrite the first time the user edits any shortcut.
#
# Bump the version integer below to force a re-apply on an image update.
source /usr/lib/ublue/setup-services/libsetup.sh

version-script awsgov-wickr user 1 || exit 0

set -euo pipefail

BIND=/usr/libexec/awsgov-wickr/bind-hotkey.py

if command -v gsettings >/dev/null 2>&1 && [ -x "$BIND" ]; then
    # Alt+W  -> Wickr-only clear (daemon closes only the notifications it tracked)
    python3 "$BIND" \
        --command /usr/bin/clear-wickr \
        --name "Clear AWS WickrGov notifications" \
        --binding '<Alt>w' || true
    # Alt+Shift+W -> hard clear ALL apps' notifications
    python3 "$BIND" \
        --command /usr/bin/clear-notifications \
        --name "Clear ALL notifications (hard clear)" \
        --binding '<Alt><Shift>w' || true
fi
