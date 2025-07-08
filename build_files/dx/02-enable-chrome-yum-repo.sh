#!/bin/bash

set -oue pipefail 
# Part of an attempt to add Google Chrome in the usual way.
echo "Fixing google-chrome yum repo"
sed -i '/enabled/d' /etc/yum.repos.d/google-chrome.repo 
echo "enabled=1" >> /etc/yum.repos.d/google-chrome.repo

# This does not appear to be necessary, since at this point there are no
# Google keys in the RPM database.  Will be deleted soon.

# First, delete all old keys; see https://github.com/rpm-software-management/rpm/issues/2577
echo "Fixing issues with Google GPG keys"
set +oue
rpm -qa gpg-pubkey* --qf '%{NAME}-%{VERSION}-%{RELEASE} %{PACKAGER}\n' | grep 'linux-packages-keymaster@google.com' | sed 's/ .*$//' | xargs
GOOGLE_PUBKEYS_RPMS=$(rpm -qa gpg-pubkey* --qf '%{NAME}-%{VERSION}-%{RELEASE} %{PACKAGER}\n' | grep 'linux-packages-keymaster@google.com' | sed 's/ .*$//' | xargs)
set -oue
echo "Installed pubkeys RPMS are $GOOGLE_PUBKEYS_RPMS"
if [ -n "$GOOGLE_PUBKEYS_RPMS" ]; then
    echo "Removing packages $GOOGLE_PUBKEYS_RPMS"
    rpm -e $GOOGLE_PUBKEYS_RPMS
fi

# We need to download and install the Google signing keys separately, we can't trust
# rpm-ostree to do it cleanly from the yum repo directly.
# Possibly related to https://github.com/rpm-software-management/rpm/issues/2577

echo "Downloading Google Signing Key ..."

curl https://dl.google.com/linux/linux_signing_key.pub > /tmp/linux_signing_key.pub

echo "Importing Google Signing Key ..."

rpm --import /tmp/linux_signing_key.pub

set +e

echo "Done importing Google Signing Key."

echo "making /usr/lib/opt/google ..."

mkdir -p /usr/lib/opt/google || echo "mkdir -p /usr/lib/opt/google failed, but that's OK if it already exists"

echo "Done making /usr/lib/opt/google."

echo "making /opt ..."

mkdir -p /opt || echo "mkdir -p /opt failed, but that's OK if it already exists"

echo "Done making /opt."

echo "Making /opt/google link ..."

ln -sf /usr/lib/opt/google /opt/google || echo "making link /opt/google failed, but that's OK if it already exists"

echo "Done creating Google directory structure."

set -oue pipefail 
