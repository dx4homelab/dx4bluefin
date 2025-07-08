#!/bin/bash
#
# copy original reusable-build.yml to original-workflows
cp -v original-reusable-build.yml original-workflows/reusable-build.yml
#
yq eval -v -i --from-file yq-mods4reusable-build-yaml.yq original-workflows/reusable-build.yml

# restore original packages.json before running yq
# cp original-packages.json original-bluefin/packages.json

# testing package.json modifification using transformation from --from-file
# export ADD_PACKAGES="add-packages.json"
# yq eval -v -i --from-file yq-mods4package-json.yq original-bluefin/packages.json

# testing package.json modifification using transformation from --from-file
# using filename &fileindex
# yq eval -v --from-file yq-mods4package-json.yq yq-mods4package-json.yq original-packages.json add-packages.json >original-bluefin/packages.json

# add-packages.json 

# validated: adding jlumbroso/free-disk-space@main step to reusable-build.yml
# yq -i '.jobs.build_container.steps = [{"name": "Free Disk Space", "uses": "jlumbroso/free-disk-space@main", "with": {"tool-cache": true}}] + .jobs.build_container.steps' .github/workflows/reusable-build.yml


        #   yq -i '.env.IMAGE_REGISTRY = "ghcr.io/ublue-os"' .github/workflows/reusable-build.yml
        #   yq -i 'del( .jobs.build_iso )' .github/workflows/reusable-build.yml
        #   yq -i 'del( .jobs.build_container.strategy.matrix.image_flavor[] | select( . == "*asus*" or . == "*surface*"  ) )' .github/workflows/reusable-build.yml
        #   yq -i '(.jobs.build_container.steps[] | select(.id == "registry_case") | .with.string) = "ghcr.io/${{ github.repository_owner }}"' .github/workflows/reusable-build.yml
        #   yq -i '.jobs.build_container.steps = [{"name": "Free Disk Space", "uses": "jlumbroso/free-disk-space@main", "with": {"tool-cache": true}}] + .jobs.build_container.steps' .github/workflows/reusable-build.yml
        #   yq -i 'del( .jobs.build-iso.strategy.matrix.image_flavor[] | select( . == "*asus*" or . == "*surface*"  ) )' .github/workflows/reusable-build-iso.yml
          
        # rm -f .github/workflows/reusable-build-iso.yml
