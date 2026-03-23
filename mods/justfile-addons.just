# === dx4homelab custom recipes ===

# Reconcile .gitignore with custom entries from mods/gitignore-addons.txt
[group('Utility')]
reconcile-gitignore:
    #!/usr/bin/bash
    set -eou pipefail
    ADDONS="mods/gitignore-addons.txt"
    GITIGNORE=".gitignore"
    if [[ ! -f "${ADDONS}" ]]; then
        echo "No addons file found at ${ADDONS}"
        exit 0
    fi
    changed=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip empty lines and comments
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        if ! grep -qxF "${line}" "${GITIGNORE}" 2>/dev/null; then
            echo "${line}" >> "${GITIGNORE}"
            echo "Added: ${line}"
            changed=1
        fi
    done < "${ADDONS}"
    if [[ "${changed}" -eq 0 ]]; then
        echo ".gitignore is already up to date"
    else
        echo ".gitignore reconciled with ${ADDONS}"
    fi
