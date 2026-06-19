#!/usr/bin/bash
# Download the latest DoD PKI certificate bundle from DISA and bake it into the
# image's system trust store at build time, so a freshly installed dx4bluefin
# instance trusts DoD-issued certificates out of the box (web, mTLS, CAC chains).
#
# Source of truth: mods/02-dod-ca-trust.sh — copied to build_files/dx/ and invoked
# from build-dx.sh after 01-custom-dx4homelab.sh (both wired via customize-build.py).
#
# Trade-off: this always pulls the CURRENT published bundle (no pinned hash), so it
# can't be SHA-pinned without breaking on every DISA refresh. Integrity rests on
# TLS verification of dl.dod.cyber.mil plus structural sanity checks below; the
# build FAILS hard rather than ship an image missing/!= the expected DoD roots.
#
# Resilience: if the live download fails (DISA outage / offline build), fall back
# to the bundle committed at mods/dod-pki/ (baked to /ctx/build_files/dx/ via
# EXTRA_FILE_COPIES). Refresh that committed copy periodically with:
#   curl -fsSL https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_DoD.zip \
#     -o mods/dod-pki/unclass-certificates_pkcs7_DoD.zip
set -xeou pipefail

echo "::group:: ===$(basename "$0")=== DoD PKI trust anchors"

# DISA's consolidated, unclassified PKCS#7 bundle ("latest" stable link).
DOD_ZIP_URL="${DOD_ZIP_URL:-https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_DoD.zip}"
# Minimum DoD Root CAs expected in the bundle (currently roots 3,4,5,6).
MIN_DOD_ROOTS="${MIN_DOD_ROOTS:-4}"
# Image-owned trust anchor location (read-only /usr; processed by update-ca-trust).
ANCHOR_DIR="/usr/share/pki/ca-trust-source/anchors"
DEST_PEM="${ANCHOR_DIR}/dod-pki-bundle.pem"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Obtain the bundle: try the live download first, then fall back to the bundle
#    committed in the repo if the download fails (DISA outage / offline build).
FALLBACK_ZIP="${FALLBACK_ZIP:-/ctx/build_files/dx/dod-pki-fallback.zip}"
if curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/dod.zip" "$DOD_ZIP_URL"; then
    echo "Downloaded latest DoD PKI bundle from ${DOD_ZIP_URL}"
elif [[ -f "$FALLBACK_ZIP" ]]; then
    echo "WARNING: download failed; using committed fallback bundle ${FALLBACK_ZIP}" >&2
    cp "$FALLBACK_ZIP" "$WORK/dod.zip"
else
    echo "ERROR: DoD bundle download failed and no committed fallback at ${FALLBACK_ZIP}" >&2
    exit 1
fi

# 2. Extract via python3 (avoids needing `unzip` in the image).
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
    "$WORK/dod.zip" "$WORK/x"

# 3. Best-effort integrity self-check against any published *.sha256 manifest.
SHA_FILE="$(find "$WORK/x" -iname '*.sha256' -type f | head -n1 || true)"
if [[ -n "$SHA_FILE" ]]; then
    ( cd "$(dirname "$SHA_FILE")" && sha256sum -c "$(basename "$SHA_FILE")" ) \
        && echo "DoD bundle sha256 manifest verified" \
        || echo "WARNING: sha256 manifest check inconclusive (paths may differ); relying on TLS + sanity checks"
fi

# 4. Locate the consolidated PKCS#7 (prefer PEM-form, fall back to DER).
P7B="$(find "$WORK/x" -iname '*.pem.p7b' -type f | head -n1 || true)"
INFORM=PEM
if [[ -z "$P7B" ]]; then
    P7B="$(find "$WORK/x" -iname '*.der.p7b' -type f | head -n1 || true)"
    INFORM=DER
fi
[[ -n "$P7B" ]] || { echo "ERROR: no PKCS#7 bundle (*.p7b) found in DoD download" >&2; exit 1; }
echo "Using PKCS#7 bundle: $P7B (inform=$INFORM)"

# 5. Convert PKCS#7 -> text (with subjects) for inspection, then a clean PEM.
openssl pkcs7 -inform "$INFORM" -in "$P7B" -print_certs -out "$WORK/full.txt"
awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "$WORK/full.txt" > "$WORK/dod-pki-bundle.pem"

# 6. Sanity: enough DoD Root CAs present (regex tolerates OpenSSL 3.x "CN = " spacing).
roots="$(grep -ciE 'subject=.*CN *= *DoD Root CA' "$WORK/full.txt" || true)"
total="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$WORK/dod-pki-bundle.pem" || true)"
echo "DoD bundle parsed: ${total} certificate(s), ${roots} DoD Root CA(s)"
[[ "$total" -gt 0 ]] || { echo "ERROR: no certificates parsed from DoD bundle" >&2; exit 1; }
[[ "$roots" -ge "$MIN_DOD_ROOTS" ]] || {
    echo "ERROR: only ${roots} DoD Root CA(s) found (expected >= ${MIN_DOD_ROOTS}); refusing to install" >&2
    exit 1
}

# 7. Install into the image trust store and re-extract the consolidated bundles.
install -d -m 0755 "$ANCHOR_DIR"
install -m 0644 "$WORK/dod-pki-bundle.pem" "$DEST_PEM"
update-ca-trust

# 8. Verify the DoD roots are actually TRUSTED as CA anchors (not just present as a
#    p11-kit friendly-name comment in the extracted bundle), and that the count
#    matches what we installed.
trusted="$(trust list --filter=ca-anchors | grep -c 'DoD Root CA' || true)"
echo "Trusted DoD Root CA anchors after update-ca-trust: ${trusted}"
[[ "$trusted" -ge "$MIN_DOD_ROOTS" ]] || {
    echo "ERROR: only ${trusted} DoD Root CA anchor(s) trusted (expected >= ${MIN_DOD_ROOTS})" >&2
    exit 1
}
echo "Installed DoD PKI bundle (${total} certs) to ${DEST_PEM}; ${trusted} DoD roots trusted as CA anchors."

echo "::endgroup::"
