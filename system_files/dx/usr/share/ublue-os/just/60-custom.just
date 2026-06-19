# vim: set ft=make :
# dx4homelab custom ujust recipes.
#
# Baked into the dx image at /usr/share/ublue-os/just/60-custom.just (via
# customize-build.py EXTRA_FILE_COPIES). The base image's 00-entry.just ends with
#   import? "/usr/share/ublue-os/just/60-custom.just"
# so every recipe below is automatically available as `ujust <recipe>`.

# Install the dx4homelab Homebrew CLI tools + fonts (idempotent; run after first boot)
[group('dx4homelab')]
install-dx4homelab-brews:
    #!/usr/bin/env bash
    set -euo pipefail
    BREWFILE="/usr/share/ublue-os/homebrew/dx4homelab.Brewfile"
    if ! command -v brew >/dev/null 2>&1; then
        if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
            eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        else
            echo "Homebrew isn't ready yet — wait for first-boot brew setup to finish, then re-run." >&2
            exit 1
        fi
    fi
    if [ ! -f "${BREWFILE}" ]; then
        echo "Brewfile not found at ${BREWFILE}" >&2
        exit 1
    fi
    echo "Installing dx4homelab brew packages from ${BREWFILE} ..."
    brew bundle install --no-upgrade --file="${BREWFILE}"
    echo "✓ dx4homelab brew packages installed"

# Install internal / extra CA certificates into the system trust from a LOCAL,
# private directory of *.crt/*.pem files. Deliberately data-free: internal CAs are
# NEVER baked into this public image — keep your CA files in private storage and
# point this recipe at them. Files containing a private key are skipped (trust
# anchors are public certs only). Needs sudo (writes /etc trust anchors).
# Usage:  ujust install-extra-ca-trust [DIR]
[group('dx4homelab')]
install-extra-ca-trust dir="~/.config/dx4homelab/ca-anchors":
    #!/usr/bin/env bash
    set -euo pipefail
    DIR="{{dir}}"; DIR="${DIR/#\~/$HOME}"
    if [[ ! -d "$DIR" ]]; then
        echo "No CA directory at: $DIR" >&2
        echo "Create it and add your *.crt/*.pem CA files, or pass a path:" >&2
        echo "  ujust install-extra-ca-trust /path/to/your/ca-dir" >&2
        exit 1
    fi
    mapfile -t certs < <(find "$DIR" -maxdepth 1 -type f \( -iname '*.crt' -o -iname '*.pem' -o -iname '*.cer' \) | sort)
    [[ ${#certs[@]} -gt 0 ]] || { echo "No *.crt/*.pem/*.cer files found in $DIR" >&2; exit 1; }
    installed=0
    for c in "${certs[@]}"; do
        if grep -q 'PRIVATE KEY' "$c"; then
            echo "  ! skipping (contains a private key): $(basename "$c")" >&2
            continue
        fi
        if ! openssl x509 -in "$c" -noout >/dev/null 2>&1; then
            echo "  ! skipping (not a PEM X.509 cert): $(basename "$c")" >&2
            continue
        fi
        sudo install -m 0644 "$c" "/etc/pki/ca-trust/source/anchors/$(basename "$c")"
        echo "  + $(basename "$c")"
        installed=$((installed + 1))
    done
    [[ $installed -gt 0 ]] || { echo "No valid CA certs installed." >&2; exit 1; }
    sudo update-ca-trust
    echo "✓ Installed ${installed} CA cert(s) into the system trust."
    echo "  Verify: trust list --filter=ca-anchors | grep -i '<your CA CN>'"
