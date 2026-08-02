#!/bin/sh
# smartd -M exec handler: forward SMART warnings to the homelab ntfy topic.
# smartd populates SMARTD_* in the environment; see smartd.conf(5).
curl -s -m 10 \
  -H "Title: smartd: ${SMARTD_FAILTYPE:-alert} on ${SMARTD_DEVICE:-?} ($(hostname))" \
  -H "Priority: high" -H "Tags: warning" \
  -d "${SMARTD_FULLMESSAGE:-no message}" \
  https://ntfy.dx4homelab.net/homelab-alerts >/dev/null
