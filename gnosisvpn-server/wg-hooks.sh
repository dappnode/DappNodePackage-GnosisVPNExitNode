#!/bin/bash
# wg-quick PostUp/PreDown hook for wggvpn (`wg-hooks.sh up|down`).
#
# Sets the exit node's forwarding policy in this container's network namespace,
# where gnosis_vpn-server creates the WireGuard interface. VPN clients are
# untrusted, so they may only reach public destinations: not the DAppNode host,
# not other packages on dncore_network, not the LAN behind the host.
#
# Rule order is the guarantee: the private-range jump is first in FORWARD, the
# client ACCEPT is last, and the policy is DROP. Ported from wg-hooks.sh +
# iptables.rules in the gvpn-exit-os appliance image, which a DAppNode package
# can't reuse as-is because it never sees the host's network namespace (see
# README).
set -euo pipefail

WG_IF="wggvpn"
PRIVATE_CHAIN="GVPN_PRIVATE"

usage() {
  echo "usage: ${0} up|down <client-cidr> <server-address> [uplink]" >&2
  exit 64
}

[[ $# -ge 3 ]] || usage
action="$1"
client_cidr="$2"
server_address="$3"
# The container's DAppNode-managed interface; the host NATs it the rest of the
# way out.
uplink="${4:-eth0}"

# Destinations a VPN client must never reach: RFC1918 (the LAN and Docker's
# default network pool), CGNAT, link-local, loopback, "this network" and
# multicast/reserved.
PRIVATE_NETS=(
  10.0.0.0/8
  172.16.0.0/12
  192.168.0.0/16
  100.64.0.0/10
  169.254.0.0/16
  127.0.0.0/8
  0.0.0.0/8
  224.0.0.0/3
  # DAppNode's dncore_network (every package and the dappmanager). It is not in
  # RFC1918, so without this entry the dappmanager stays reachable.
  172.33.0.0/16
)

PRIVATE_JUMP=(FORWARD -i "${WG_IF}" -j "${PRIVATE_CHAIN}")
CLIENT_ACCEPT=(FORWARD -i "${WG_IF}" -o "${uplink}" -j ACCEPT)
# shellcheck disable=SC2054  # the comma belongs to --ctstate, not the array
RETURN_ACCEPT=(FORWARD -o "${WG_IF}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT)
# The GnosisVPN client pings the WireGuard server address (`connection.ping`,
# default 10.128.0.1) to verify the tunnel. Accept only that echo request;
# everything else from clients is dropped, the control API on port 8000 included.
PING_ACCEPT=(INPUT -s "${client_cidr}" -d "${server_address}/32" -i "${WG_IF}" -p icmp -m icmp --icmp-type 8 -j ACCEPT)
CLIENT_DROP=(INPUT -i "${WG_IF}" -j DROP)
NAT_RULE=(POSTROUTING -s "${client_cidr}" -o "${uplink}" -j MASQUERADE)

# The subnet this container is attached to, whatever DAppNode assigned, so
# isolation doesn't rely on the static entry above. Read from the kernel's
# route for the interface.
own_network() {
  local network
  # awk reads all input, so ip never hits a closed pipe and pipefail only
  # reports a real ip failure.
  if ! network="$(ip -4 route show dev "${uplink}" proto kernel scope link | awk 'NR == 1 { print $1 }')"; then
    echo "wg-hooks: cannot read the routes of ${uplink}" >&2
    return 1
  fi
  if [[ -z "${network}" ]]; then
    echo "wg-hooks: no IPv4 subnet on ${uplink}; only the static ranges are dropped" >&2
    return 0
  fi
  printf '%s\n' "${network}"
}

private_nets() {
  local own
  own="$(own_network)" || return 1
  printf '%s\n' "${PRIVATE_NETS[@]}" "${own}" | awk 'NF && !seen[$0]++'
}

up() {
  # gnosis_vpn-server can bring the interface up again without PreDown (hard
  # kill, interface sync), so clear old rules first to avoid duplicates.
  down

  # Rules for a missing interface match nothing and raise no error, which
  # would silently leave the control API reachable. Refuse instead.
  if ! ip link show dev "${WG_IF}" >/dev/null 2>&1; then
    echo "wg-hooks: ${WG_IF} does not exist; refusing to install forwarding rules" >&2
    exit 1
  fi

  # Fail closed first: a client packet arriving mid-install is dropped.
  iptables -P FORWARD DROP
  iptables -N "${PRIVATE_CHAIN}" 2>/dev/null || iptables -F "${PRIVATE_CHAIN}"
  # Collected first, not read from a process substitution (bash ignores its
  # failure): a range that can't be determined must stop the hook.
  local nets net
  nets="$(private_nets)"
  while IFS= read -r net; do
    iptables -A "${PRIVATE_CHAIN}" -d "${net}" -j DROP
  done <<<"${nets}"
  # -I without a rule number inserts at the head, ahead of anything else.
  iptables -I "${PRIVATE_JUMP[@]}"
  iptables -A "${CLIENT_ACCEPT[@]}"
  iptables -A "${RETURN_ACCEPT[@]}"
  iptables -I "${CLIENT_DROP[@]}"
  iptables -I "${PING_ACCEPT[@]}"
  iptables -t nat -A "${NAT_RULE[@]}"
}

down() {
  iptables -t nat -D "${NAT_RULE[@]}" 2>/dev/null || true
  iptables -D "${PING_ACCEPT[@]}" 2>/dev/null || true
  iptables -D "${CLIENT_DROP[@]}" 2>/dev/null || true
  iptables -D "${RETURN_ACCEPT[@]}" 2>/dev/null || true
  iptables -D "${CLIENT_ACCEPT[@]}" 2>/dev/null || true
  iptables -D "${PRIVATE_JUMP[@]}" 2>/dev/null || true
  iptables -F "${PRIVATE_CHAIN}" 2>/dev/null || true
  iptables -X "${PRIVATE_CHAIN}" 2>/dev/null || true
  # FORWARD stays DROP on purpose: nothing forwards without the interface, and
  # a hook that failed half way must not leave the namespace open.
}

main() {
  case "${action}" in
    up) up ;;
    down) down ;;
    *) usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
