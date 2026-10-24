#!/usr/bin/bash
# dx4homelab: bake Eclipse IDE (EPP "Enterprise Java and Web Developers" package) with
# Subclipse and EGit
# into the image.
#
#   - Eclipse : the current EPP release (resolved from the EPP release.xml, sha512-checked),
#               unpacked to /usr/lib/eclipse. It ships its own JustJ JRE, so no system JDK.
#               /usr is read-only at runtime, so Eclipse runs as a "shared install":
#               per-user config and any plugins users add go to ~/.eclipse.
#   - EGit    : from the matching simultaneous-release repo (already part of the jee
#               package; listed so it survives a switch to a package that lacks it).
#   - Subclipse 4.3.x + its JavaHL client adapter and Revision Graph, from
#               subclipse.github.io (the graph's GEF Classic comes from the release repo).
#
# JavaHL: Subclipse is unmaintained (last release 4.3.4, 2023) and its newest adapter
# bundles JavaHL 1.14 Java classes. Against Fedora's native libsvnjavahl 1.15 those crash
# the JVM (`terminate called after throwing an instance of 'Java::SignalExceptionThrown'`);
# with the image's own svn-javahl.jar the adapter works. So the bundled jar is replaced
# with the image's one — the Java and native halves then always come from the same RPM.
#
# Source of truth: mods/04-eclipse-ide.sh — copied to build_files/dx/ and chained after
# 03-awsgov-wickr-badge.sh in build-dx.sh (both wired via customize-build.py).
set -xeuo pipefail

echo "::group:: ===$(basename "$0")=== Eclipse IDE + Subclipse + EGit"

EPP_PACKAGE="${EPP_PACKAGE:-jee}"
EPP_BASE="https://download.eclipse.org/technology/epp/downloads/release"
SUBCLIPSE_REPO="https://subclipse.github.io/updates/subclipse/4.3.x/"
APPROOT="/usr/lib/eclipse"              # NOT /opt — the Containerfile relinks /opt -> /var/opt
CURL_RETRY=(--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 30)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Native JavaHL (libsvnjavahl-1.so, from subversion-libs) + its Java classes.
rpm -q subversion-javahl >/dev/null 2>&1 || dnf -y install subversion-javahl
test -e /usr/lib64/libsvnjavahl-1.so
test -s /usr/share/java/svn-javahl.jar

# --- 1. Fetch + unpack the current EPP release (e.g. RELEASE=2026-09/R) ---
RELEASE="${EPP_RELEASE:-$(curl -fsSL "${CURL_RETRY[@]}" "$EPP_BASE/release.xml" \
  | sed -n 's|.*<present>\(.*\)</present>.*|\1|p')}"
test -n "$RELEASE"
TARBALL="eclipse-${EPP_PACKAGE}-${RELEASE%/*}-${RELEASE#*/}-linux-gtk-x86_64.tar.gz"
curl -fsSL "${CURL_RETRY[@]}" -o "$WORK/$TARBALL" "$EPP_BASE/$RELEASE/$TARBALL"
curl -fsSL "${CURL_RETRY[@]}" -o "$WORK/$TARBALL.sha512" "$EPP_BASE/$RELEASE/$TARBALL.sha512"
(cd "$WORK" && sha512sum -c "$TARBALL.sha512")
rm -rf "$APPROOT"
mkdir -p "$APPROOT"
tar -xzf "$WORK/$TARBALL" -C "$APPROOT" --strip-components=1 --no-same-owner
rm -f "$WORK/$TARBALL"

# --- 2. Install the plugins with the p2 director (headless) ---
# The EPP product's p2 profile, e.g. epp.package.jee.
PROFILE="$(basename "$(ls -d "$APPROOT"/p2/org.eclipse.equinox.p2.engine/profileRegistry/*.profile)" .profile)"
P2_IUS=(
  org.tigris.subversion.subclipse.feature.group
  org.tigris.subversion.clientadapter.javahl.feature.feature.group
  org.tigris.subversion.subclipse.graph.feature.feature.group
  org.eclipse.egit.feature.group
)
# Without a config, logback (pulled in with m2e) logs at DEBUG: ~68k lines of HttpClient
# chatter per run.
cat > "$WORK/logback.xml" <<'XML'
<configuration><root level="WARN"/></configuration>
XML
p2() {
  # Own configuration area and user.home so the director leaves nothing in the install's
  # configuration/ or in /root; appendVmargs keeps eclipse.ini's -vmargs in effect.
  "$APPROOT/eclipse" -nosplash -consoleLog --launcher.appendVmargs \
    -application org.eclipse.equinox.p2.director \
    -configuration "$WORK/p2-config" \
    -destination "$APPROOT" -profile "$PROFILE" "$@" \
    -vmargs -Duser.home="$WORK/home" -Dlogback.configurationFile="$WORK/logback.xml"
}
p2 -repository "$SUBCLIPSE_REPO,https://download.eclipse.org/releases/${RELEASE%/*}" \
  -installIU "$(IFS=,; echo "${P2_IUS[*]}")"
rm -rf "$APPROOT/p2/org.eclipse.equinox.p2.core/cache"

# --- 2b. Pin the Subclipse bundles ---
# subclipse.github.io publishes no checksums or signatures, so p2 installs them unverified
# ("No digest algorithm is available"). Subclipse is frozen (each jar committed once to
# subclipse/updates, 2021/2023, never changed), so these pins never churn. They must run
# before step 3 rewrites the javahl jar, and the installed set must be exactly this set.
(cd "$APPROOT/plugins" && sha256sum -c --strict) <<'SHA'
3864685f97aa55e785af0358518c837e92ab3c17c1d5ac3cd026bdf9b7947658  com.collabnet.subversion.merge_4.2.0.1.jar
f7f778b305809a32e400fa28396bc117816050246302771ac7d1c75d2a776f12  org.tigris.subversion.clientadapter_1.10.0.jar
4ec0c255022c43be2d69e9096eae192358d77ba35f3d314b4651b0728856ca99  org.tigris.subversion.clientadapter.javahl_1.14.0.1.jar
511c8b008c56dd8328c626cc465b7b303eb5dabb1c7768e3345049da1e56c3e3  org.tigris.subversion.subclipse.core_4.3.4.202306191346.jar
834f6821c696341526219e54b971cfec23667a7b1bd34fb89222bbe308c88e77  org.tigris.subversion.subclipse.ui_4.3.4.202306191346.jar
9b8629f198b99f323f62b78afbaa7415cd10d1d64fb08e442652e6474ea4f9a0  org.tigris.subversion.subclipse.graph_4.2.0.1.jar
SHA
test "$(cd "$APPROOT/plugins" && ls -d com.collabnet.* org.tigris.* | wc -l)" -eq 6

# --- 3. Swap the adapter's bundled JavaHL 1.14 classes for the image's own ---
# The bundle is a plain (unsigned) jar whose Bundle-ClassPath names lib/javahl-<ver>.jar,
# so rewrite that one entry in place and keep its name (and its ZipInfo: ostree-normalized
# mtimes are 1970, which ZIP cannot store).
JHL_BUNDLE="$(ls "$APPROOT"/plugins/org.tigris.subversion.clientadapter.javahl_*.jar)"
python3 - "$JHL_BUNDLE" /usr/share/java/svn-javahl.jar <<'PY'
import os, sys, zipfile
bundle, jar = sys.argv[1], sys.argv[2]
tmp = bundle + ".tmp"
with zipfile.ZipFile(bundle) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
    swapped = [i.filename for i in src.infolist()
               if i.filename.startswith("lib/javahl-") and i.filename.endswith(".jar")]
    if len(swapped) != 1:
        sys.exit(f"expected one lib/javahl-*.jar in {bundle}, found {swapped}")
    for i in src.infolist():
        if i.filename == swapped[0]:
            with open(jar, "rb") as f:
                dst.writestr(i, f.read())
        else:
            dst.writestr(i, src.read(i.filename))
os.replace(tmp, bundle)
with zipfile.ZipFile(bundle) as z, open(jar, "rb") as f:
    assert z.read(swapped[0]) == f.read(), "JavaHL swap did not stick"
print(f"{os.path.basename(bundle)}: {swapped[0]} <- {jar}")
PY
chmod 0644 "$JHL_BUNDLE"

# --- 3b. The image is the update channel ---
# EPP enables a weekly in-app update check that also downloads. In a read-only shared
# install those updates land in each user's ~/.eclipse, drift from the image, and trigger
# p2's "shared installation has changed" migration on every image upgrade. New releases
# arrive with the image instead (step 1 always takes the current one).
CUST="$(ls "$APPROOT"/plugins/org.eclipse.epp.package."$EPP_PACKAGE"_*/plugin_customization.ini)"
sed -i '/^org\.eclipse\.equinox\.p2\.ui\.sdk\.scheduler\/enabled=/d' "$CUST"
echo 'org.eclipse.equinox.p2.ui.sdk.scheduler/enabled=false' >> "$CUST"

# --- 4. Launcher, desktop entry, icon ---
ln -sf "$APPROOT/eclipse" /usr/bin/eclipse
install -Dm644 "$(ls "$APPROOT"/plugins/org.eclipse.platform_*/eclipse256.png | head -n1)" \
  /usr/share/pixmaps/eclipse.png
cat > /usr/share/applications/eclipse.desktop <<'DESK'
[Desktop Entry]
Version=1.0
Type=Application
Name=Eclipse IDE
GenericName=Integrated Development Environment
Comment=Eclipse IDE with Subclipse, Revision Graph and EGit
Exec=/usr/bin/eclipse
Icon=eclipse
Terminal=false
Categories=Development;IDE;Java;
StartupWMClass=Eclipse
DESK

# --- 5. Build-time gates ---
roots="$(p2 -listInstalledRoots)"
for iu in "${P2_IUS[@]}"; do
  grep -qF "$iu/" <<<"$roots" \
    || { echo "ERROR: $iu is not installed in $APPROOT" >&2; exit 1; }
done
bundles="$APPROOT/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
grep -q '^org.tigris.subversion.clientadapter.javahl,' "$bundles"
grep -q '^org.eclipse.egit.core,' "$bundles"
grep -q '^org.tigris.subversion.subclipse.graph,' "$bundles"
grep -q '^org.eclipse.gef,' "$bundles"
grep -qx 'org.eclipse.equinox.p2.ui.sdk.scheduler/enabled=false' "$CUST"
desktop-file-validate /usr/share/applications/eclipse.desktop
test -x /usr/bin/eclipse

echo "Eclipse $RELEASE ($EPP_PACKAGE) installed to $APPROOT ($(du -sh "$APPROOT" | cut -f1)) with Subclipse (+ Revision Graph) + EGit"
echo "::endgroup::"
