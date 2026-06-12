# dx4homelab/bluefin readme

## this repo used to maintain all my desktops

## How changes are made here (the MODS pattern)

Everything outside `mods/` and `.github/` is **generated**. On any push touching
`mods/**` (and every Friday 07:00 UTC), `.github/workflows/mods.yml`:

1. wipes the tree and clones upstream `ublue-os/bluefin` `main` HEAD over it,
2. copies `mods/customize-build.py` to `build_files/mods/` and runs it with
   `--apply-defaults --write` (applies `ADDITION_LIST`, `REMOVAL_LIST`,
   `LINE_MODS`, `EXTRA_FILE_COPIES`, DNF exclusions),
3. commits the result and dispatches the `stable` and `latest` image builds.

> **Never fix only `build_files/`** — the next sync overwrites it. Make the
> change in `mods/customize-build.py`, `cp` it to `build_files/mods/`, and
> optionally hand-apply the same change to `build_files/` for immediate
> consistency. Note `reusable-build.yml` has `cancel-in-progress: true`: a
> push to `mods/**` cancels any in-flight image builds.

Verify a mods change before pushing by simulating CI locally:

```bash
git clone --depth 1 https://github.com/ublue-os/bluefin.git /tmp/sim && cd /tmp/sim
rm -rf mods && cp -r ~/workspaces/homelab/dx4bluefin/mods ./mods
mkdir -p build_files/mods && cp mods/customize-build.py build_files/mods/
python3 build_files/mods/customize-build.py --apply-defaults --write
find build_files -name '*.sh' -exec bash -n {} \;
diff -rq build_files ~/workspaces/homelab/dx4bluefin/build_files  # identical, modulo upstream drift
```

`apply_line_mods` is drift-hardened (since 2026-06-12): deletions are
all-or-nothing (each delete line must match exactly once, or none at all for
idempotent re-runs), and a missing anchor with pending insertions raises
instead of silently dropping the customization. A failed MODS run is the
signal that upstream changed and a `LINE_MODS` entry needs updating.

## Runbook: VS Code Wayland "Share Screen" popup

**Symptom:** on VS Code launch — or when a display sleeps/wakes
(`display-metrics-changed`, e.g. a TV turning off) — the xdg-desktop-portal
"Share Screen" picker pops up with no user action.

**History:** VS Code ≤ 1.122 eagerly warmed up screen sources at startup:
`warmUpScreenSources()` in `src/vs/code/electron-main/app.ts` called
`desktopCapturer.getSources({types:['screen'], thumbnailSize:{width:0,height:0}}).then(...)`,
which on Wayland routes through the portal. We patched this at build time with
a sed on the minified `main.js` (commit `50f1c93`, 2026-05-31). **Microsoft
removed the eager call in 1.123.0** — sources are now enumerated lazily inside
the on-demand screen-share handler — so the patch became a no-op and was
retired (commit `c3e78e7`, 2026-06-12).

**If it reappears:**

1. **Map the call sites** in the installed binary:

   ```bash
   python3 -c "
   import re
   src = open('/usr/share/code/resources/app/out/main.js', errors='replace').read()
   for m in re.finditer(r'getSources', src):
       print(f'@{m.start()}: ...{src[m.start()-60:m.start()]}[getSources]{src[m.end():m.end()+110]}...')"
   ```

2. **Classify each site** against the source at the matching tag:
   `https://raw.githubusercontent.com/microsoft/vscode/<version>/src/vs/code/electron-main/app.ts`.
   The eager/pre-warm call is fire-and-forget (typically ends in `.then(`, not
   `await`ed); the legitimate calls are `await`ed inside the screen-share
   handler (recognizable by the `getDisplayNearestPoint` /
   `find(...display_id...)` context). **Patch only the eager call** — touching
   the awaited ones breaks real screen sharing.

3. **Add the patch** as a `LINE_MODS` `add_after` entry in
   `mods/customize-build.py` for `build_files/dx/00-dx.sh`, anchored at the
   `code` line of the `dnf install` (insertions land right after the install
   command). The sed should rewrite that call's `types:["screen"]` to
   `types:[]`, with enough surrounding minified context to be unique.

4. **Guard positively** — assert the *replacement* took effect:

   ```bash
   grep -qF '<the NEW types:[] string with its unique context>' /usr/share/code/resources/app/out/main.js \
     || { echo "ERROR: VS Code pre-warm patch did not apply" >&2; exit 1; }
   ```

   Do **not** assert absence of the old string: that guard passes both when
   the patch applied *and* when upstream rewrote the code — a tautology, and
   exactly how the original patch died silently.

5. **Verify before pushing:** download the rpm CI will install
   (`https://packages.microsoft.com/yumrepos/vscode/Packages/c/code-<ver>.el8.x86_64.rpm`),
   extract `main.js` (`rpm2cpio code.rpm | cpio -idmv './usr/share/code/resources/app/out/main.js'`),
   run the sed on it, and confirm: exactly one site changed, the awaited
   handler calls are untouched, and `node --check main.js` still parses. Then
   run the CI simulation above.
