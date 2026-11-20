#!/usr/bin/env bash
# Checks that a VPN client tunnelled through this exit node can't reach private
# addresses: first that the image runs the hook, then how the rules behave in a
# throwaway privileged container (see test/firewall-check.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# wg-quick runs PostUp/PreDown from the rendered config, so a template that
# stops calling the hook ships an unfiltered exit node. Without
# --sync-wg-interface gnosis_vpn-server never runs wg-quick at all.
grep -q '^PostUp = /app/wg-hooks.sh up ' gnosisvpn-server/wggvpn.conf.tpl
grep -q '^PreDown = /app/wg-hooks.sh down ' gnosisvpn-server/wggvpn.conf.tpl
grep -q '^COPY .*wg-hooks.sh' gnosisvpn-server/Dockerfile
grep -q -- '--sync-wg-interface' gnosisvpn-server/entrypoint.sh
echo "ok: wggvpn.conf.tpl runs the hook, the image ships it, and the server syncs the interface"
# wg-quick brings wggvpn up before PostUp runs the hook, so FORWARD must be
# DROP before the server starts.
grep -q '^iptables -P FORWARD DROP$' gnosisvpn-server/entrypoint.sh
echo "ok: entrypoint.sh closes FORWARD before the server brings wggvpn up"

if [ -n "${FIREWALL_TEST_IMAGE:-}" ]; then
  # Tests the image's own /app/wg-hooks.sh, bash, iproute2 and iptables, so
  # nothing is mounted or installed. --entrypoint skips entrypoint.sh, which
  # would start the server.
  docker run --rm --privileged --entrypoint bash \
    -v "${PWD}/test/firewall-check.sh:/firewall-check.sh:ro" \
    "${FIREWALL_TEST_IMAGE}" \
    /firewall-check.sh
else
  docker run --rm --privileged \
    -v "${PWD}/gnosisvpn-server/wg-hooks.sh:/app/wg-hooks.sh:ro" \
    -v "${PWD}/test/firewall-check.sh:/firewall-check.sh:ro" \
    alpine:3 \
    sh -c 'apk add --no-cache --quiet bash iptables iproute2 ipset >/dev/null && bash /firewall-check.sh'
fi
