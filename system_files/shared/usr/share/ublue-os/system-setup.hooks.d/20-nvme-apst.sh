#!/usr/bin/env bash

source /usr/lib/ublue/setup-services/libsetup.sh

version-script nvme-apst system 1 || exit 0

set -x

# INNOGRIT IG5236 "RainierPC" controllers (HP SSD FX900 Pro, Adata Legend 850,
# and other rebadges) ship a faulty APST implementation: a few seconds after the
# drive goes idle it transitions into its deepest power state and never comes
# back, dropping off the PCIe bus entirely. The kernel logs
#   nvme nvmeN: controller is down; will reset: CSTS=0xffffffff, PCI_STATUS=0x10
#   nvme nvmeN: Does your device have a faulty power saving mode enabled?
# and resets the controller. When the drive holds the root filesystem, a reset
# that does not recover in time takes the filesystem read-only.
#
# Capping the allowed exit latency to 0 stops the kernel enabling APST for it.
# Gated on the controller PCI ID so machines without this silicon keep their
# NVMe power savings.
IG5236_VENDOR="0x1dbe"
IG5236_DEVICE="0x5236"

KARGS=$(rpm-ostree kargs)
NEEDED_KARGS=()
echo "Current kargs: $KARGS"

if [[ ! $KARGS =~ "nvme_core.default_ps_max_latency_us" ]]; then
	for dev in /sys/bus/pci/devices/*; do
		[[ "$(cat "$dev/vendor" 2>/dev/null)" == "$IG5236_VENDOR" ]] || continue
		[[ "$(cat "$dev/device" 2>/dev/null)" == "$IG5236_DEVICE" ]] || continue
		echo "INNOGRIT IG5236 NVMe controller detected at ${dev##*/}, disabling APST deep power states"
		NEEDED_KARGS+=("--append-if-missing=nvme_core.default_ps_max_latency_us=0")
		break
	done
fi

#shellcheck disable=SC2128
if [[ -n "$NEEDED_KARGS" ]]; then
	echo "Found needed karg changes, applying the following: ${NEEDED_KARGS[*]}"
	plymouth display-message --text="Updating kargs - Please wait, this may take a while" || true
	rpm-ostree kargs "${NEEDED_KARGS[@]}" --reboot || exit 1
else
	echo "No karg changes needed"
fi
