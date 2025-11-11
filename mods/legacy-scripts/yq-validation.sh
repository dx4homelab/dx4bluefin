#!/bin/bash
#
# copy original reusable-build.yml to original-workflows
cp -vf original-reusable-build.yml reusable-build.yml
#
yq eval -v -i --from-file yq-mods4reusable-build-yaml.yq reusable-build.yml

echo grep result ...
grep 'TARGET_IMAGE_REGISTRY' -b2 -a2 reusable-build.yml

