#!/usr/bin/bash

echo "::group:: ===$(basename "$0")==="

echo "===full path for this script $ ===" 

# to call this script in github action add the following line:
# bash mods/update_build_scripts.sh

source "${GITHUB_WORKSPACE}/build_files/mods/build_scripts_update_functions.sh"

# calling the function to insert line into 04-packages.sh to customize excluded packages array
update_04_packages_sh_to_customize_excluded_packages

update_04_packages_sh_to_expand_fedora_packages

echo "::endgroup::"
