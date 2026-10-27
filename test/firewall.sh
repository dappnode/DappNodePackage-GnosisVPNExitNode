#!/usr/bin/env bash
# Checks that a VPN client tunnelled through this exit node cannot reach
# private addresses: first that the shipped image actually runs the hook, then
# the behaviour of the rules themselves in a throwaway privileged container
# (test/firewall-check.sh explains why it needs its own network namespace).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# PostUp/PreDown in the rendered config are what wg-quick runs, so a template
# that stopped calling the hook would silently ship an unfiltered exit node -
# and without --sync-wg-interface gnosis_vpn-server never runs wg-quick at all.
grep -q '^PostUp = /app/wg-hooks.sh up ' gnosisvpn-server/wggvpn.conf.tpl
grep -q '^PreDown = /app/wg-hooks.sh down ' gnosisvpn-server/wggvpn.conf.tpl
grep -q '^COPY .*wg-hooks.sh' gnosisvpn-server/Dockerfile
grep -q -- '--sync-wg-interface' gnosisvpn-server/entrypoint.sh
echo "ok: wggvpn.conf.tpl runs the hook, the image ships it, and the server syncs the interface"
# wg-quick brings wggvpn up before PostUp runs the hook, so FORWARD has to be
# DROP before the server starts, not only once the hook has run.
grep -q '^iptables -P FORWARD DROP$' gnosisvpn-server/entrypoint.sh
echo "ok: entrypoint.sh closes FORWARD before the server brings wggvpn up"

if [ -n "${FIREWALL_TEST_IMAGE:-}" ]; then
  # The built gnosisvpn-server image: its own /app/wg-hooks.sh and its own
  # bash, iproute2 and iptables are what is under test, so nothing is mounted
  # over them or installed. --entrypoint skips entrypoint.sh, which would start
  # the server instead.
  docker run --rm --privileged --entrypoint bash \
    -v "${PWD}/test/firewall-check.sh:/firewall-check.sh:ro" \
    "${FIREWALL_TEST_IMAGE}" \
    /firewall-check.sh
else
  docker run --rm --privileged \
    -v "${PWD}/gnosisvpn-server/wg-hooks.sh:/app/wg-hooks.sh:ro" \
    -v "${PWD}/test/firewall-check.sh:/firewall-check.sh:ro" \
    alpine:3 \
    sh -c 'apk add --no-cache --quiet bash iptables iproute2 >/dev/null && bash /firewall-check.sh'
fi
