#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

# Function to update build scripts with remove_excluded_packages command
update_04_packages_sh_to_customize_excluded_packages() {

    local target_file="build_files/base/04-packages.sh"

    # Source the script containing remove_excluded_packages function
    local source_line='source "mods/build_scripts_update_functions.sh"'
    
    local file_with_packages="mods/remove_packages_from_excluded_list.txt"

    # Combine source and function call with a semicolon to ensure sequential execution
    local insert_line=''"$source_line"'; [[ -f "'"$file_with_packages"'" ]] && remove_packages_from_excluded_list "'"$file_with_packages"'"'

    # Check if target file exists
    if [[ ! -f "$target_file" ]]; then
        echo "Error: Target file $target_file does not exist"
        return 1
    fi
    
    # Insert the line after the comment about removing excluded packages
    sed -i '/#.*Remove excluded packages if they are installed/a '"$insert_line" "$target_file"
    
    if [[ $? -eq 0 ]]; then
        echo "Successfully updated $target_file"
    else
        echo "Error: Failed to update $target_file"
        return 1
    fi
}

# Function to remove items from EXCLUDED_PACKAGES array using a file

remove_packages_from_excluded_list() {
    # Check if exactly one argument is provided
    if [[ $# -ne 1 ]]; then
        echo "Error: Function requires exactly one parameter (file path)"
        echo "Usage: remove_packages_from_excluded_list path/to/file.txt"
        return 1
    fi

    local file_path="$1"
    local new_array=()
    
    # Check if file exists
    if [[ ! -f "$file_path" ]]; then
        echo "Error: File $file_path does not exist"
        return 1
    fi
    
    # Read packages to remove into an array
    local items=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace and add to array
        items+=("${line//[[:space:]]/}")
    done < "$file_path"
    
    # Filter out packages that should be removed
    for pkg in "${EXCLUDED_PACKAGES[@]}"; do
        local keep=true
        for item in "${items[@]}"; do
            if [[ "$pkg" == "$item" ]]; then
                keep=false
                break
            fi
        done
        if [[ "$keep" == true ]]; then
            new_array+=("$pkg")
        fi
    done
    EXCLUDED_PACKAGES=("${new_array[@]}")
}

# Example: Remove packages listed in the file
# Create a file 'packages-to-remove.txt' with content:
# firefox
# firefox-langpacks
#
# remove_packages_from_excluded_list "mods/remove_packages_from_excluded_list.txt"


# Function to add packages to FEDORA_PACKAGES array from a file
add_packages_to_fedora_packages_array() {
    # Check if exactly one argument is provided
    if [[ $# -ne 1 ]]; then
        echo "Error: Function requires exactly one parameter (file path)"
        echo "Usage: add_packages_to_fedora_packages_array path/to/file.txt"
        return 1
    fi

    local file_path="$1"
    
    # Check if file exists
    if [[ ! -f "$file_path" ]]; then
        echo "Error: File $file_path does not exist"
        return 1
    fi
    
    # Read packages to add into an array
    local items=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace and add to array
        items+=("${line//[[:space:]]/}")
    done < "$file_path"
    
    # Add packages to FEDORA_PACKAGES array
    if [[ "${#items[@]}" -gt 0 ]]; then
        FEDORA_PACKAGES+=("${items[@]}")
        echo "Added ${#items[@]} packages to FEDORA_PACKAGES array"
    else
        echo "No valid packages found in $file_path"
    fi
}

# Function to update 04-packages.sh to expand FEDORA_PACKAGES array
update_04_packages_sh_to_expand_fedora_packages() {
    local target_file="build_files/base/04-packages.sh"
    local file_with_packages="mods/add_packages.txt"
    
    # Source line and function call
    local source_line='source "mods/build_scripts_update_functions.sh"'
    local insert_line=''"$source_line"'; [[ -f "'"$file_with_packages"'" ]] && add_packages_to_fedora_packages_array "'"$file_with_packages"'"'
    
    # Check if target file exists
    if [[ ! -f "$target_file" ]]; then
        echo "Error: Target file $target_file does not exist"
        return 1
    fi
    
    # Insert the line after the FEDORA_PACKAGES array body (after its closing ')')
    echo "Attempting to insert after FEDORA_PACKAGES array..."
    echo "Target file: $target_file"
    echo "Insert line: $insert_line"
    
    awk -v ins="$insert_line" '
    BEGIN { in_array=0 }
    /^FEDORA_PACKAGES=\(/ { in_array=1; print; next }
    in_array && /^\)/ { 
        print;
        print ins;
        in_array=0;
        next
    }
    { print }' "$target_file" > "${target_file}.tmp"
    
    # Debug: show the difference
    echo "Changes to be made:"
    diff "$target_file" "${target_file}.tmp" || true
    
    # Only move if changes were made
    if cmp -s "${target_file}.tmp" "$target_file"; then
        echo "Warning: No changes were made to the file"
        rm "${target_file}.tmp"
        return 1
    else
        mv "${target_file}.tmp" "$target_file"
    fi

    if [[ $? -eq 0 ]]; then
        echo "Successfully updated $target_file"
    else
        echo "Error: Failed to update $target_file"
        return 1
    fi
}

# Example usage:
# Create a file 'add_packages.txt' with one package name per line:
# package1
# package2
# Then the packages will be added to FEDORA_PACKAGES array