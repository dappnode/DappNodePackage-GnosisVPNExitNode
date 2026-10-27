#!/usr/bin/env bash
# Checks that a VPN client tunnelled through this exit node cannot reach
# private addresses: first that the shipped image actually runs the hook, then
# the behaviour of the rules themselves in a throwaway privileged container
# (test/firewall-check.sh explains why it needs its own network namespace).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${FIREWALL_TEST_IMAGE:-alpine:3}"

# PostUp/PreDown in the rendered config are what wg-quick runs, so a template
# that stopped calling the hook would silently ship an unfiltered exit node -
# and without --sync-wg-interface gnosis_vpn-server never runs wg-quick at all.
grep -q '^PostUp = /app/wg-hooks.sh up ' gnosisvpn-server/wggvpn.conf.tpl
grep -q '^PreDown = /app/wg-hooks.sh down ' gnosisvpn-server/wggvpn.conf.tpl
grep -q 'wg-hooks.sh' gnosisvpn-server/Dockerfile
grep -q -- '--sync-wg-interface' gnosisvpn-server/entrypoint.sh
echo "ok: wggvpn.conf.tpl runs the hook, the image ships it, and the server syncs the interface"

docker run --rm --privileged \
  -v "${PWD}/gnosisvpn-server:/app:ro" \
  -v "${PWD}/test/firewall-check.sh:/firewall-check.sh:ro" \
  "${IMAGE}" \
  sh -c 'apk add --no-cache --quiet bash iptables iproute2 iputils >/dev/null && bash /firewall-check.sh'
