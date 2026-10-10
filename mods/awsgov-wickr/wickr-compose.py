#!/usr/bin/env python3
"""wickr-compose -- a local "compose box" for AWS WickrGov (or any chat app).

Write the message here, then Ctrl+Enter copies it and hides the window; paste it into
Wickr with Ctrl+V. Everything stays on this machine:
  * spelling  -- libspelling (hunspell/enchant) red underlines + right-click suggestions
  * grammar   -- a LOCAL LanguageTool server (`ujust setup-languagetool`), blue underlines
                 + a clickable list of fixes; checked automatically after a typing pause
  * dictation -- mic button records with pw-record and transcribes on a LOCAL whisper.cpp
                 server (/inference)
Text is never written to disk. Grammar/dictation refuse non-loopback URLs unless
allow_remote = true. The copied text is owned by this process and disappears from the
clipboard when it exits (clear_clipboard_seconds after the copy, unless you copied
something else meanwhile). Esc hides the window and keeps the draft for draft_keep_seconds.

Config (optional): ~/.config/wickr-compose/config.ini -- see DEFAULTS below.
    wickr-compose               # open (or re-show) the composer
    wickr-compose --self-test   # check imports + local services, no GUI
"""
import configparser
import ipaddress
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("GtkSource", "5")
gi.require_version("Spelling", "1")
from gi.repository import Adw, Gdk, GLib, Gtk, GtkSource, Pango, Spelling  # noqa: E402

APP_ID = "io.github.dx4homelab.WickrCompose"
DEFAULTS = {
    "languagetool": {"url": "http://127.0.0.1:8010", "language": "en-US",
                     "auto_check": "true", "allow_remote": "false"},
    "whisper": {"url": "http://127.0.0.1:8089/inference", "language": "en",
                "allow_remote": "false"},
    "send": {"clear_clipboard_seconds": "120", "draft_keep_seconds": "300",
             "auto_paste": "false"},
}


def load_config():
    cfg = configparser.ConfigParser()
    cfg.read_dict(DEFAULTS)
    cfg.read(os.path.join(GLib.get_user_config_dir(), "wickr-compose", "config.ini"))
    return cfg


def url_allowed(url, allow_remote):
    """Message text and voice must not leave the machine by accident."""
    if allow_remote:
        return True
    host = urllib.parse.urlsplit(url).hostname or ""
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def http(url, data=None, headers=None, timeout=30):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def lt_check(cfg, text):
    """LanguageTool /v2/check -> list of (start, end, message, [replacements]) in code points."""
    lt = cfg["languagetool"]
    body = urllib.parse.urlencode({"text": text, "language": lt["language"]}).encode()
    res = json.loads(http(lt["url"].rstrip("/") + "/v2/check", body, timeout=15))
    # LanguageTool offsets are Java UTF-16 units; GtkTextBuffer offsets are code points.
    u16 = []
    for i, ch in enumerate(text):
        u16 += [i, i] if ord(ch) > 0xFFFF else [i]
    u16.append(len(text))
    out = []
    for m in res.get("matches", []):
        a, b = m["offset"], m["offset"] + m["length"]
        if b >= len(u16):
            continue
        out.append((u16[a], u16[b], m["message"], [r["value"] for r in m["replacements"][:4]]))
    return out


def whisper_transcribe(cfg, wav_path):
    w = cfg["whisper"]
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in (("response_format", "json"), ("language", w["language"])):
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'
                     f"{value}\r\n".encode())
    with open(wav_path, "rb") as f:
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
                     f'filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode()
                     + f.read() + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    res = json.loads(http(w["url"], b"".join(parts),
                          {"Content-Type": f"multipart/form-data; boundary={boundary}"},
                          timeout=120))
    # whisper marks non-speech as [BLANK_AUDIO], [Music], ...
    return re.sub(r"\s+", " ", re.sub(r"\[[^\]]*\]", "", res.get("text", ""))).strip()


def probe(url, allow_remote):
    """'' if usable, else a human-readable reason."""
    if not url_allowed(url, allow_remote):
        return f"{url} is not on this machine (set allow_remote = true to permit)"
    p = urllib.parse.urlsplit(url)
    try:
        http(f"{p.scheme}://{p.netloc}/", timeout=2)
    except urllib.error.HTTPError:
        pass  # server answered -> reachable
    except Exception as e:  # noqa: BLE001
        return f"not reachable at {p.netloc} ({getattr(e, 'reason', e)})"
    return ""


class Composer(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        self.cfg = load_config()
        self.win = None
        self._park_id = 0
        self._check_id = 0
        self._gen = 0
        self._rec = None
        self._rec_path = None
        self.lt_ok = self.whisper_ok = False

    # ---------- UI ----------
    def do_activate(self):
        if self._park_id:
            GLib.source_remove(self._park_id)
            self._park_id = 0
            self.release()
        if self.win is None:
            self._build()
        self.win.present()
        self.view.grab_focus()

    def _build(self):
        self.win = Adw.ApplicationWindow(application=self, title="Compose for Wickr",
                                         default_width=620, default_height=380)
        self.win.connect("close-request", lambda *_: self._hide() or True)

        self.buf = GtkSource.Buffer()
        self.view = GtkSource.View(buffer=self.buf, wrap_mode=Gtk.WrapMode.WORD_CHAR,
                                   top_margin=12, bottom_margin=12, left_margin=12,
                                   right_margin=12, vexpand=True)
        adapter = Spelling.TextBufferAdapter.new(self.buf, Spelling.Checker.get_default())
        self.view.set_extra_menu(adapter.get_menu_model())
        self.view.insert_action_group("spelling", adapter)
        adapter.set_enabled(True)
        self._spelling = adapter  # keep a reference
        blue = Gdk.RGBA()
        blue.parse("#3584e4")
        self.gtag = self.buf.create_tag("grammar", underline=Pango.Underline.ERROR,
                                        underline_rgba=blue)
        self.buf.connect("changed", self._on_changed)

        self.issues = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.issues.add_css_class("boxed-list")
        self.issues.connect("row-activated", self._on_issue_activated)
        issues_sw = Gtk.ScrolledWindow(child=self.issues, max_content_height=150,
                                       propagate_natural_height=True,
                                       margin_start=12, margin_end=12, margin_bottom=6)
        self.reveal = Gtk.Revealer(child=issues_sw)

        hint = Gtk.Label(label="Ctrl+Enter copy & hide · Ctrl+G grammar · Ctrl+M dictate"
                               " · Esc hide (draft kept)", margin_bottom=6)
        hint.add_css_class("dim-label")
        hint.add_css_class("caption")

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(Gtk.ScrolledWindow(child=self.view, vexpand=True))
        box.append(self.reveal)
        box.append(hint)
        self.toasts = Adw.ToastOverlay(child=box)

        header = Adw.HeaderBar()
        self.mic = Gtk.ToggleButton(icon_name="audio-input-microphone-symbolic",
                                    sensitive=False, tooltip_text="Dictation: checking…")
        self.mic.connect("toggled", self._on_mic)
        self.gbtn = Gtk.Button(icon_name="tools-check-spelling-symbolic", sensitive=False,
                               tooltip_text="Grammar: checking…")
        self.gbtn.connect("clicked", lambda *_: self._check_now())
        send = Gtk.Button(label="Copy & Hide")
        send.add_css_class("suggested-action")
        send.connect("clicked", lambda *_: self._send())
        header.pack_start(self.mic)
        header.pack_start(self.gbtn)
        header.pack_end(send)

        tv = Adw.ToolbarView(content=self.toasts)
        tv.add_top_bar(header)
        self.win.set_content(tv)

        keys = Gtk.ShortcutController(propagation_phase=Gtk.PropagationPhase.CAPTURE)
        for trigger, cb in (("<Control>Return", self._send), ("<Control>KP_Enter", self._send),
                            ("<Control>g", self._check_now), ("Escape", self._hide),
                            ("<Control>m", lambda: self.mic.get_sensitive()
                             and self.mic.set_active(not self.mic.get_active()))):
            keys.add_shortcut(Gtk.Shortcut(trigger=Gtk.ShortcutTrigger.parse_string(trigger),
                                           action=Gtk.CallbackAction.new(
                                               lambda *_a, cb=cb: cb() or True)))
        self.win.add_controller(keys)
        threading.Thread(target=self._probe, daemon=True).start()

    def toast(self, msg):
        self.toasts.add_toast(Adw.Toast(title=GLib.markup_escape_text(msg), timeout=4))

    def _probe(self):
        lt, w = self.cfg["languagetool"], self.cfg["whisper"]
        lt_err = probe(lt["url"], lt.getboolean("allow_remote"))
        w_err = probe(w["url"], w.getboolean("allow_remote"))
        if not w_err and not shutil.which("pw-record"):
            w_err = "pw-record not installed"
        GLib.idle_add(self._probed, lt_err, w_err)

    def _probed(self, lt_err, w_err):
        self.lt_ok, self.whisper_ok = not lt_err, not w_err
        self.gbtn.set_sensitive(self.lt_ok)
        self.gbtn.set_tooltip_text("Check grammar (Ctrl+G)" if self.lt_ok else
                                   f"Grammar off: LanguageTool {lt_err}. "
                                   "Set it up with: ujust setup-languagetool")
        self.mic.set_sensitive(self.whisper_ok)
        self.mic.set_tooltip_text("Dictate (Ctrl+M): click to start, click to stop"
                                  if self.whisper_ok else f"Dictation off: whisper {w_err}")
        if self.lt_ok and self.buf.get_char_count():
            self._schedule_check(100)

    # ---------- grammar ----------
    def _text(self):
        return self.buf.get_text(self.buf.get_start_iter(), self.buf.get_end_iter(), True)

    def _on_changed(self, *_):
        self._gen += 1
        self.buf.remove_tag(self.gtag, self.buf.get_start_iter(), self.buf.get_end_iter())
        self.reveal.set_reveal_child(False)
        if self.lt_ok and self.cfg["languagetool"].getboolean("auto_check"):
            self._schedule_check(1200)

    def _schedule_check(self, ms):
        if self._check_id:
            GLib.source_remove(self._check_id)
        self._check_id = GLib.timeout_add(ms, self._check_now)

    def _check_now(self):
        self._check_id = 0
        text, gen = self._text(), self._gen
        if self.lt_ok and text.strip():
            threading.Thread(target=self._check_worker, args=(text, gen), daemon=True).start()
        return GLib.SOURCE_REMOVE

    def _check_worker(self, text, gen):
        try:
            matches, err = lt_check(self.cfg, text), None
        except Exception as e:  # noqa: BLE001
            matches, err = [], str(e)
        GLib.idle_add(self._show_issues, text, gen, matches, err)

    def _show_issues(self, text, gen, matches, err):
        if gen != self._gen:
            return  # text changed while LanguageTool was working; a newer check is queued
        if err:
            self.toast(f"Grammar check failed: {err}")
            return
        while (row := self.issues.get_row_at_index(0)) is not None:
            self.issues.remove(row)
        for start, end, msg, reps in matches:
            self.buf.apply_tag(self.gtag, self.buf.get_iter_at_offset(start),
                               self.buf.get_iter_at_offset(end))
            orig = text[start:end]
            row_box = Gtk.Box(spacing=6, margin_top=6, margin_bottom=6,
                              margin_start=8, margin_end=8)
            lbl = Gtk.Label(label=f"“{orig}” — {msg}", wrap=True, xalign=0, hexpand=True)
            row_box.append(lbl)
            for rep in reps:
                b = Gtk.Button(label=rep or "∅", valign=Gtk.Align.CENTER)
                b.add_css_class("flat")
                b.connect("clicked", lambda _b, s=start, e=end, o=orig, r=rep, g=gen:
                          self._apply(s, e, o, r, g))
                row_box.append(b)
            row = Gtk.ListBoxRow(child=row_box)
            row.span = (start, end)
            self.issues.append(row)
        self.reveal.set_reveal_child(bool(matches))

    def _on_issue_activated(self, _lb, row):
        s, e = row.span
        self.buf.select_range(self.buf.get_iter_at_offset(s), self.buf.get_iter_at_offset(e))
        self.view.grab_focus()

    def _apply(self, start, end, orig, rep, gen):
        s, e = self.buf.get_iter_at_offset(start), self.buf.get_iter_at_offset(end)
        if gen != self._gen or self.buf.get_text(s, e, True) != orig:
            return
        self.buf.begin_user_action()
        self.buf.delete(s, e)
        self.buf.insert(s, rep)
        self.buf.end_user_action()
        self._schedule_check(150)

    # ---------- dictation ----------
    def _on_mic(self, btn):
        if btn.get_active():
            fd, self._rec_path = tempfile.mkstemp(suffix=".wav", prefix="wickr-compose-",
                                                  dir=GLib.get_user_runtime_dir())
            os.close(fd)
            self._rec = subprocess.Popen(
                ["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16",
                 self._rec_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            btn.add_css_class("destructive-action")
            return
        btn.remove_css_class("destructive-action")
        rec, path, self._rec = self._rec, self._rec_path, None
        if rec is None:
            return
        rec.send_signal(signal.SIGINT)
        try:
            rec.wait(timeout=3)
        except subprocess.TimeoutExpired:
            rec.kill()
        if os.path.getsize(path) < 44 + 16000 * 2 // 2:  # < 0.5 s of audio
            os.unlink(path)
            self.toast("Too short — hold the mic on a little longer")
            return
        btn.set_sensitive(False)
        self.toast("Transcribing…")
        threading.Thread(target=self._stt_worker, args=(path,), daemon=True).start()

    def _stt_worker(self, path):
        try:
            text, err = whisper_transcribe(self.cfg, path), None
        except Exception as e:  # noqa: BLE001
            text, err = "", str(e)
        finally:
            os.unlink(path)
        GLib.idle_add(self._insert_dictation, text, err)

    def _insert_dictation(self, text, err):
        self.mic.set_sensitive(True)
        if err:
            self.toast(f"Dictation failed: {err}")
        elif not text:
            self.toast("No speech recognised")
        else:
            pos = self.buf.get_iter_at_mark(self.buf.get_insert()).get_offset()
            if pos and not self.buf.get_iter_at_offset(pos - 1).get_char().isspace():
                text = " " + text
            self.buf.insert_at_cursor(text)
        self.view.grab_focus()

    # ---------- send / hide ----------
    def _park(self, seconds, then):
        """Hide but stay alive (owning the clipboard / holding the draft) for `seconds`."""
        self.win.set_visible(False)
        if self._park_id:
            GLib.source_remove(self._park_id)
        else:
            self.hold()

        def expire():
            self._park_id = 0
            self.release()
            then()
            return GLib.SOURCE_REMOVE
        self._park_id = GLib.timeout_add_seconds(max(1, seconds), expire)

    def _hide(self):
        if self.mic.get_active():
            self.mic.set_active(False)
        if not self._text().strip():
            self.quit()
        else:
            self._park(self.cfg["send"].getint("draft_keep_seconds"), self.quit)

    def _send(self):
        text = self._text().strip()
        if not text:
            return self._hide()
        clip = self.win.get_clipboard()
        clip.set(text)
        self.buf.set_text("")
        snd = self.cfg["send"]
        self._park(snd.getint("clear_clipboard_seconds"), self.quit)  # exit drops the clip
        if snd.getboolean("auto_paste") and shutil.which("ydotool"):
            GLib.timeout_add(350, self._autopaste)

    def _autopaste(self):
        # Ctrl+V (evdev 29=LEFTCTRL, 47=V) into whatever regains focus; needs ydotoold.
        subprocess.Popen(["ydotool", "key", "29:1", "47:1", "47:0", "29:0"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return GLib.SOURCE_REMOVE


def self_test():
    cfg = load_config()
    print("imports: OK (Gtk 4, Adw 1, GtkSource 5, Spelling 1)")
    lt = cfg["languagetool"]
    err = probe(lt["url"], lt.getboolean("allow_remote"))
    if err:
        print(f"languagetool: OFF ({err})")
    else:
        m = lt_check(cfg, "This are a test with 😀 teh emoji.")
        print(f"languagetool: OK, {len(m)} issue(s): " +
              "; ".join(f"[{a}:{b}] {msg}" for a, b, msg, _ in m))
    w = cfg["whisper"]
    err = probe(w["url"], w.getboolean("allow_remote"))
    print(f"whisper: {'OFF (' + err + ')' if err else 'OK'}; "
          f"pw-record: {'OK' if shutil.which('pw-record') else 'missing'}")


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        self_test()
        sys.exit(0)
    sys.exit(Composer().run(sys.argv[:1]))
