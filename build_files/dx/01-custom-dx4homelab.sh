#!/usr/bin/bash
#
# 01-custom-dx4homelab.sh — dx4homelab custom image-build steps.
# Invoked from build-dx.sh right after 00-dx.sh (wired in by mods/customize-build.py).
#
# Currently installs: AWS WickrGov, natively, by extracting its snap — snapd is NOT
# used at runtime (snapd + ostree /var/home can't run confined app snaps). The Wickr
# client is a self-contained Qt 6.9.2 / QtWebEngine app with a bundled FIPS OpenSSL;
# we unpack it into /usr/lib (NOT /opt — the Containerfile relinks /opt -> /var/opt),
# supply the two libs Fedora can't (libapparmor from the core24 base; a libbz2 soname
# symlink), and ship a launcher that uses host Mesa with software rendering (hardware
# EGL is unreliable for the extracted app; software is fine for a messaging client).
#
set -ouex pipefail

ARCH="x86_64-linux-gnu"
APPROOT="/usr/lib/awswickrgov"          # baked, read-only at runtime; survives image rebases
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build-time tools (present in the image already; ensure regardless).
dnf -y install squashfs-tools jq

# Resolve a snap's stable amd64 download URL from the public store API (no snapd, no auth),
# then fetch it with retries (transient TLS/CDN drops happen) via a local cache keyed by the
# revisioned filename, so a flaky network or a re-run does not re-pull ~1 GB.
SNAP_CACHE="${SNAP_CACHE:-/var/tmp/dx4homelab-snapcache}"
CURL_RETRY=(--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 30)
snap_dl() {
  local name="$1" out="$2" url cache
  url="$(curl -sSL "${CURL_RETRY[@]}" -H 'Snap-Device-Series: 16' \
        "https://api.snapcraft.io/v2/snaps/info/${name}?fields=download" \
      | jq -r '.["channel-map"][]
               | select(.channel.name=="stable" and .channel.architecture=="amd64")
               | .download.url' | head -1)"
  test -n "$url"
  mkdir -p "$SNAP_CACHE"
  cache="$SNAP_CACHE/$(basename "$url")"
  if [ -s "$cache" ] && unsquashfs -s "$cache" >/dev/null 2>&1; then
    echo "snap_dl: using cached $(basename "$cache")"
  else
    curl -sSL "${CURL_RETRY[@]}" -o "$cache.part" "$url"
    unsquashfs -s "$cache.part" >/dev/null     # verify it is a valid squashfs before trusting it
    mv -f "$cache.part" "$cache"
  fi
  cp -f "$cache" "$out"
}

# --- 1. Fetch + unpack the WickrGov app ---
snap_dl awswickrgov "$WORK/wickr.snap"
rm -rf "$APPROOT"
unsquashfs -q -n -d "$APPROOT" "$WORK/wickr.snap"

# --- 2. libapparmor.so.1: Fedora ships none; take it from the core24 base.
# Selective extraction following the symlink to its versioned target. A FULL core24
# extraction would try to mknod /dev/* nodes, which the unprivileged image-build
# container cannot do (it fails the build); -follow-symlinks also avoids hardcoding
# the lib version (it differs per core24 revision, e.g. .1.17.1 vs .1.17.2).
snap_dl core24 "$WORK/core24.snap"
unsquashfs -q -n -follow-symlinks -d "$WORK/core24" "$WORK/core24.snap" "/usr/lib/$ARCH/libapparmor.so.1"
cp -a "$WORK/core24/usr/lib/$ARCH/"libapparmor.so.1* "$APPROOT/usr/lib/$ARCH/"

# --- 3. libbz2.so.1.0 (Debian soname) -> Fedora's libbz2.so.1 ---
host_bz2="$(ldconfig -p | awk '/libbz2.so.1 /{print $NF; exit}')"
ln -sf "${host_bz2:-/lib64/libbz2.so.1}" "$APPROOT/usr/lib/$ARCH/libbz2.so.1.0"

# --- 4. Remove the bundled Mesa/GL stack so host GL (software) is used ---
GLD="$APPROOT/usr/lib/$ARCH"
for pat in 'libEGL*' 'libGLX*' 'libGL.so*' 'libGLdispatch*' 'libOpenGL*' \
           'libgbm*' 'libglapi*' 'libgallium*' 'libdrm*' 'libvulkan*'; do
  for f in $GLD/$pat; do [ -e "$f" ] && rm -f "$f"; done
done
rm -rf "$GLD/dri"

# --- 5. Launcher wrapper (the recipe validated on the workstation) ---
cat > /usr/bin/awswickrgov <<'WRAP'
#!/usr/bin/bash
SNAP=/usr/lib/awswickrgov
ARCH=x86_64-linux-gnu
export QT_BASE_DIR="$SNAP/opt/Qtqt692" QTDIR="$SNAP/opt/Qtqt692"
export QT_PLUGIN_PATH="$QT_BASE_DIR/plugins" QML2_IMPORT_PATH="$QT_BASE_DIR/qml"
export LD_LIBRARY_PATH="$QT_BASE_DIR/lib:$SNAP/usr/lib/$ARCH:$SNAP/usr/lib/$ARCH/pulseaudio:$SNAP/usr/lib/$ARCH/libproxy:$SNAP/lib/$ARCH:$SNAP/usr/lib"
export OPENSSL_MODULES="$SNAP/fips" OPENSSL_CONF="$SNAP/fips/openssl.cnf"
export QTWEBENGINE_DISABLE_SANDBOX=1 ALWAYS_USE_PULSEAUDIO=1
# Host Mesa, software rendering (hardware EGL is unreliable for the extracted app).
export __EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d
export LIBGL_DRIVERS_PATH=/usr/lib64/dri
export QT_QUICK_BACKEND=software QMLSCENE_DEVICE=softwarecontext LIBGL_ALWAYS_SOFTWARE=1
export QTWEBENGINE_CHROMIUM_FLAGS="--disable-gpu --disable-gpu-compositing ${QTWEBENGINE_CHROMIUM_FLAGS:-}"
export XDG_DATA_DIRS="$SNAP/usr/share:$SNAP/share:${XDG_DATA_DIRS:-/usr/share}"
export PATH="$QT_BASE_DIR/bin:$SNAP/usr/bin:$PATH"
exec "$SNAP/usr/bin/AWSWickrGov" "$@"
WRAP
chmod +x /usr/bin/awswickrgov

# --- 6. Desktop entry + icon ---
icon_src="$APPROOT/meta/gui/awswickrgov.png"
[ -f "$icon_src" ] || icon_src="$APPROOT/meta/gui/icon.png"
install -Dm644 "$icon_src" /usr/share/pixmaps/awswickrgov.png
cat > /usr/share/applications/awswickrgov.desktop <<'DESK'
[Desktop Entry]
Version=1.0
Type=Application
Name=AWS WickrGov
GenericName=Secure Messenger
Comment=Secure messaging for teams (AWS WickrGov)
Exec=/usr/bin/awswickrgov %u
Icon=awswickrgov
Terminal=false
Categories=Network;InstantMessaging;
MimeType=x-scheme-handler/awswickrgov;
StartupWMClass=AWSWickrGov
DESK

# --- 7. Assert every library the app links is satisfied; fail the build loudly if not ---
APP_LD="$APPROOT/opt/Qtqt692/lib:$APPROOT/usr/lib/$ARCH:$APPROOT/usr/lib/$ARCH/pulseaudio:$APPROOT/lib/$ARCH:$APPROOT/usr/lib"
missing="$(LD_LIBRARY_PATH="$APP_LD" ldd "$APPROOT/usr/bin/AWSWickrGov" 2>/dev/null | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')"
if [ -n "$missing" ]; then
  echo "ERROR: AWS WickrGov has unmet libraries on this image: $missing" >&2
  exit 1
fi

echo "AWS WickrGov installed natively to $APPROOT ($(du -sh "$APPROOT" | cut -f1))"
