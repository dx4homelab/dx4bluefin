#!/usr/bin/bash
# dx4homelab: bake the Claude desktop app into the image.
#
# Anthropic ships no Linux build, so this is the community repackaging
# (github.com/aaddrick/claude-desktop-debian) of the official Electron app, from its
# signed dnf repo. Every image build installs whatever is current there; /usr is
# read-only at runtime, so the image is the only update channel.
#
#   - Trust : the repo's signing key is committed at mods/claude-desktop/KEY.gpg
#             (fingerprint 8749 4CF7 3ACC 0F23 AA95 57B8 6E29 E413 B912 E0F1) and used
#             from /ctx instead of being fetched from the host that serves the packages,
#             so a compromised server cannot swap key and package together. Both the
#             package and the repo metadata are signature-checked. If upstream rotates
#             the key the build fails here: verify the new key before replacing it.
#   - Repo  : exists only for this step (enabled=0 + --enablerepo, removed on exit), so
#             validate-repos.sh passes and nothing third-party stays configured.
#   - Paths : the RPM installs to /usr/lib/claude-desktop-unofficial, not /opt (which
#             the Containerfile relinks to /var/opt). Gated below in case that changes.
#
# Source of truth: mods/05-claude-desktop.sh — copied to build_files/dx/ and chained
# after 04-eclipse-ide.sh in build-dx.sh (both wired via customize-build.py).
set -xeuo pipefail

echo "::group:: ===$(basename "$0")=== Claude desktop (unofficial RPM)"

PKG="claude-desktop-unofficial"
KEY="${CLAUDE_DESKTOP_KEY:-/ctx/build_files/dx/claude-desktop/KEY.gpg}"
REPO="/etc/yum.repos.d/$PKG.repo"
APPROOT="/usr/lib/$PKG"

test -s "$KEY"
trap 'rm -f "$REPO"' EXIT
cat >"$REPO" <<REPOFILE
[$PKG]
name=Claude Desktop (unofficial packaging)
baseurl=https://pkg.claude-desktop-debian.dev/rpm/\$basearch
enabled=0
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$KEY
REPOFILE

dnf5 -y install --enablerepo="$PKG" "$PKG"
rm -f "$REPO"

# --- Build-time gates ---
# Nothing may land where it would not survive into the deployed system.
if rpm -ql "$PKG" | grep -E '^/(opt|var|usr/local)(/|$)'; then
  echo "ERROR: $PKG now installs outside /usr (see paths above)" >&2
  exit 1
fi
test -x "/usr/bin/$PKG"
test -x "$APPROOT/claude-desktop"
test -u "$APPROOT/chrome-sandbox"       # setuid helper for Chromium's sandbox
desktop-file-validate "/usr/share/applications/$PKG.desktop"
# The RPM declares no library dependencies, so check the image really provides them.
if ldd "$APPROOT/claude-desktop" | grep 'not found'; then
  echo "ERROR: $PKG needs libraries the image does not ship (see above)" >&2
  exit 1
fi

echo "Claude desktop $(rpm -q --qf '%{VERSION}-%{RELEASE}' "$PKG") installed to $APPROOT ($(du -sh "$APPROOT" | cut -f1))"
echo "::endgroup::"
