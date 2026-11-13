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
    DIR="{{ dir }}"; DIR="${DIR/#\~/$HOME}"
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
    if rpm -q snapd >/dev/null 2>&1 && [[ "{{ force }}" != "force" ]]; then
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
# ujust setup-wickr-badge-fix '<Alt>w' '<Alt><Shift>w'
[group('dx4homelab')]
setup-wickr-badge-fix wickr_key='<Alt>w' all_key='<Alt><Shift>w':
    #!/usr/bin/env bash
    set -euo pipefail
    systemctl --user enable --now awsgov-wickr-notify.service
    python3 /usr/libexec/awsgov-wickr/bind-hotkey.py \
        --command /usr/bin/clear-wickr \
        --name "Clear AWS WickrGov notifications" --binding '{{ wickr_key }}'
    python3 /usr/libexec/awsgov-wickr/bind-hotkey.py \
        --command /usr/bin/clear-notifications \
        --name "Clear ALL notifications (hard clear)" --binding '{{ all_key }}'
    echo "✓ Wickr badge fix active: {{ wickr_key }} = Wickr-only clear, {{ all_key }} = clear-all."

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

# Rootless podman quadlet published on 127.0.0.1:8010 only, so message text never leaves
# this machine. Opt-in and per user: the ~0.5 GB image is pulled on install (not baked into
# the OS image) and the server uses ~0.8 GB RAM. Pinned by digest; bump IMAGE to update.
# Local LanguageTool grammar server for wickr-compose. Usage: ujust setup-languagetool [install|remove|status]
[group('dx4homelab')]
setup-languagetool action="install":
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE="docker.io/erikvl87/languagetool:6.8@sha256:ef8fa12cbd485166c9ceeb7139d76d56d07707a624da6bb1fc1fbb5411750527"
    UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/languagetool.container"
    up() { curl -fs -m 2 http://127.0.0.1:8010/v2/languages >/dev/null; }
    case "{{ action }}" in
    install)
        podman pull "$IMAGE"
        mkdir -p "$(dirname "$UNIT")"
        printf '%s\n' \
            "[Unit]" \
            "Description=LanguageTool grammar server (local, for wickr-compose)" \
            "" \
            "[Container]" \
            "ContainerName=languagetool" \
            "Image=$IMAGE" \
            "PublishPort=127.0.0.1:8010:8010" \
            "Environment=Java_Xms=256m Java_Xmx=1g" \
            "DropCapability=ALL" \
            "NoNewPrivileges=true" \
            "" \
            "[Service]" \
            "Restart=on-failure" \
            "TimeoutStartSec=300" \
            "" \
            "[Install]" \
            "WantedBy=default.target" > "$UNIT"
        systemctl --user daemon-reload
        systemctl --user restart languagetool.service
        echo -n "Waiting for LanguageTool on 127.0.0.1:8010 "
        for _ in $(seq 1 60); do up && break; echo -n .; sleep 2; done
        up || { echo; echo "LanguageTool did not come up: journalctl --user -u languagetool" >&2; exit 1; }
        echo " ✓ ready. Grammar check is on in wickr-compose (starts with your session)."
        ;;
    remove)
        systemctl --user stop languagetool.service 2>/dev/null || true
        rm -f "$UNIT"
        systemctl --user daemon-reload
        podman rmi "$IMAGE" 2>/dev/null || true
        echo "✓ LanguageTool removed; wickr-compose keeps spelling + dictation."
        ;;
    status)
        systemctl --user --no-pager status languagetool.service || true
        ;;
    *)
        echo "Usage: ujust setup-languagetool [install|remove|status]" >&2
        exit 1
        ;;
    esac

# ---------------------------------------------------------------------------
# Remote desktop (gnome-remote-desktop RDP), tuned for pixel-exact text.
#   host :3389  remote login -> its own GDM session, sized to the client window
#   host :3390  live session -> mirror of the host's primary monitor
# Client side uses the FreeRDP flatpak with RemoteFX (/gfx:RFX): measured on g-r-d
# 50.2 it keeps text edges far cleaner than AVC444/AVC420 (0.00-0.03 % vs 0.8-4.6 %
# of edge pixels off by >32 levels), with 1:1 pixel geometry.
# ---------------------------------------------------------------------------

# Usage: ujust setup-remote-desktop [enable|disable|status]
# Prompts for the RDP password (or generates one); the GDM login password is still
# asked at the greeter. Needs sudo.
# Serve this host over RDP: 3389 remote login, 3390 live session (pixel-exact setup)
[group('dx4homelab')]
setup-remote-desktop action="enable":
    #!/usr/bin/env bash
    set -euo pipefail
    SYSD=/var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop
    USRD="$HOME/.local/share/gnome-remote-desktop"
    H="$(hostname -s)"
    fp() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d : | tr A-F a-f; }
    show() {
        echo "Add this host on a client with:  ujust rdp-add-host $H"
        echo "  login   3389  $(sudo cat "$SYSD/rdp-tls.crt" 2>/dev/null | fp || true)"
        echo "  session 3390  $(fp < "$USRD/rdp-tls.crt" 2>/dev/null || true)"
    }
    case "{{ action }}" in
    enable)
        RDP_USER=rdp
        read -rsp "RDP password for '$RDP_USER' on $H (empty = generate): " RDP_PASS || true; echo
        if [[ -z "$RDP_PASS" ]]; then
            RDP_PASS="$(openssl rand -base64 33 | tr -d '/+=' | cut -c1-28)"
            echo "Generated RDP password (shown once): $RDP_PASS"
        fi
        [[ "$RDP_PASS" != *"'"* && "$RDP_PASS" != *'\'* ]] || { echo "Password may not contain ' or \\" >&2; exit 1; }
        TS_DNS="$(tailscale status --self --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -n1 || true)"
        TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
        SAN="DNS:${H},DNS:${H}.lan${TS_DNS:+,DNS:${TS_DNS}}${TS_IP:+,IP:${TS_IP}}"
        mkcert() { # $1=dir, rest=run-as prefix
            local d="$1"; shift
            if ! "$@" test -s "$d/rdp-tls.crt"; then
                "$@" mkdir -p "$d"
                "$@" openssl req -new -x509 -nodes -newkey rsa:4096 -sha256 -days 3650 \
                    -subj "/CN=${H}.lan" -addext "subjectAltName=${SAN}" \
                    -keyout "$d/rdp-tls.key" -out "$d/rdp-tls.crt" 2>/dev/null
                "$@" chmod 600 "$d/rdp-tls.key"
            fi
        }
        CRED="{'username': <'$RDP_USER'>, 'password': <'$RDP_PASS'>}"
        # 1. system daemon: GDM remote login. `grdctl --system rdp set-credentials` (50.2)
        #    accepts stdin but stores nothing; write the GKeyFile entry it would write.
        mkcert "$SYSD" sudo -u gnome-remote-desktop
        sudo grdctl --system rdp set-tls-key  "$SYSD/rdp-tls.key"
        sudo grdctl --system rdp set-tls-cert "$SYSD/rdp-tls.crt"
        printf '[RDP]\ncredentials=%s\n' "$CRED" \
            | sudo -u gnome-remote-desktop tee "$SYSD/credentials.ini" >/dev/null
        sudo chmod 600 "$SYSD/credentials.ini"
        sudo grdctl --system rdp set-port 3389
        sudo grdctl --system rdp enable
        sudo systemctl enable gnome-remote-desktop.service
        sudo systemctl restart gnome-remote-desktop.service
        # 2. user daemon: live session. `grdctl rdp set-credentials` (50.2) segfaults;
        #    store the same libsecret item it would.
        mkcert "$USRD"
        grdctl rdp set-tls-key  "$USRD/rdp-tls.key"
        grdctl rdp set-tls-cert "$USRD/rdp-tls.crt"
        printf '%s' "$CRED" | secret-tool store --label="GNOME Remote Desktop RDP credentials" \
            xdg:schema org.gnome.RemoteDesktop.RdpCredentials
        grdctl rdp set-port 3390
        grdctl rdp disable-port-negotiation
        grdctl rdp disable-view-only
        gsettings set org.gnome.desktop.remote-desktop.rdp screen-share-mode 'mirror-primary'
        grdctl rdp enable
        systemctl --user enable gnome-remote-desktop.service
        systemctl --user restart gnome-remote-desktop.service
        # Verify both daemons actually read the credentials back.
        sudo grdctl --system status --show-credentials 2>/dev/null | grep -q "Username: $RDP_USER" \
            || { echo "! system daemon credentials not readable" >&2; exit 1; }
        grdctl status --show-credentials 2>/dev/null | grep -q "Username: $RDP_USER" \
            || { echo "! user daemon credentials not readable (is the login keyring unlocked?)" >&2; exit 1; }
        echo "✓ RDP enabled on $H (3389 remote login, 3390 live session)."
        show
        ;;
    disable)
        grdctl rdp disable || true
        systemctl --user disable --now gnome-remote-desktop.service || true
        sudo grdctl --system rdp disable || true
        sudo systemctl disable --now gnome-remote-desktop.service || true
        echo "✓ RDP disabled on $H (certificates and credentials kept)."
        ;;
    status)
        echo "system (3389): $(systemctl is-active gnome-remote-desktop.service || true)"
        echo "user   (3390): $(systemctl --user is-active gnome-remote-desktop.service || true)"
        ss -ltnH '( sport = :3389 or sport = :3390 )' | awk '{print "  listening " $4}'
        show
        ;;
    *)
        echo "Usage: ujust setup-remote-desktop [enable|disable|status]" >&2
        exit 1
        ;;
    esac

# Usage: ujust rdp-add-host HOST
# Fetches the fingerprints over ssh when possible, else asks for them (shown by
# `ujust setup-remote-desktop status` on the host).
# Register an RDP host on this client (password -> keyring, TLS fingerprints pinned)
[group('dx4homelab')]
rdp-add-host host:
    #!/usr/bin/env bash
    set -euo pipefail
    H="{{ host }}"; H="${H%%.*}"
    CONF="${XDG_CONFIG_HOME:-$HOME/.config}/dx4homelab/rdp-hosts.conf"
    mkdir -p "$(dirname "$CONF")"; touch "$CONF"
    FPS="$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$H.lan" \
        'f() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr A-F a-f; }
         echo "L=$(sudo -n cat /var/lib/gnome-remote-desktop/.local/share/gnome-remote-desktop/rdp-tls.crt 2>/dev/null | f)"
         echo "S=$(f < ~/.local/share/gnome-remote-desktop/rdp-tls.crt 2>/dev/null)"' \
        2>/dev/null || true)"
    FP_LOGIN="$(sed -n 's/^L=//p' <<< "$FPS")"; FP_SESSION="$(sed -n 's/^S=//p' <<< "$FPS")"
    [[ ${#FP_LOGIN} -eq 64 ]]   || read -rp "sha256 fingerprint of $H login (3389): " FP_LOGIN
    [[ ${#FP_SESSION} -eq 64 ]] || read -rp "sha256 fingerprint of $H session (3390): " FP_SESSION
    for f in "$FP_LOGIN" "$FP_SESSION"; do
        [[ "$f" =~ ^[0-9a-f]{64}$ ]] || { echo "bad fingerprint: $f" >&2; exit 1; }
    done
    read -rsp "RDP password for $H: " P || true; echo
    [[ -n "$P" ]] || { echo "empty password" >&2; exit 1; }
    printf '%s' "$P" | secret-tool store --label="RDP $H (dx4homelab)" service dx4homelab-rdp host "$H" user rdp
    grep -vE "^$H[[:space:]]" "$CONF" > "$CONF.tmp" || true
    printf '%-9s login    3389  %s\n%-9s session  3390  %s\n' "$H" "$FP_LOGIN" "$H" "$FP_SESSION" >> "$CONF.tmp"
    mv -f "$CONF.tmp" "$CONF"
    flatpak info com.freerdp.FreeRDP >/dev/null 2>&1 || flatpak install -y flathub com.freerdp.FreeRDP
    echo "✓ $H added. Connect: ujust rdp-connect $H [login|session]"

# Usage: ujust rdp-connect HOST [login|session] [extra FreeRDP args]
#   login (default) = own session resized to the window; session = the host's live desktop.
# Env: RDP_CODEC=AVC444 (video), RDP_ADDR=<tailscale name>, RDP_SCALE=1.5, RDP_SIZE=80%
# Connect to a registered RDP host, pixel-exact (RemoteFX, 1:1, this display's scale)
[group('dx4homelab')]
rdp-connect host mode="login" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    H="{{ host }}"; MODE="{{ mode }}"; HS="${H%%.*}"
    CONF="${XDG_CONFIG_HOME:-$HOME/.config}/dx4homelab/rdp-hosts.conf"
    read -r PORT FP < <(awk -v h="$HS" -v m="$MODE" '$1==h && $2==m {print $3, $4}' "$CONF" 2>/dev/null) || true
    [[ -n "${FP:-}" ]] || { echo "Unknown host/mode '$HS $MODE' — run: ujust rdp-add-host $HS" >&2; exit 1; }
    PASS="$(secret-tool lookup service dx4homelab-rdp host "$HS")" \
        || { echo "No RDP password in keyring for $HS — run: ujust rdp-add-host $HS" >&2; exit 1; }
    ADDR="${RDP_ADDR:-$H}"; [[ "$ADDR" == *.* ]] || ADDR="$ADDR.lan"
    SCALE="${RDP_SCALE:-$(gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
        --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState \
        | grep -oP '\(-?\d+, -?\d+, \K[0-9.]+(?=, (uint32 )?\d+, true)' | head -n1 || true)}"
    PCT="$(awk -v s="${SCALE:-1}" 'BEGIN{printf "%d", s*100+0.5}')"
    DEV=100; if (( PCT >= 180 )); then DEV=180; elif (( PCT >= 140 )); then DEV=140; fi
    ARGS=("/v:$ADDR:$PORT" "/u:rdp" "/p:$PASS" "/cert:fingerprint:sha256:$FP"
          "/gfx:${RDP_CODEC:-RFX}" "/bpp:32" "/network:lan"
          "/scale-desktop:$PCT" "/scale-device:$DEV"
          "+clipboard" "/sound:sys:pulse" "/auto-reconnect" "/title:$HS ($MODE)")
    [[ "$MODE" == login ]] && ARGS+=("/dynamic-resolution" "/size:${RDP_SIZE:-80%}")
    for a in {{ args }}; do ARGS+=("$a"); done
    # All arguments, password included, go through stdin — never argv.
    printf '%s\n' "${ARGS[@]}" | exec flatpak run --command=sdl-freerdp com.freerdp.FreeRDP /args-from:stdin

# Usage: ujust install-f5go [--config FILE] [--headless] [--no-build] [--help] ...
# Runs scripts/f5goUi/install.sh from a local f5go checkout (default
# ~/workspaces/homelab/f5go, or $F5GO_REPO); every argument goes to it. Only this
# launcher is in the image: the sources and your VPN config stay with you.
# Build + install the f5go VPN panel (f5go-ui, alias f5ui) and its engine service (f5god)
[group('dx4homelab')]
install-f5go *args:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO="${F5GO_REPO:-$HOME/workspaces/homelab/f5go}"
    INSTALLER="$REPO/scripts/f5goUi/install.sh"
    if [[ ! -x "$INSTALLER" ]]; then
        echo "No f5go installer at: $INSTALLER" >&2
        echo "Check out the f5go branch that carries the panel there, or point at another checkout:" >&2
        echo "  F5GO_REPO=/path/to/f5go ujust install-f5go" >&2
        exit 1
    fi
    exec "$INSTALLER" {{ args }}
