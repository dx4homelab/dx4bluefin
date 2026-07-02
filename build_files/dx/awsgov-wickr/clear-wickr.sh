#!/usr/bin/env bash
# Tell the Wickr-only tracker daemon to close just AWS WickrGov's notifications.
# Installed as ~/.local/bin/clear-wickr and (optionally) bound to a hotkey.
set -uo pipefail
SERVICE="awsgov-wickr-notify.service"

if systemctl --user is-active --quiet "$SERVICE" 2>/dev/null; then
    if systemctl --user kill -s SIGUSR1 "$SERVICE" 2>/dev/null; then
        echo "clear-wickr: signaled $SERVICE"
        exit 0
    fi
fi

# Fallback: a manually-started daemon (matches the script name, not this trigger).
pid="$(pgrep -f 'awsgov-wickr-notify-daemon' | head -n1 || true)"
if [ -n "${pid:-}" ]; then
    kill -USR1 "$pid" && echo "clear-wickr: signaled pid $pid"
    exit 0
fi

echo "clear-wickr: daemon not running." >&2
echo "  start it:        systemctl --user start $SERVICE" >&2
echo "  enable at login: systemctl --user enable --now $SERVICE" >&2
echo "  fallback (clears ALL notifications): clear-notifications" >&2
exit 1
