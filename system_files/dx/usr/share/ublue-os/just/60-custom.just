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

# Remove a stale, locally-installed (priority 400) snap SELinux override — e.g. a
# `snapd_local` module produced by audit2allow. After a base `selinux-policy` bump, such
# a local module can reference types/attributes the new base no longer defines (e.g.
# `snappy_t`); then `ostree-finalize-staged` fails to rebuild the SELinux policy and the
# next image update can't finalize or boot. snapd itself ships in the upstream bluefin
# image (not added here) and is NOT touched — only the local priority-400 override is
# removed; snapd's packaged `snappy` policy (priority 200) stays. Any allows you actually
# need can be regenerated with audit2allow against the *new* policy after updating.
# Idempotent: a clean no-op when nothing matches. Because snapd ships upstream, pass
# `force` to confirm removal while the snapd package is installed.
# Usage:  ujust purge-stale-snap-selinux [force]
[group('dx4homelab')]
purge-stale-snap-selinux force="":
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v semodule >/dev/null 2>&1; then
        echo "semodule not found — SELinux tooling unavailable; nothing to do."
        exit 0
    fi
    # Priority 400 = locally installed (semodule -i) modules; image modules live at 100.
    # Match snapd*/snappy* only — NOT 'snapper' (the unrelated btrfs snapshot tool).
    mapfile -t stale < <(sudo semodule -lfull | awk '$1==400 && tolower($2) ~ /^snap(d|py)/ {print $2}')
    if [[ ${#stale[@]} -eq 0 ]]; then
        echo "✓ No stale priority-400 snap SELinux modules found — nothing to do."
        exit 0
    fi
    echo "Found local (priority 400) snap SELinux module(s):"
    printf '    %s\n' "${stale[@]}"
    if rpm -q snapd >/dev/null 2>&1 && [[ "{{force}}" != "force" ]]; then
        echo "" >&2
        echo "! The 'snapd' package IS installed — these modules may still be in use." >&2
        echo "  Refusing to remove them without an explicit override. If you really want" >&2
        echo "  to drop snapd's SELinux modules anyway, re-run:" >&2
        echo "      ujust purge-stale-snap-selinux force" >&2
        exit 1
    fi
    removed=0
    for m in "${stale[@]}"; do
        # Try a normal removal (also reloads the live policy). If the live reload
        # fails, fall back to --noreload (-N): the store is still cleaned, and the
        # next ostree finalize rebuilds the policy without the module.
        if sudo semodule -X 400 -r "$m" 2>/dev/null; then
            echo "  + removed: $m"
            removed=$((removed + 1))
        elif sudo semodule -N -X 400 -r "$m"; then
            echo "  + removed (store only; policy rebuilds on next boot): $m"
            removed=$((removed + 1))
        else
            echo "  ! failed to remove: $m" >&2
        fi
    done
    [[ $removed -gt 0 ]] || { echo "No modules removed." >&2; exit 1; }
    echo "✓ Removed ${removed} stale snap SELinux module(s)."
    echo "  Re-stage and boot the pending update so its SELinux policy finalizes cleanly:"
    echo "      sudo rpm-ostree update && sudo systemctl reboot"
    echo "  After reboot, confirm with: rpm-ostree status"

# Clear ONLY the AWS WickrGov notifications the tracker daemon recorded (resets just the
# Wickr dock badge). Same as pressing Alt+W. Needs the awsgov-wickr-notify.service running.
[group('dx4homelab')]
clear-wickr-notifications:
    #!/usr/bin/env bash
    exec /usr/bin/clear-wickr

# HARD clear: close EVERY app's notifications (resets all dock badges, not only Wickr's).
# Same as pressing Alt+Shift+W. Use when notifications piled up before the tracker started.
[group('dx4homelab')]
clear-all-notifications:
    #!/usr/bin/env bash
    exec /usr/bin/clear-notifications

# (Re)apply the AWS WickrGov dock-badge fix for the current user: enable+start the tracker
# service and (re)bind the two clear hotkeys. Idempotent — run it if you wiped your shortcuts
# or want different keys. The bindings merge into your shortcuts (never clobber existing ones).
#   ujust setup-wickr-badge-fix '<Alt>w' '<Alt><Shift>w'
[group('dx4homelab')]
setup-wickr-badge-fix wickr_key='<Alt>w' all_key='<Alt><Shift>w':
    #!/usr/bin/env bash
    set -euo pipefail
    systemctl --user enable --now awsgov-wickr-notify.service
    python3 /usr/libexec/awsgov-wickr/bind-hotkey.py \
        --command /usr/bin/clear-wickr \
        --name "Clear AWS WickrGov notifications" --binding '{{wickr_key}}'
    python3 /usr/libexec/awsgov-wickr/bind-hotkey.py \
        --command /usr/bin/clear-notifications \
        --name "Clear ALL notifications (hard clear)" --binding '{{all_key}}'
    echo "✓ Wickr badge fix active: {{wickr_key}} = Wickr-only clear, {{all_key}} = clear-all."

# Undo the per-user setup: unbind both hotkeys and stop+disable the tracker service for the
# current user. The baked binaries stay in the image; re-enable with `ujust setup-wickr-badge-fix`.
[group('dx4homelab')]
remove-wickr-badge-fix:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 /usr/libexec/awsgov-wickr/bind-hotkey.py --unbind /usr/bin/clear-wickr || true
    python3 /usr/libexec/awsgov-wickr/bind-hotkey.py --unbind /usr/bin/clear-notifications || true
    systemctl --user disable --now awsgov-wickr-notify.service || true
    echo "✓ Wickr badge fix removed for ${USER}."
