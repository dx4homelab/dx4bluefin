#!/usr/bin/env python3
"""Reset the Dash-to-Dock per-app unread badge (e.g. AWS WickrGov's stale count) by
clearing GNOME's notification list -- the same effect as the notification shade's
"Clear" button.

Why this and not a "LauncherEntry count=0" trick: Dash-to-Dock v105 draws that red
number from `show-icons-notifications-counter`, which counts the notifications an app
still has in Main.messageTray. Wickr posts a desktop notification per message and never
withdraws them when you read the message in-app, so they pile up. Removing them resets
the badge. Wickr does NOT use the com.canonical.Unity.LauncherEntry API at all.

GNOME's notification server exposes no "list" method, so we (1) probe the current
notification-id ceiling with a silent transient dummy, then (2) CloseNotification for
every id up to it. Closing an absent/already-closed id is a harmless no-op.

CRITICAL (GNOME 45+): the public `org.freedesktop.Notifications` name is owned by a
sandboxing proxy (`org.gnome.Shell.Notifications`) that REJECTS CloseNotification for any
id created by a *different* D-Bus sender -- silently (the call just returns OK and does
nothing). So closing another app's (Wickr's) notifications via the public name is
impossible while that app is running. We therefore send CloseNotification straight to the
REAL in-shell server, well-known name `org.gnome.Shell` on the same object path, which
does NOT enforce sender ownership. The id space is shared, so probing via the public
Notify still yields valid ids. On older GNOME (no proxy) we fall back to the public name.

LIMITATION: this clears notifications from ALL apps, not only Wickr -- GNOME provides no
public API to enumerate or target one app's already-delivered notifications. For
Wickr-only clearing, use the daemon (install-daemon.sh) instead.

Usage:
    clear-notifications            # clear the notification list (resets the badge)
    clear-notifications --test     # probe only: prove the D-Bus path works, clear nothing
"""
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

PUBLIC_BUS = "org.freedesktop.Notifications"  # public name (sandboxing proxy on GNOME 45+)
SHELL_BUS = "org.gnome.Shell"                 # real in-shell server, no sender-ownership check
PATH = "/org/freedesktop/Notifications"
IFACE = "org.freedesktop.Notifications"

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def _name_has_owner(name):
    try:
        res = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                            "org.freedesktop.DBus", "NameHasOwner",
                            GLib.Variant("(s)", (name,)), GLib.VariantType("(b)"),
                            Gio.DBusCallFlags.NONE, 3000, None)
        return res.unpack()[0]
    except GLib.Error:
        return False


# Close on the in-shell server if present (bypasses the ownership-enforcing proxy),
# else the public name (older GNOME, where it IS the shell and imposes no such check).
CLOSE_BUS = SHELL_BUS if _name_has_owner(SHELL_BUS) else PUBLIC_BUS


def probe_ceiling():
    """Post a silent, transient, instantly-expiring dummy; its returned id is the
    current id ceiling."""
    hints = {
        "transient": GLib.Variant("b", True),
        "suppress-sound": GLib.Variant("b", True),
        "urgency": GLib.Variant("y", 0),
    }
    args = GLib.Variant("(susssasa{sv}i)", ("", 0, "", "", "", [], hints, 1))
    res = bus.call_sync(PUBLIC_BUS, PATH, IFACE, "Notify", args,
                        GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 3000, None)
    return res.unpack()[0]


def close(nid):
    try:
        bus.call_sync(CLOSE_BUS, PATH, IFACE, "CloseNotification",
                      GLib.Variant("(u)", (nid,)),
                      None, Gio.DBusCallFlags.NONE, 3000, None)
        return True
    except GLib.Error:
        return False  # unknown/closed id -> fine


def main():
    test = "--test" in sys.argv[1:]
    ceiling = probe_ceiling()
    close(ceiling)  # always remove our own dummy
    if test:
        print(f"[test] OK. Notify works; CloseNotification target = {CLOSE_BUS}. "
              f"Current id ceiling = {ceiling}. (No real notifications were cleared.)")
        return
    for nid in range(1, ceiling):
        close(nid)
    # Note: GNOME's CloseNotification returns OK even for absent ids, so we can't report a
    # meaningful "removed N" count here; the badge is the source of truth.
    print(f"Requested close of notification ids 1..{ceiling} via {CLOSE_BUS}. "
          f"The Wickr dock badge should now read 0.")


if __name__ == "__main__":
    main()
