#!/bin/bash
# Stream the kernel log and push NVMe/PCIe failure signatures to the homelab
# ntfy topic. This exists because SMART is provably blind to the failure mode
# that matters on this fleet: the INNOGRIT IG5236 (HP FX900 Pro) drops off the
# PCIe bus with a PASSED SMART page (fury4dx, 2026-07: ten dropouts, zero SMART
# indications). The kernel log is the only early-warning channel — correctable
# RxErr/AER storms preceded the fatal drops by days.
#
# Serialized to at most one push per 15s so an AER storm (observed: 1006
# suppressed callbacks in one burst) cannot flood the topic.
NTFY_URL="https://ntfy.dx4homelab.net/homelab-alerts"

journalctl -kf --since now \
  | grep --line-buffered -E "controller is down|RxErr|aer_ratelimit|Uncorrectable.*error|nvme.*: I/O.*timeout" \
  | grep --line-buffered -v "AER: enabled" \
  | while read -r line; do
      curl -s -m 10 \
        -H "Title: $(hostname): NVMe/PCIe event" \
        -H "Priority: urgent" -H "Tags: rotating_light" \
        -d "$line" "$NTFY_URL" >/dev/null
      sleep 15
    done
