#!/bin/bash
# wg-quick PostUp/PreDown hook for wggvpn (`wg-hooks.sh up|down`).
#
# gnosis_vpn-server creates the WireGuard interface inside this container's own
# network namespace, so that namespace is where the exit node's forwarding
# policy has to live. Without it a VPN client's packets are masqueraded to this
# container's address and then take the same path as the container's own
# egress traffic: to the DAppNode host, to every other package on
# dncore_network, and to the LAN behind the host. A VPN client is an untrusted
# third party, so only publicly addressed destinations are allowed through.
#
# Ordering is the guarantee: the private-range jump sits at the head of
# FORWARD and the client ACCEPT at the tail, so a client packet is checked
# against the private ranges before any rule can accept it, and the FORWARD
# policy is DROP. Mirrors wg-hooks.sh + iptables.rules in the gvpn-exit-os
# appliance image, which cannot be reused as-is because a DAppNode package
# never sees the host's network namespace (see README).
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
# The container's only uplink: its DAppNode-managed interface, whose traffic
# the host then NATs the rest of the way out.
uplink="${4:-eth0}"

# Destinations a VPN client must never reach. RFC1918 covers the LAN behind the
# DAppNode and every package network Docker allocates from its default pool;
# the rest are CGNAT, link-local, loopback, "this network" and
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
  # DAppNode's dncore_network, which every package and the dappmanager itself
  # are attached to. It is deliberately not in RFC1918, so the RFC1918 entries
  # above do not cover it and the dappmanager would stay reachable without it.
  172.33.0.0/16
)

PRIVATE_JUMP=(FORWARD -i "${WG_IF}" -j "${PRIVATE_CHAIN}")
CLIENT_ACCEPT=(FORWARD -i "${WG_IF}" -o "${uplink}" -j ACCEPT)
# shellcheck disable=SC2054  # the comma belongs to --ctstate, not the array
RETURN_ACCEPT=(FORWARD -o "${WG_IF}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT)
# The GnosisVPN client verifies the tunnel by pinging the WireGuard server
# address (client `connection.ping`, default 10.128.0.1) before it reports the
# connection established. Accept exactly that echo request; everything else
# from VPN clients stays dropped, the control API on port 8000 included.
PING_ACCEPT=(INPUT -s "${client_cidr}" -d "${server_address}/32" -i "${WG_IF}" -p icmp -m icmp --icmp-type 8 -j ACCEPT)
CLIENT_DROP=(INPUT -i "${WG_IF}" -j DROP)
NAT_RULE=(POSTROUTING -s "${client_cidr}" -o "${uplink}" -j MASQUERADE)

# The network this container is attached to, whatever subnet DAppNode gave it,
# so isolation does not depend on the entry above staying correct. The kernel's
# own route for the interface is its configured subnet.
own_network() {
  local network
  network="$(ip -4 route show dev "${uplink}" proto kernel scope link | awk '{ print $1; exit }')"
  if [[ -z "${network}" ]]; then
    echo "wg-hooks: no IPv4 subnet on ${uplink}; only the static ranges are dropped" >&2
    return 0
  fi
  printf '%s\n' "${network}"
}

private_nets() {
  local net
  printf '%s\n' "${PRIVATE_NETS[@]}" "$(own_network)" | awk 'NF && !seen[$0]++'
}

up() {
  # gnosis_vpn-server can bring the interface up again without a PreDown in
  # between (hard kill, interface sync), so start from a clean slate instead
  # of stacking duplicate rules.
  down

  # A rule for an interface that does not exist matches nothing and complains
  # about nothing, which would leave the control API reachable from the tunnel
  # with every rule in place and no error to show for it. Refuse to install a
  # policy that cannot apply instead.
  if ! ip link show dev "${WG_IF}" >/dev/null 2>&1; then
    echo "wg-hooks: ${WG_IF} does not exist; refusing to install forwarding rules" >&2
    exit 1
  fi

  # Fail closed before anything else: a client packet that arrives while the
  # rules below are still being installed is dropped rather than forwarded.
  iptables -P FORWARD DROP
  iptables -N "${PRIVATE_CHAIN}" 2>/dev/null || iptables -F "${PRIVATE_CHAIN}"
  local net
  while IFS= read -r net; do
    iptables -A "${PRIVATE_CHAIN}" -d "${net}" -j DROP
  done < <(private_nets)
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
  # FORWARD stays DROP on purpose: with the interface gone nothing forwards
  # anyway, and a hook that failed half way must not leave the namespace open.
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
