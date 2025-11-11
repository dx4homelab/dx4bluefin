#!/bin/bash

# Function to remove packages from script file
update_script_file() {
    local script_file="$1"
    local array_name="$2"
    local remove_file="/var/home/developer/workspaces/homelab/dx4bluefin/mods/remove_packages_from_excluded_list.txt"
    local temp_file

    # Check if array name is provided
    if [[ -z "$array_name" ]]; then
        echo "Error: Array name must be provided"
        return 1
    fi
    
    # Check if files exist
    if [[ ! -f "$script_file" ]]; then
        echo "Error: Script file $script_file not found"
        return 1
    fi
    if [[ ! -f "$remove_file" ]]; then
        echo "Error: Remove file $remove_file not found"
        return 1
    fi

    # Create temp file
    temp_file=$(mktemp)
    
    # Read packages to remove
    local remove_patterns=()
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
        # Skip empty lines and trim whitespace
        [[ -z "${pkg// }" ]] && continue
        # Add pattern to array with proper indentation and quoting
        remove_patterns+=("^[[:space:]]*\"?${pkg}\"?\$")
    done < "$remove_file"

    # If no patterns found, exit
    if [[ ${#remove_patterns[@]} -eq 0 ]]; then
        echo "No packages to remove found in $remove_file"
        rm -f "$temp_file"
        return 0
    fi

    # Build sed command to remove lines only between array markers
    local sed_cmd="sed -e '/${array_name}=(/,/)/{"
    for pattern in "${remove_patterns[@]}"; do
        # Only apply deletion within the array context and skip the array markers themselves
        sed_cmd+=" -e '/${array_name}=(/n; /)/n; /${pattern}/d;'"
    done
    sed_cmd+=" }"

    # Execute the command
    eval "$sed_cmd '$script_file' > '$temp_file'"

    # Check if changes were made
    if ! cmp -s "$script_file" "$temp_file"; then
        cp "$temp_file" "$script_file"
        # Make the script executable
        chmod +x "$script_file"
        echo "Successfully updated $script_file and made it executable"
    else
        echo "No matching packages found in $script_file"
    fi

    # Cleanup
    rm -f "$temp_file"
}

# Function to remove packages from FEDORA_PACKAGES array
remove_packages_from_excluded_list() {
    local remove_file="/var/home/developer/workspaces/homelab/dx4bluefin/mods/remove_packages_from_excluded_list.txt"
    if [[ -f "$remove_file" ]]; then
        while IFS= read -r pkg || [[ -n "$pkg" ]]; do
            # Skip empty lines and trim whitespace
            [[ -z "${pkg// }" ]] && continue
            # Remove the package from FEDORA_PACKAGES array if it exists
            FEDORA_PACKAGES=("${FEDORA_PACKAGES[@]/$pkg}")
            # Clean up any empty elements that might have been created
            FEDORA_PACKAGES=("${FEDORA_PACKAGES[@]}")
        done < "$remove_file"
    else
        echo "Warning: $remove_file not found"
    fi
}

# Base packages from Fedora repos - common to all versions
FEDORA_PACKAGES=(
    adcli
    adw-gtk3-theme
    adwaita-fonts-all
    bash-color-prompt
    bootc
    borgbackup
    cryfs
    davfs2
    ddcutil
    evtest
    fastfetch
    firewall-config
    fish
    foo2zjs
    fuse-encfs
    gcc
    git-credential-libsecret
    glow
    gnome-shell-extension-appindicator
    gnome-shell-extension-blur-my-shell
    gnome-shell-extension-caffeine
    gnome-shell-extension-dash-to-dock
    gnome-shell-extension-gsconnect
    gnome-tweaks
    gum
    hplip
    ibus-mozc
    ifuse
    igt-gpu-tools
    input-remapper
    iwd
    jetbrains-mono-fonts-all
    krb5-workstation
    libgda
    libgda-sqlite
    libimobiledevice
    libratbag-ratbagd
    libsss_autofs
    libxcrypt-compat
    lm_sensors
    make
    mesa-libGLU
    mozc
    nautilus-gsconnect
    oddjob-mkhomedir
    opendyslexic-fonts
    openssh-askpass
    powertop
    printer-driver-brlaser
    pulseaudio-utils
    python3-pip
    python3-pygit2
    rclone
    restic
    samba
    samba-dcerpc
    samba-ldb-ldap-modules
    samba-winbind-clients
    samba-winbind-modules
    setools-console
    sssd-ad
    sssd-krb5
    sssd-nfs-idmap
    switcheroo-control
    tmux
    usbip
    usbmuxd
    waypipe
    wireguard-tools
    wl-clipboard
    xprop
    zenity
    zsh
)

# Update the script file
update_script_file "/var/home/developer/workspaces/homelab/dx4bluefin/build_files/base/04-packages.sh" "FEDORA_PACKAGES"
