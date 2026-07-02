#!/usr/bin/env python3
"""AWS WickrGov notification tracker -- enables *Wickr-only* badge cleanup.

Background
----------
Dash-to-Dock's red count on the Wickr icon is the number of AWS WickrGov desktop
notifications still sitting in GNOME's notification list. Wickr never withdraws them
when you read the message in-app, so they pile up. GNOME exposes NO API to enumerate
notifications, so the only way to close *only* Wickr's (without nuking every app's
notifications) is to observe them as they are created.

This daemon becomes a passive D-Bus monitor of org.freedesktop.Notifications and keeps
a live set of open Wickr notification ids:
  * a Notify from Wickr  -> record the id the server returns
  * a NotificationClosed -> drop that id
On SIGUSR1 it calls CloseNotification() for exactly those ids (and nothing else), which
removes them from the list and resets the dock badge to 0.

Limitation: it can only clear notifications it actually saw, so run it from login
(the systemd --user service does that). Notifications that arrived before it started
aren't tracked -- use the clear-all script (clear-notifications) once to mop those up.

Usage:
    wickr-notify-daemon.py              # run in the foreground (systemd runs it this way)
    wickr-notify-daemon.py --self-test  # prove capture+close works, then exit
Trigger a clear from another process with:  kill -USR1 <pid>   (or `clear-wickr`)
"""
import os
import signal
import sys

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NBUS = "org.freedesktop.Notifications"
NPATH = "/org/freedesktop/Notifications"
NIFACE = "org.freedesktop.Notifications"


def _resolve_close_bus(conn):
    """Pick the server to send CloseNotification to.

    GNOME 45+ fronts the public `org.freedesktop.Notifications` name with a sandboxing
    proxy that REJECTS closing a notification created by a different D-Bus sender -- so
    this daemon (a different sender than Wickr) cannot close Wickr's notifications there.
    The real in-shell server owns `org.gnome.Shell` on the same object path and enforces
    no such check, so prefer it. Fall back to the public name on older GNOME (no proxy)."""
    try:
        res = conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                             "org.freedesktop.DBus", "NameHasOwner",
                             GLib.Variant("(s)", ("org.gnome.Shell",)),
                             GLib.VariantType("(b)"), Gio.DBusCallFlags.NONE, 3000, None)
        if res.unpack()[0]:
            return "org.gnome.Shell"
    except GLib.Error:
        pass
    return NBUS


def _looks_like_wickr(app_name, hints):
    if app_name and "wickr" in app_name.lower():
        return True
    if hints:
        de = hints.get("desktop-entry")
        if de and "wickr" in str(de).lower():
            return True
    return False


def send_notify(conn, app_name, summary="", body="", hints=None, timeout_ms=5000):
    hv = {}
    for k, v in (hints or {}).items():
        hv[k] = v if isinstance(v, GLib.Variant) else GLib.Variant("s", str(v))
    args = GLib.Variant("(susssasa{sv}i)",
                        (app_name, 0, "", summary, body, [], hv, timeout_ms))
    res = conn.call_sync(NBUS, NPATH, NIFACE, "Notify", args,
                         GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 3000, None)
    return res.unpack()[0]


class WickrNotifyDaemon:
    def __init__(self, verbose=True):
        self.verbose = verbose
        self.open_ids = set()
        self._pending_serials = set()  # Wickr Notify calls awaiting their return id

        # A normal (shared) connection used to SEND CloseNotification.
        self.action = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        # Which server accepts our (third-party) CloseNotification -- see _resolve_close_bus.
        self.close_bus = _resolve_close_bus(self.action)

        # A dedicated PRIVATE connection turned into a bus monitor. Must be separate:
        # a monitor connection is receive-only and can't be reused for method calls.
        addr = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
        self.mon = Gio.DBusConnection.new_for_address_sync(
            addr,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT
            | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        # NOTE: match rules must be catch-all ([]). A rule like interface='...Notifications'
        # would match the Notify *call* and the NotificationClosed *signal*, but a method
        # *return* carries no interface field, so the reply holding the assigned id would be
        # filtered out and we'd never learn the id. We instead see every message and
        # correlate a return's reply_serial back to a pending Wickr Notify call in code.
        self.mon.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus.Monitoring", "BecomeMonitor",
            GLib.Variant("(asu)", ([], 0)),
            None, Gio.DBusCallFlags.NONE, -1, None)
        self.mon.add_filter(self._filter)

    def _log(self, msg):
        if self.verbose:
            print(f"[wickr-notify-daemon] {msg}", flush=True)

    def _filter(self, conn, message, incoming):
        try:
            mtype = message.get_message_type()
            iface = message.get_interface()
            member = message.get_member()
            if mtype == Gio.DBusMessageType.METHOD_CALL and iface == NIFACE and member == "Notify":
                body = message.get_body()
                if body is not None:
                    vals = body.unpack()
                    app_name = vals[0] if len(vals) > 0 else ""
                    hints = vals[6] if len(vals) > 6 else {}
                    if _looks_like_wickr(app_name, hints):
                        self._pending_serials.add(message.get_serial())
            elif mtype == Gio.DBusMessageType.METHOD_RETURN:
                rs = message.get_reply_serial()
                if rs in self._pending_serials:
                    self._pending_serials.discard(rs)
                    body = message.get_body()
                    if body is not None:
                        nid = int(body.unpack()[0])
                        self.open_ids.add(nid)
                        self._log(f"tracking Wickr notification id={nid} (open={len(self.open_ids)})")
            elif mtype == Gio.DBusMessageType.SIGNAL and iface == NIFACE and member == "NotificationClosed":
                body = message.get_body()
                if body is not None:
                    nid = int(body.unpack()[0])
                    self.open_ids.discard(nid)
        except Exception as e:  # never let a filter error kill the daemon
            self._log(f"filter error: {e!r}")
        return None  # monitor: inspect and drop

    def clear(self):
        ids = sorted(self.open_ids)
        for nid in ids:
            try:
                self.action.call_sync(self.close_bus, NPATH, NIFACE, "CloseNotification",
                                      GLib.Variant("(u)", (nid,)), None,
                                      Gio.DBusCallFlags.NONE, 3000, None)
            except GLib.Error:
                pass
        self.open_ids.clear()
        self._log(f"cleared {len(ids)} Wickr notification(s) via {self.close_bus}")
        return len(ids)


def _run_self_test():
    daemon = WickrNotifyDaemon(verbose=True)
    loop = GLib.MainLoop()
    state = {}

    def send():
        state["sent"] = send_notify(
            daemon.action, "AWS WickrGov (self-test)", "self-test", "safe to ignore",
            hints={"desktop-entry": "awswickrgov"})
        print(f"[self-test] sent Wickr-like notification id={state['sent']}", flush=True)
        return False

    def other():
        # a NON-Wickr notification that must NOT be tracked/cleared
        state["other"] = send_notify(daemon.action, "SomeOtherApp", "unrelated", "keep me")
        print(f"[self-test] sent non-Wickr notification id={state['other']}", flush=True)
        return False

    def check_and_clear():
        state["tracked"] = set(daemon.open_ids)
        state["cleared"] = daemon.clear()
        return False

    def verdict():
        wickr_tracked = state.get("sent") in state.get("tracked", set())
        other_ignored = state.get("other") not in state.get("tracked", set())
        cleared_ok = state.get("cleared", 0) >= 1
        ok = wickr_tracked and other_ignored and cleared_ok
        print(f"[self-test] wickr_tracked={wickr_tracked} other_ignored={other_ignored} "
              f"cleared={state.get('cleared')} tracked={sorted(state.get('tracked', []))}", flush=True)
        print(f"SELF-TEST: {'PASS' if ok else 'FAIL'}", flush=True)
        # tidy up the stray non-Wickr test notification we created
        try:
            daemon.action.call_sync(daemon.close_bus, NPATH, NIFACE, "CloseNotification",
                                    GLib.Variant("(u)", (state.get("other", 0),)),
                                    None, Gio.DBusCallFlags.NONE, 2000, None)
        except GLib.Error:
            pass
        loop.quit()
        return False

    GLib.timeout_add(200, send)
    GLib.timeout_add(500, other)
    GLib.timeout_add(1000, check_and_clear)
    GLib.timeout_add(1400, verdict)
    loop.run()


def main():
    if "--self-test" in sys.argv[1:]:
        _run_self_test()
        return
    daemon = WickrNotifyDaemon(verbose=True)
    loop = GLib.MainLoop()
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1,
                         lambda: (daemon.clear(), True)[1])
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM,
                         lambda: (loop.quit(), False)[1])
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT,
                         lambda: (loop.quit(), False)[1])
    daemon._log(f"running (pid {os.getpid()}); send SIGUSR1 (or run `clear-wickr`) to clear")
    loop.run()


if __name__ == "__main__":
    main()
