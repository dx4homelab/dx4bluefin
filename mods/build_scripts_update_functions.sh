#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

# Function to update build scripts with remove_excluded_packages command
update_04_packages_sh_to_customize_excluded_packages() {

    local target_file="build_files/base/04-packages.sh"

    # Source the script containing remove_excluded_packages function
    local source_line='source "mods/build_scripts_update_functions.sh"'
    
    # Combine source and function call with a semicolon to ensure sequential execution
    local insert_line=''"$source_line"'; remove_packages_from_excluded_list'

    # Check if target file exists
    if [[ ! -f "$target_file" ]]; then
        echo "Error: Target file $target_file does not exist"
        return 1
    fi
    
    # Insert the line after the comment about removing excluded packages
    # Prevent duplicate insertion: skip if the exact line already exists
    if grep -F -q "$insert_line" "$target_file"; then
        echo "Line already exists in $target_file, skipping insertion"
        return 0
    fi

    sed -i '/#.*Remove excluded packages if they are installed/a '"$insert_line" "$target_file"
    rc=$?

    if [[ $rc -eq 0 ]]; then
        # Ensure the updated script is executable
        if chmod +x "$target_file"; then
            echo "Successfully updated $target_file and set executable permission"
        else
            echo "Updated $target_file but failed to set executable permission"
            return 1
        fi
    else
        echo "Error: Failed to update $target_file"
        return 1
    fi
}

# Function to remove items from EXCLUDED_PACKAGES array using a file

remove_packages_from_excluded_list() {

    local file_with_packages="mods/remove_packages_from_excluded_list.txt"

    local new_array=()
    
    # Check if file exists
    if [[ ! -f "$file_with_packages" ]]; then
        echo "Error: File $file_with_packages does not exist"
        return 1
    fi
    
    # Read packages to remove into an array
    local items=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace and add to array
        items+=("${line//[[:space:]]/}")
    done < "$file_with_packages"
    
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


# Function to add packages to FEDORA_PACKAGES array from a file
add_packages_to_fedora_packages_array() {

    local file_with_packages="mods/add_packages.txt"

    # Check if file exists
    if [[ ! -f "$file_with_packages" ]]; then
        echo "Error: File $file_with_packages does not exist"
        return 1
    fi
    
    # Read packages to add into an array
    local items=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Trim whitespace and add to array
        items+=("${line//[[:space:]]/}")
    done < "$file_with_packages"
    
    # Add packages to FEDORA_PACKAGES array
    if [[ "${#items[@]}" -gt 0 ]]; then
        FEDORA_PACKAGES+=("${items[@]}")
        echo "Added ${#items[@]} packages to FEDORA_PACKAGES array"
    else
        echo "No valid packages found in $file_with_packages to add"
    fi
}


# Function to update 04-packages.sh to expand FEDORA_PACKAGES array
update_04_packages_sh_to_expand_fedora_packages() {
    local target_file="build_files/base/04-packages.sh"
    
    # Source line and function call
    local source_line='source "mods/build_scripts_update_functions.sh"'
    local insert_line=''"$source_line"'; add_packages_to_fedora_packages_array'
    
    # Check if target file exists
    if [[ ! -f "$target_file" ]]; then
        echo "Error: Target file $target_file does not exist"
        return 1
    fi
    
    # Insert the line after the FEDORA_PACKAGES array body (after its closing ')')
    echo "Attempting to insert after FEDORA_PACKAGES array..."
    echo "Target file: $target_file"
    echo "Insert line: $insert_line"
    
    # First check if the line is already present
    if grep -q "$insert_line" "$target_file"; then
        echo "Line already exists in file, skipping insertion"
        return 0
    fi
    
    awk -v ins="$insert_line" '
    BEGIN { in_array=0; found=0 }
    /^FEDORA_PACKAGES=\(/ { in_array=1 }
    /^[[:space:]]*\)[[:space:]]*$/ && in_array { 
        in_array=0;
        found=1;
        print;
        print ins;
        next
    }
    { print }
    END {
        if (!found) {
            print "Warning: Could not find end of FEDORA_PACKAGES array" > "/dev/stderr"
            exit 1
        }
    }' "$target_file" > "${target_file}.tmp"
    
    # Debug: show the difference
    echo "Changes to be made:"
    diff "$target_file" "${target_file}.tmp" || true
    
    # Only move if changes were made
    if cmp -s "${target_file}.tmp" "$target_file"; then
        echo "Warning: No changes were made to the file"
        rm "${target_file}.tmp"
        return 1
    else
        # Move new file into place and make it executable. Use a single conditional so we can
        # report failure if either operation fails.
        if mv "${target_file}.tmp" "$target_file" && chmod +x "$target_file"; then
            echo "Successfully updated $target_file and set executable permission"
        else
            echo "Error: Failed to update or set executable permission on $target_file"
            # Clean up temp file if it still exists
            [[ -f "${target_file}.tmp" ]] && rm -f "${target_file}.tmp"
            return 1
        fi
    fi
}

