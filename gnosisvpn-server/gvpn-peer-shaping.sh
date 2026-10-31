#!/bin/bash
# Per-peer traffic shaping for the exit node (`gvpn-peer-shaping.sh up|down`).
# Invoked by wg-hooks.sh from the wggvpn PostUp/PreDown hooks. Ported from
# gvpn-exit-os (itself from gnosis_vpn-infrastructure, roles/gnosisvpn-server):
# the Ansible variables arrive here as the environment entrypoint.sh exports.
#
# Shapes (queues) instead of policing (dropping): each peer gets an HTB class
# capped at the per-peer ceil with an fq_codel leaf, so TCP settles smoothly at
# the cap instead of sawtoothing on hard packet loss. The parent class enforces
# the node-wide aggregate cap.
#
# Directions:
# - download (server -> peers): tree on wggvpn egress, classified by dst IP
# - upload (peers -> internet): wggvpn ingress mirrored to an ifb device, tree
#   on the ifb classified by src IP. Shaping has to happen on the wggvpn side
#   because the uplink only ever sees post-MASQUERADE addresses.
#
# Peers are assigned GVPN_PEER_MIN_OCTET..GVPN_PEER_MAX_OCTET dynamically by
# gnosis_vpn-server, so all classes in that range are provisioned up front and
# packets are steered by a u32 hash table on the last octet (O(1) per packet).
# .1 is the server itself and .255 the broadcast address; both stay unshaped in
# the default class. The range must stay within one /24 (this script only
# varies the last octet), which entrypoint.sh enforces when it derives it.
set -euo pipefail

WG_IF="wggvpn"
IFB_IF="ifb-gvpn"
# Derived by entrypoint.sh from WIREGUARD_CIDR and MAX_SLOTS, the same way it
# derives config.toml's pool and the rendered WireGuard address. Only `up`
# needs them, so `down` still works when they are absent.
SUBNET_PREFIX="${GVPN_PEER_SUBNET_PREFIX:-}"
PEER_MIN="${GVPN_PEER_MIN_OCTET:-}"
PEER_MAX="${GVPN_PEER_MAX_OCTET:-}"
PEER_RATE_KBIT="${GVPN_PEER_RATE_KBIT:-10000}"
AGGREGATE_KBIT="${GVPN_PEER_SHAPING_AGGREGATE_KBIT:-25000}"
# Guaranteed per-peer share; 253 x 56kbit stays below the aggregate so HTB
# guarantees remain honest. The ceil is what actually caps a peer.
PEER_GUARANTEE_KBIT=56
# fq_codel tuned to signal congestion by queueing delay rather than drops: a
# dropped packet triggers an end-to-end retransmit across the mixnet, while a
# delayed packet lets the mixnet and TCP adapt to the slower pace. target
# tolerates ~250ms of standing queue (on top of the ~250ms mixnet peer RTT)
# before codel starts dropping, and ECN-capable flows are marked instead of
# dropped. Small quantum for inter-flow latency at low rates.
FQ_CODEL_OPTS="target 250ms interval 1000ms quantum 300 ecn"
# HTB derives a class's quantum from its rate and the parent's r2q, and warns on
# every class when the rates span too wide a range for one r2q (a 56kbit
# guarantee next to a 25Mbit aggregate does). Pin it at one MTU instead, so the
# container log isn't full of tc warnings on every interface sync.
HTB_QUANTUM=1500

usage() {
  echo "usage: ${0} up|down" >&2
  exit 64
}

# Map a peer's last octet to the hex minor id of its class (1:<hex>).
peer_classid() {
  printf '%x' "${1}"
}

# IPv4 header offset of the address to classify on: dst for download (traffic
# leaving wggvpn toward peers), src for upload (peer traffic entering wggvpn,
# seen on the ifb mirror).
match_offset() {
  case "${1}" in
    dst) echo 16 ;;
    src) echo 12 ;;
    *)
      echo "unknown match direction: ${1}" >&2
      return 1
      ;;
  esac
}

# Print the full tc command batch for one device. ${2} is the match direction
# (dst|src). Consumed via `tc -batch -` so the whole tree is built in one
# netlink session instead of ~800 tc invocations.
emit_tree() {
  local dev="${1}" dir="${2}" offset octet minor
  offset="$(match_offset "${dir}")"

  echo "qdisc add dev ${dev} root handle 1: htb default fff"
  echo "class add dev ${dev} parent 1: classid 1:1 htb rate ${AGGREGATE_KBIT}kbit ceil ${AGGREGATE_KBIT}kbit quantum ${HTB_QUANTUM}"
  # non-peer traffic (server address, broadcasts) shares the aggregate uncapped
  echo "class add dev ${dev} parent 1:1 classid 1:fff htb rate 1000kbit ceil ${AGGREGATE_KBIT}kbit quantum ${HTB_QUANTUM}"
  echo "qdisc add dev ${dev} parent 1:fff fq_codel ${FQ_CODEL_OPTS}"
  echo "filter add dev ${dev} parent 1: prio 1 handle 2: protocol ip u32 divisor 256"
  echo "filter add dev ${dev} parent 1: prio 1 protocol ip u32 ht 800:: match ip ${dir} ${SUBNET_PREFIX}.0/24 hashkey mask 0x000000ff at ${offset} link 2:"

  for octet in $(seq "${PEER_MIN}" "${PEER_MAX}"); do
    minor="$(peer_classid "${octet}")"
    echo "class add dev ${dev} parent 1:1 classid 1:${minor} htb rate ${PEER_GUARANTEE_KBIT}kbit ceil ${PEER_RATE_KBIT}kbit quantum ${HTB_QUANTUM}"
    echo "qdisc add dev ${dev} parent 1:${minor} fq_codel ${FQ_CODEL_OPTS}"
    echo "filter add dev ${dev} parent 1: prio 1 protocol ip u32 ht 2:${minor}: match ip ${dir} ${SUBNET_PREFIX}.${octet}/32 flowid 1:${minor}"
  done
}

# tc and the ifb/sch_* modules come from the DAppNode host's kernel, which this
# container cannot load modules into. A host without them gets an unshaped exit
# node and this error in the log, not a dead package.
up() {
  # download: replace whatever root qdisc is present (idempotent re-runs)
  tc qdisc del dev "${WG_IF}" root 2>/dev/null || true
  emit_tree "${WG_IF}" dst | tc -batch -

  # upload: mirror wggvpn ingress onto the ifb and shape there
  ip link add "${IFB_IF}" type ifb 2>/dev/null || true
  ip link set "${IFB_IF}" up
  tc qdisc del dev "${IFB_IF}" root 2>/dev/null || true
  emit_tree "${IFB_IF}" src | tc -batch -
  tc qdisc del dev "${WG_IF}" ingress 2>/dev/null || true
  tc qdisc add dev "${WG_IF}" handle ffff: ingress
  tc filter add dev "${WG_IF}" parent ffff: prio 1 protocol ip u32 match u32 0 0 action mirred egress redirect dev "${IFB_IF}"
}

down() {
  tc qdisc del dev "${WG_IF}" ingress 2>/dev/null || true
  tc qdisc del dev "${WG_IF}" root 2>/dev/null || true
  ip link del "${IFB_IF}" 2>/dev/null || true
}

require_params() {
  local missing=()
  [[ -n "${SUBNET_PREFIX}" ]] || missing+=("GVPN_PEER_SUBNET_PREFIX")
  [[ -n "${PEER_MIN}" ]] || missing+=("GVPN_PEER_MIN_OCTET")
  [[ -n "${PEER_MAX}" ]] || missing+=("GVPN_PEER_MAX_OCTET")
  if [[ "${#missing[@]}" -ne 0 ]]; then
    echo "not set: ${missing[*]} (derived by entrypoint.sh)" >&2
    return 1
  fi
  local value
  for value in "${PEER_RATE_KBIT}" "${AGGREGATE_KBIT}"; do
    if ! [[ "${value}" =~ ^[1-9][0-9]*$ ]]; then
      echo "shaping rates must be positive integers in kbit/s, got '${value}'" >&2
      return 1
    fi
  done
}

main() {
  case "${1:-}" in
    up)
      require_params || exit 64
      up
      ;;
    down) down ;;
    *) usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
