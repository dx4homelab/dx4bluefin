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

# Resolve the newest kernel NVRA where EVERY akmods sub-image this flavor needs
# coexists on the channel. Used to pin the build past upstream akmods channel
# promotion skew (e.g. akmods-nvidia-open lagging akmods/akmods-zfs on
# coreos-stable for a given kernel, which fails `verify-container`).
# Mirrors the build recipe's akmods_flavor selection and verify-container
# required-image set exactly, so the computed pin is precisely the set the build
# will cosign-verify. Prints the full pin (X.Y.Z-REL.fcNN.ARCH) on stdout, or an
# empty string (+ stderr note) if no common kernel exists — caller then builds
# unpinned (today's behaviour). Per-flavor: `main` is only constrained by
# akmods+akmods-zfs, so it keeps the newest kernel; only nvidia-open steps back.
[group('Utility')]
[private]
safe-kernel image="bluefin" tag="latest" flavor="main" arch="x86_64":
    #!/usr/bin/bash
    set -eou pipefail
    # akmods flavor — mirror the build recipe (Justfile `build`, AKMODS Flavor block)
    if [[ "{{ flavor }}" =~ hwe ]]; then
        akmods_flavor="bazzite"
    elif [[ "{{ tag }}" =~ stable ]]; then
        akmods_flavor="coreos-stable"
    elif [[ "{{ tag }}" =~ beta ]]; then
        akmods_flavor="main"
    else
        akmods_flavor="main"
    fi
    fed="$({{ just }} fedora_version '{{ image }}' '{{ tag }}' '{{ flavor }}' '')"
    prefix="${akmods_flavor}-${fed}-"
    # required image set — mirror the build recipe's verify-container conditionals
    required=("akmods")
    if [[ "${akmods_flavor}" =~ coreos ]]; then
        required+=("akmods-zfs")
    fi
    if [[ "{{ flavor }}" =~ nvidia-open ]]; then
        required+=("akmods-nvidia-open")
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    # Per image: collect the kernels published for this channel+arch (prefix stripped).
    for img in "${required[@]}"; do
        skopeo list-tags --retry-times 3 "docker://ghcr.io/ublue-os/${img}" \
            | jq -r --arg p "${prefix}" --arg a ".{{ arch }}" \
                '.Tags[] | select(startswith($p)) | select(endswith($a)) | ltrimstr($p)' \
            | LC_ALL=C sort -u > "${tmp}/${img}.set"
    done
    # Intersection across all required images (a kernel present in all N sets
    # appears exactly N times), then newest by version order. `sort -V` is
    # MANDATORY: plain lexical sort returns 7.0.9 over 7.0.11 ('9' > '1').
    pin="$(cat "${tmp}"/*.set | LC_ALL=C sort | uniq -c \
        | awk -v n="${#required[@]}" '$1 == n {print $2}' | sort -V | tail -1)"
    if [[ -z "${pin}" ]]; then
        echo "safe-kernel: no common kernel across ${required[*]} at ${prefix}*.{{ arch }}" >&2
        echo ""
        exit 0
    fi
    echo "${pin}"
