#!/usr/bin/bash
# dx4homelab: bake the awsgov-wickr AWS WickrGov dock-badge fix into the image.
#
#   - awsgov-wickr-notify.service  : systemd --user daemon, enabled image-wide; tracks the
#                                    ids of AWS WickrGov notifications as they are posted.
#   - clear-wickr                  : close ONLY the tracked Wickr notifications  (Alt+W)
#   - clear-notifications          : hard clear ALL apps' notifications         (Alt+Shift+W)
#
# Both closers target the internal `org.gnome.Shell` notification server, which — unlike the
# public `org.freedesktop.Notifications` proxy on GNOME 45+ — does not reject closing another
# sender's notifications. The Alt+W / Alt+Shift+W keybindings are bound per user by the
# user-setup hook 30-awsgov-wickr.sh (installed below).
#
# Source of truth lives in mods/awsgov-wickr/ and is staged to /ctx/build_files/dx/awsgov-wickr/
# by customize-build.py (EXTRA_FILE_COPIES); this script is chained after 02-dod-ca-trust.sh
# via LINE_MODS.
set -xeuo pipefail

SRC=/ctx/build_files/dx/awsgov-wickr

# The daemon needs PyGObject (gi / Gio / GLib). Present in the GNOME base already; pin it so a
# future base change can't silently drop it. Guarded so we don't hit dnf when it's already there.
rpm -q python3-gobject-base >/dev/null 2>&1 || dnf -y install python3-gobject-base

# --- binaries ---
install -Dm0755 "$SRC/wickr-notify-daemon.py" /usr/libexec/awsgov-wickr/awsgov-wickr-notify-daemon
install -Dm0755 "$SRC/bind-hotkey.py"         /usr/libexec/awsgov-wickr/bind-hotkey.py
install -Dm0755 "$SRC/clear-wickr.sh"         /usr/bin/clear-wickr
install -Dm0755 "$SRC/clear-notifications.py" /usr/bin/clear-notifications

# --- systemd --user unit, enabled for every user (reaches the pre-existing primary user;
#     etc/skel and presets do not) ---
install -Dm0644 "$SRC/awsgov-wickr-notify.service" /usr/lib/systemd/user/awsgov-wickr-notify.service
systemctl --global enable awsgov-wickr-notify.service

# --- per-user first-login hook: binds Alt+W and Alt+Shift+W ---
install -Dm0755 "$SRC/30-awsgov-wickr.sh" /usr/share/ublue-os/user-setup.hooks.d/30-awsgov-wickr.sh

# --- build-time gates (static only; a session bus / GNOME is not available in the build
#     container, so functional capture+close and "key fires" are verified at runtime) ---
test -x /usr/bin/clear-wickr
test -x /usr/bin/clear-notifications
test -x /usr/libexec/awsgov-wickr/awsgov-wickr-notify-daemon
# the daemon's runtime import must resolve inside the image
python3 -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio, GLib'
# parse (do NOT py_compile — avoid writing __pycache__/*.pyc into /usr that lint may flag)
python3 - /usr/libexec/awsgov-wickr/awsgov-wickr-notify-daemon \
           /usr/libexec/awsgov-wickr/bind-hotkey.py \
           /usr/bin/clear-notifications <<'PY'
import ast, sys
for p in sys.argv[1:]:
    ast.parse(open(p, encoding="utf-8").read())
PY
bash -n /usr/bin/clear-wickr
bash -n /usr/share/ublue-os/user-setup.hooks.d/30-awsgov-wickr.sh
systemctl --global is-enabled awsgov-wickr-notify.service | grep -qx enabled
systemd-analyze verify /usr/lib/systemd/user/awsgov-wickr-notify.service || true

echo "awsgov-wickr: baked (daemon enabled image-wide; Alt+W / Alt+Shift+W bound per user at login)"
