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

## ISO downloads (build-disk.yml)

The ISO is rebuilt automatically whenever the **"Build dx4homelab/bluefin/dx
Stable"** image workflow completes successfully on `main` (`workflow_run`
trigger — so after every Friday MODS run and after any push to `mods/**`), or
on `workflow_dispatch` with "Upload to S3". Either way it lands in the
`dx4homelab` bucket under `iso/bootiso/` as
`<flavor>-<YYYYMMDD>-<short sha>.iso` plus a matching `.sha256`, e.g.

    https://dx4homelab.s3.us-east-2.amazonaws.com/iso/bootiso/bluefin-dx-stable-20260914-c5860c9.iso

Objects under `iso/*` are **publicly readable by exact key** (bucket policy
grants anonymous `s3:GetObject`); listing is not public, so the bucket root
shows AccessDenied in a browser and unknown keys return 403. Only the
`bootiso/` directory is uploaded — the bootc-image-builder manifest JSON is
never published. After each upload the workflow prunes to the newest
`ISO_KEEP` (4) revisions; this needs `s3:DeleteObject` on `iso/bootiso/*`,
which is the `PruneOldIsoRevisions` statement in
`mods/aws/github-upload-iso-policy.json` (apply with
`aws iam create-policy-version --policy-arn arn:aws:iam::199715917706:policy/github-upload-iso-policy --policy-document file://mods/aws/github-upload-iso-policy.json --set-as-default`).

Every build posts the link, size, checksum and image digest to the rolling
**"ISO downloads (weekly build)"** issue (label `iso-download`): the body
always holds the newest build, every build adds a comment (linking the image
build that triggered it) with an `@dx4homelab` mention so GitHub emails the
notification. If the issue is closed, the next build opens a fresh one.
Pre-signed URLs were deliberately not used: URLs signed with the OIDC role's
temporary credentials die with the 1 h session.

## Eclipse IDE (04-eclipse-ide.sh)

The dx image bakes Eclipse IDE (EPP **jee** package) with **Subclipse 4.3.4**
(JavaHL adapter, Revision Graph) and **EGit** into `/usr/lib/eclipse`, launched as
`/usr/bin/eclipse`. It runs as a read-only *shared install*: per-user config
and any plugins a user adds live in `~/.eclipse`.

- **Updates come with the image only.** Every build takes the current EPP
  release from `release.xml` (quarterly: Mar/Jun/Sep/Dec), so a new release
  lands with the next Friday build. Eclipse's own weekly update check is
  disabled (`org.eclipse.equinox.p2.ui.sdk.scheduler/enabled=false`):
  updates it installed would land in `~/.eclipse`, drift from the image and
  trigger the "shared installation has changed" migration on every upgrade.
  If a new release breaks Subclipse, `bootc rollback`; to hold a release,
  set `EPP_RELEASE=2026-09/R` in the script.
- **JavaHL swap.** Subclipse is unmaintained; its newest adapter bundles
  JavaHL **1.14** Java classes, which crash the JVM against Fedora's native
  `libsvnjavahl` **1.15** (`terminate called after throwing an instance of
  'Java::SignalExceptionThrown'`). The script replaces
  `lib/javahl-*.jar` inside the adapter bundle with the image's
  `/usr/share/java/svn-javahl.jar`, so the Java and native halves always come
  from the same RPM. On a stock (unswapped) Subclipse the same mismatch also
  shows up without a crash: Revision Graph fails with "An internal error
  occurred during: Calculating graph information" / `NoSuchMethodError:
  <init>` at `SVNClient.info(Native Method)`.
- **X11 by default.** `/usr/bin/eclipse` is a wrapper that sets
  `GDK_BACKEND=x11` unless already set. On native Wayland, clicking a
  perspective or view tab can start a part drag whose button release SWT
  never receives, freezing the UI in `DnDManager.startDrag`. Try Wayland with
  `GDK_BACKEND=wayland eclipse`. NVIDIA PRIME variables are deliberately not
  set: they break GLX on machines without an NVIDIA GPU.
- **Hash pins.** subclipse.github.io publishes no checksums or signatures.
  The six Subclipse jars are SHA-256 pinned (step 2b); each was committed
  once to `subclipse/updates` (2021/2023) and never changed, so the pins
  should never need a bump. A pin failure means the update site changed —
  investigate before re-pinning.
- **Alternative considered:** Subversive 5.1 (Eclipse, maintained, checksummed)
  + ArSysOp SVNKit connector (PGP-signed). Rejected for now: its pure-Java
  protocol stack bundles Apache SSHD 2.11 (Terrapin, CVE-2023-48795),
  BouncyCastle 1.77 and trilead-ssh2, whereas JavaHL uses Fedora's patched
  native Subversion/serf/OpenSSL. `git svn` + EGit is the leanest option
  where the SVN workflow allows it.

### Optional: a second Eclipse in a distrobox (not set up, not tested)

Only worth it to run a *different* Eclipse next to the baked one — e.g. a
pinned older release for a legacy project, or trying the next release before
it reaches the image. Flatpak is not an option: Flathub has no jee build, and
the sandbox can't reach the host's `libsvnjavahl` (Subclipse) or host
JDKs/Maven/podman.

The same build script works in a Fedora box (it only needs `dnf`, `curl`,
`python3`, `desktop-file-utils` and `subversion-javahl`; the box also needs
`gtk3` for SWT, and optionally `webkit2gtk4.1` for the internal browser and
Javadoc hovers):

```bash
distrobox create --name eclipse --image registry.fedoraproject.org/fedora-toolbox:44
distrobox enter eclipse -- sudo dnf -y install subversion-javahl desktop-file-utils \
  python3 gtk3 webkit2gtk4.1
# To pin a release or package, put e.g. EPP_RELEASE=2026-06/R EPP_PACKAGE=java after sudo.
distrobox enter eclipse -- sh -c 'curl -fsSLo /tmp/04-eclipse-ide.sh \
  https://raw.githubusercontent.com/dx4homelab/dx4bluefin/main/mods/04-eclipse-ide.sh \
  && sudo bash /tmp/04-eclipse-ide.sh'
# Own workspace: both installs default to ~/eclipse-workspace, and a workspace
# is locked while open and gets its metadata upgraded by newer releases.
distrobox enter eclipse -- distrobox-export --app eclipse \
  --extra-flags "-data $HOME/eclipse-workspace-box"
```

Gotchas:

- **Updates are manual.** Re-run the script line to move to the current
  release (it wipes and reinstalls `/usr/lib/eclipse` in the box).
- **Re-run the script after any `dnf upgrade` that bumps `subversion`** in the
  box: the swapped JavaHL jar must match the box's native library, or the
  `Java::SignalExceptionThrown` JVM crash returns.
- Per-user state doesn't collide: `~/.eclipse/<product>_<version>_<hash>_…`
  is keyed by install path, and the exported launcher is suffixed
  "(on eclipse)".
- If this gets used regularly, promote it to a CI-built image instead
  (`FROM fedora-toolbox:44`, `COPY` + `RUN` the script, push to GHCR, then
  `distrobox create --image ghcr.io/dx4homelab/eclipse-box`). The keyring PAT
  lacks `workflow` scope; push the new workflow via `gh auth git-credential`.

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
