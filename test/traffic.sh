#!/usr/bin/env bash
# Checks the blocklist and the per-peer shaping the exit node applies to
# forwarded traffic: first that the image ships both scripts and wires them up,
# then how they behave in a throwaway privileged container (see
# test/traffic-check.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# wg-hooks.sh runs the shaping script from PostUp/PreDown, and entrypoint.sh
# loads the cached blocklist before the server starts and refreshes it in the
# background. An image that stopped shipping either would fail here.
grep -q '^COPY .*gvpn-blocklist-update.sh' gnosisvpn-server/Dockerfile
grep -q '^COPY .*gvpn-peer-shaping.sh' gnosisvpn-server/Dockerfile
grep -q 'gvpn-blocklist-update.sh --from-cache' gnosisvpn-server/entrypoint.sh
grep -q 'gvpn-blocklist-update.sh --loop &' gnosisvpn-server/entrypoint.sh
grep -q 'GVPN_SHAPING_BIN:-/app/gvpn-peer-shaping.sh' gnosisvpn-server/wg-hooks.sh

# The rates and the feeds are set from the DAppNode UI, so their setup-wizard
# fields have to exist.
for field in GVPN_PEER_RATE_KBIT GVPN_PEER_SHAPING_AGGREGATE_KBIT \
  GVPN_BLOCKLIST_FEEDS GVPN_BLOCKLIST_REFRESH_INTERVAL_S; do
  if ! grep -qx "      name: ${field}" setup-wizard.yml; then
    echo "setup-wizard.yml has no ${field} field" >&2
    exit 1
  fi
done
echo "ok: the image ships both scripts, wires them up, and the wizard exposes their settings"

if [ -n "${TRAFFIC_TEST_IMAGE:-}" ]; then
  # Tests the image's own /app, so nothing is mounted or installed. --entrypoint
  # skips entrypoint.sh, which would start the server.
  docker run --rm --privileged --entrypoint bash \
    -v "${PWD}/test/traffic-check.sh:/traffic-check.sh:ro" \
    "${TRAFFIC_TEST_IMAGE}" \
    /traffic-check.sh
else
  docker run --rm --privileged \
    -v "${PWD}/gnosisvpn-server:/app:ro" \
    -v "${PWD}/test/traffic-check.sh:/traffic-check.sh:ro" \
    alpine:3 \
    sh -c 'apk add --no-cache --quiet bash iptables iproute2 ipset curl iputils >/dev/null && bash /traffic-check.sh'
fi
