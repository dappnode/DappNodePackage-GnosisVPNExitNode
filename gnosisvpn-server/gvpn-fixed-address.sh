#!/bin/bash
# Claims gnosisvpn-server's fixed address on dncore_network (`gvpn-fixed-address.sh [--loop]`).
#
# DAppNode doesn't let a package pin a container IP, so this adds ADDRESS to the container's
# own dncore_network interface. Every container on that network, node included, then reaches
# it directly. Docker doesn't know about ADDRESS, so it is never taken from anything that
# already answers for it.
#
#   (no argument)  claim once; fail if ADDRESS can't be claimed
#   --loop         claim again every GVPN_FIXED_ADDRESS_INTERVAL seconds if ADDRESS is gone,
#                  e.g. after a network reconnect
set -euo pipefail

# Must match GNOSISVPN_SERVER_IP in node's entrypoint.sh.
ADDRESS=172.33.255.254
INTERVAL="${GVPN_FIXED_ADDRESS_INTERVAL:-30}"

usage() {
  echo "usage: ${0} [--loop]" >&2
  exit 64
}

log() { echo "gvpn-fixed-address: $*"; }

claimed() { [ -n "$(ip -4 -o addr show to "${ADDRESS}/32")" ]; }

claim() {
  local route dev dad on_link=' dev ([^ ]+)'
  claimed && return 0

  # The interface on ADDRESS's subnet: "172.33.255.254 dev eth0 src 172.33.0.4 uid 0".
  if ! route="$(ip -4 route get "${ADDRESS}" 2>&1)" || [[ "${route}" == *" via "* ]] ||
    [[ ! "${route}" =~ ${on_link} ]]; then
    log "no attached network holds ${ADDRESS} (${route})" >&2
    return 1
  fi
  dev="${BASH_REMATCH[1]}"

  if ! dad="$(arping -D -c 2 -w 3 -I "${dev}" "${ADDRESS}" 2>&1)"; then
    log "${ADDRESS} is already in use on ${dev}, not claiming it: ${dad//$'\n'/ }" >&2
    return 1
  fi
  if ! ip addr add "${ADDRESS}/32" dev "${dev}"; then
    log "could not add ${ADDRESS} to ${dev}" >&2
    return 1
  fi
  # Neighbours may still have a previous gnosisvpn-server container's MAC for ADDRESS.
  arping -U -q -c 2 -I "${dev}" -s "${ADDRESS}" "${ADDRESS}" || true
  log "claimed ${ADDRESS} on ${dev}"
}

case "${1:-}" in
"") claim ;;
--loop)
  while sleep "${INTERVAL}"; do
    claim || true
  done
  ;;
*) usage ;;
esac
