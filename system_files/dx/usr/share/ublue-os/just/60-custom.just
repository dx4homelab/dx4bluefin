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
