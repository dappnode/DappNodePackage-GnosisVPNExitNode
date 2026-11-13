#!/bin/bash
# Runs inside a throwaway privileged container (see test/traffic.sh): the
# blocklist and the per-peer shaping the exit node applies to forwarded traffic.
# A veth pair named wggvpn stands in for WireGuard, a second namespace for a VPN
# client, and a third for a public host that answers, so probes are really
# forwarded across wggvpn instead of only checked against a ruleset.
set -euo pipefail

HOOK=/app/wg-hooks.sh
BLOCKLIST=/app/gvpn-blocklist-update.sh
WG_IF=wggvpn
IFB_IF=ifb-gvpn
BLOCKLIST_SET=gvpn-blocklist
CLIENT_CIDR=10.128.0.0/24
SERVER_ADDRESS=10.128.0.1
CLIENT_ADDRESS=10.128.0.2
# The uplink, and a public host behind it that answers. Both are TEST-NET
# addresses: public as far as the rules are concerned, and never routed.
UPLINK=eth1
PUBLIC_HOST=203.0.113.9
PUBLIC_SUBNET=203.0.113.0/24
# Blocked by the feed below, and not otherwise private, so only the blocklist
# can stop it.
BLOCKED_HOST=203.0.113.77
CLIENT_NS=vpn-client
CLIENT_IF=veth-client
INTERNET_NS=internet
INTERNET_IF=inet0
CACHE_DIR=/tmp/blocklist
GOOD_FEED=/tmp/feed-good
SHORT_FEED=/tmp/feed-short
EXTRA_FEED=/tmp/feed-extra

# What entrypoint.sh derives from WIREGUARD_CIDR and MAX_SLOTS and exports for
# wg-hooks.sh. Rates are the shipped defaults, so tc does not warn about small
# quanta.
export GVPN_PEER_SUBNET_PREFIX=10.128.0
export GVPN_PEER_MIN_OCTET=2
export GVPN_PEER_MAX_OCTET=5
# Deliberately not the shipped defaults, so a rate the setup wizard sets has to
# reach the classes for these checks to pass.
export GVPN_PEER_RATE_KBIT=7000
export GVPN_PEER_SHAPING_AGGREGATE_KBIT=18000
export GVPN_BLOCKLIST_CACHE_DIR="${CACHE_DIR}"
export GVPN_BLOCKLIST_MIN_ENTRIES=3
# Local feeds only: the refresher runs curl, and the sandbox has no route off
# the machine.
export GVPN_BLOCKLIST_FEEDS="file://${GOOD_FEED}"

failures=0
pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

setup() {
  # A public host behind the uplink that answers pings.
  ip netns add "${INTERNET_NS}"
  ip link add "${UPLINK}" type veth peer name "${INTERNET_IF}"
  ip link set "${INTERNET_IF}" netns "${INTERNET_NS}"
  ip addr add 198.51.100.10/24 dev "${UPLINK}"
  ip link set "${UPLINK}" up
  ip route replace "${PUBLIC_SUBNET}" dev "${UPLINK}"
  ip route replace default dev "${UPLINK}"
  ip -n "${INTERNET_NS}" addr add 198.51.100.9/24 dev "${INTERNET_IF}"
  ip -n "${INTERNET_NS}" addr add "${PUBLIC_HOST}/24" dev "${INTERNET_IF}"
  ip -n "${INTERNET_NS}" link set "${INTERNET_IF}" up
  ip -n "${INTERNET_NS}" link set lo up
  ip -n "${INTERNET_NS}" route add default via 198.51.100.10

  # The tunnel, and the client behind it.
  ip netns add "${CLIENT_NS}"
  ip link add "${WG_IF}" type veth peer name "${CLIENT_IF}"
  ip link set "${CLIENT_IF}" netns "${CLIENT_NS}"
  ip addr add "${SERVER_ADDRESS}/24" dev "${WG_IF}"
  ip link set "${WG_IF}" up
  ip -n "${CLIENT_NS}" addr add "${CLIENT_ADDRESS}/24" dev "${CLIENT_IF}"
  ip -n "${CLIENT_NS}" link set "${CLIENT_IF}" up
  ip -n "${CLIENT_NS}" link set lo up
  ip -n "${CLIENT_NS}" route add default via "${SERVER_ADDRESS}"

  # Three entries: one that matters (the blocked host) and two that only get
  # the feed over the minimum-entry threshold.
  cat >"${GOOD_FEED}" <<EOF
${BLOCKED_HOST}/32
192.0.2.0/24
198.18.0.0/15
EOF
  # One entry: below GVPN_BLOCKLIST_MIN_ENTRIES, so a refresh must reject it.
  printf '%s/32\n' 203.0.113.78 >"${SHORT_FEED}"
  # A second feed, to check that several feeds are merged.
  printf '%s/32\n' 203.0.113.79 >"${EXTRA_FEED}"
}

# Packet count of the rule in CHAIN whose `iptables -S -v` line contains SPEC,
# with the `-c PACKETS BYTES` counters stripped. Counters are zeroed before
# every probe, so the count belongs to that probe.
counter() {
  local chain="$1" spec="$2"
  iptables -t filter -S "${chain}" -v | awk -v want="${spec}" -v prefix="-A ${chain} " '
    {
      line = $0
      pkts = "missing"
      if (match(line, / -c [0-9]+ [0-9]+/)) {
        split(substr(line, RSTART + 4, RLENGTH - 4), counts, " ")
        pkts = counts[1]
        line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
      }
      # This chain only, so a spec cannot match a rule somewhere else.
      if (index(line, prefix) == 1 && index(line, want) > 0) { print pkts; found = 1; exit }
    }
    END { if (!found) print "missing" }
  ' || true
}

expect_matched() {
  local chain="$1" spec="$2" description="$3" pkts
  pkts="$(counter "${chain}" "${spec}")"
  if [ "${pkts}" = missing ]; then
    fail "${description}: no rule '${spec}' in ${chain}"
  elif [ "${pkts}" -lt 1 ]; then
    fail "${description}: rule '${spec}' in ${chain} matched ${pkts} packets"
  else
    pass "${description}"
  fi
}

expect_unmatched() {
  local chain="$1" spec="$2" description="$3" pkts
  pkts="$(counter "${chain}" "${spec}")"
  if [ "${pkts}" = missing ]; then
    fail "${description}: no rule '${spec}' in ${chain}"
  elif [ "${pkts}" -ne 0 ]; then
    fail "${description}: rule '${spec}' in ${chain} matched ${pkts} packets"
  else
    pass "${description}"
  fi
}

# probe_from_client DESTINATION: succeeds when the public host answered.
probe_from_client() {
  ip netns exec "${CLIENT_NS}" ping -c 1 -W 1 "$1" >/dev/null 2>&1
}

zero_counters() {
  local chain
  for chain in FORWARD INPUT; do
    iptables -t filter -Z "${chain}"
  done
}

# `|| true` so a missing set reports as a failed check instead of aborting the
# run under `set -e`.
blocklist_entries() {
  ipset list "${BLOCKLIST_SET}" 2>/dev/null | awk '/Number of entries/ { print $4 }' || true
}

# expect_entries COUNT DESCRIPTION
expect_entries() {
  local expected="$1" description="$2" actual
  actual="$(blocklist_entries)"
  if [ "${actual}" = "${expected}" ]; then
    pass "${description}"
  else
    fail "${description}: set holds '${actual:-nothing}', expected ${expected}"
  fi
}

# Packets sent through class CLASSID of DEV, from `tc -s class show`.
class_packets() {
  tc -s class show dev "$1" classid "$2" | awk '/Sent [0-9]+ bytes/ { for (i = 1; i < NF; i++) if ($i == "bytes") { print $(i + 1); exit } }' || true
}

expect_class_packets() {
  local dev="$1" classid="$2" description="$3" pkts
  pkts="$(class_packets "${dev}" "${classid}")"
  if [ -z "${pkts}" ]; then
    fail "${description}: no class ${classid} on ${dev}"
  elif [ "${pkts}" -lt 1 ]; then
    fail "${description}: class ${classid} on ${dev} saw ${pkts} packets"
  else
    pass "${description}"
  fi
}

setup

# --- the hook installs the blocklist drops and the shaping -------------------
"${HOOK}" up "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}"

if ipset list "${BLOCKLIST_SET}" >/dev/null 2>&1; then
  pass "the hook creates ${BLOCKLIST_SET}, so its DROP rules resolve"
else
  fail "the hook did not create ${BLOCKLIST_SET}"
fi

expect_entries 0 "an empty blocklist blocks nothing"

# Both directions, and both ahead of the ACCEPT that lets clients out.
# `|| true` throughout: a missing rule must report as a failed check rather
# than abort the run, so a regression shows all of its symptoms at once.
blocked_rule="$(iptables -t filter -S FORWARD | grep -nF -- "-m set --match-set ${BLOCKLIST_SET} dst -j DROP" | cut -d: -f1 || true)"
accepted_rule="$(iptables -t filter -S FORWARD | grep -nF -- "-i ${WG_IF} -o ${UPLINK} -j ACCEPT" | cut -d: -f1 || true)"
if [ -n "${blocked_rule}" ] && [ -n "${accepted_rule}" ] && [ "${blocked_rule}" -lt "${accepted_rule}" ]; then
  pass "the client -> blocklisted destination drop precedes the client ACCEPT"
else
  fail "the client -> blocklisted destination drop is missing or behind the client ACCEPT"
fi
if iptables -t filter -S FORWARD | grep -qF -- "-o ${WG_IF} -m set --match-set ${BLOCKLIST_SET} src -j DROP"; then
  pass "blocklisted sources are dropped on their way back to clients"
else
  fail "no FORWARD drop for blocklisted sources returning to clients"
fi

# --- a refresh replaces the set, atomically, and the cache follows ------------
if "${BLOCKLIST}" --refresh >/dev/null 2>&1; then
  pass "--refresh exits 0"
else
  fail "--refresh failed"
fi
expect_entries 3 "a good feed populates the set"
if [ -s "${CACHE_DIR}/blocklist.cidr" ]; then
  pass "a good feed is cached for the next boot"
else
  fail "no cache file after a successful refresh"
fi

# --- several feeds are merged, space- or newline-separated -------------------
GVPN_BLOCKLIST_FEEDS="file://${GOOD_FEED} file://${EXTRA_FEED}" "${BLOCKLIST}" --refresh >/dev/null 2>&1 || true
expect_entries 4 "space-separated feeds are merged"
GVPN_BLOCKLIST_FEEDS="$(printf 'file://%s\nfile://%s' "${GOOD_FEED}" "${EXTRA_FEED}")" \
  "${BLOCKLIST}" --refresh >/dev/null 2>&1 || true
expect_entries 4 "newline-separated feeds are merged"
"${BLOCKLIST}" --refresh >/dev/null 2>&1 || true
expect_entries 3 "the configured feeds replace the merged set"

zero_counters
if probe_from_client "${BLOCKED_HOST}"; then
  fail "the client reached a blocklisted destination"
else
  pass "the client cannot reach a blocklisted destination"
fi
expect_matched FORWARD "-m set --match-set ${BLOCKLIST_SET} dst -j DROP" "the blocklist drop matched it"
expect_unmatched FORWARD "-i ${WG_IF} -o ${UPLINK} -j ACCEPT" "the blocklisted packet was not forwarded"

# --- a feed that is too short is rejected, the previous set stays -------------
GVPN_BLOCKLIST_FEEDS="file://${SHORT_FEED}" "${BLOCKLIST}" --refresh >/dev/null 2>&1 || true
expect_entries 3 "a feed below the minimum entry count keeps the previous set"

zero_counters
probe_from_client 203.0.113.78 >/dev/null 2>&1 || true
expect_unmatched FORWARD "-m set --match-set ${BLOCKLIST_SET} dst -j DROP" "the rejected feed's entry is not blocked"

# --- an unreachable feed falls back to the cache, not to an empty set --------
GVPN_BLOCKLIST_FEEDS="file:///tmp/does-not-exist" "${BLOCKLIST}" --refresh >/dev/null 2>&1 || true
expect_entries 3 "an unreachable feed falls back to the cached list"

# --- the cache reloads the set without the network ---------------------------
ipset flush "${BLOCKLIST_SET}"
expect_entries 0 "the set is empty after a flush"
"${BLOCKLIST}" --from-cache >/dev/null 2>&1 || true
expect_entries 3 "--from-cache reloads the cached list"

# --- short prefixes are accepted for the 224/3 bogon range only ---------------
# ipset normalizes a network, so 224.0.0.0/1 would block 128.0.0.0/1, and a /0
# fails the whole restore.
parsed="$(printf '%s\n' 224.0.0.0/3 224.0.0.0/1 240.0.0.0/2 240.0.0.0/0 0.0.0.0/1 1.2.3.0/24 \
  | bash -c "source ${BLOCKLIST}; parse_feed" || true)"
if [ "${parsed}" = "$(printf '%s\n' 224.0.0.0/3 1.2.3.0/24)" ]; then
  pass "the parser keeps 224.0.0.0/3 and drops every other prefix shorter than /8"
else
  fail "the parser kept: ${parsed//$'\n'/ }"
fi

# --- repeated refreshes in one process leave no temp files --------------------
# --loop never exits, so its EXIT trap cannot be what cleans up after a refresh.
tmp_root="$(mktemp -d)"
TMPDIR="${tmp_root}" bash -c "source ${BLOCKLIST}; refresh; refresh" >/dev/null 2>&1 || true
leftover="$(find "${tmp_root}" -mindepth 1 | wc -l)"
if [ "${leftover}" -eq 0 ]; then
  pass "each refresh removes its temp files"
else
  fail "${leftover} temp file(s) left behind by two refreshes"
fi
rm -rf "${tmp_root}"

# --- a client still reaches public destinations ------------------------------
zero_counters
if probe_from_client "${PUBLIC_HOST}"; then
  pass "the client still reaches a public host"
else
  fail "the client could not reach a public host"
fi
expect_unmatched FORWARD "-m set --match-set ${BLOCKLIST_SET} dst -j DROP" "the public host is not blocklisted"

# --- every peer has a shaped class in both directions ------------------------
class_count="$(tc class show dev "${WG_IF}" | grep -c 'class htb 1:' || true)"
if [ "${class_count}" -eq 6 ]; then
  pass "one class per peer, plus the aggregate and the default class"
else
  fail "${class_count} classes on ${WG_IF}, expected 6 (aggregate, default, 4 peers)"
fi
if tc class show dev "${WG_IF}" classid 1:1 | grep -q 'rate 18Mbit'; then
  pass "the aggregate class caps the node-wide rate"
else
  fail "the aggregate class is not capped at 18Mbit"
fi
if tc class show dev "${WG_IF}" classid 1:2 | grep -q 'ceil 7Mbit'; then
  pass "each peer class is capped at the per-peer rate"
else
  fail "peer class 1:2 is not capped at 7Mbit"
fi
if [ "$(tc qdisc show dev "${WG_IF}" | grep -c fq_codel)" -eq 5 ]; then
  pass "every class has an fq_codel leaf"
else
  fail "fq_codel leaves are missing from ${WG_IF}"
fi
if ip link show "${IFB_IF}" >/dev/null 2>&1 && tc class show dev "${IFB_IF}" classid 1:2 | grep -q 'ceil 7Mbit'; then
  pass "uploads are shaped on ${IFB_IF}, mirrored from ${WG_IF}"
else
  fail "no shaped ${IFB_IF} for upload traffic"
fi

# The probes above already moved packets through peer .2: the reply left via
# wggvpn (classified by destination) and the request arrived on the mirror
# (classified by source).
expect_class_packets "${WG_IF}" 1:2 "download traffic to peer .2 is shaped"
expect_class_packets "${IFB_IF}" 1:2 "upload traffic from peer .2 is shaped"

# --- down removes the drops and the shaping, and keeps the set --------------
"${HOOK}" down "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}"

if iptables -t filter -S FORWARD | grep -qF -- "-m set --match-set ${BLOCKLIST_SET}"; then
  fail "FORWARD still references ${BLOCKLIST_SET} after down"
else
  pass "down removes the blocklist drops"
fi
expect_entries 3 "down keeps the blocklist set, so the refresher keeps working"
if tc qdisc show dev "${WG_IF}" | grep -q 'htb'; then
  fail "the shaping tree on ${WG_IF} survived down"
else
  pass "down removes the shaping tree"
fi
if ip link show "${IFB_IF}" >/dev/null 2>&1; then
  fail "${IFB_IF} survived down"
else
  pass "down removes ${IFB_IF}"
fi

if [ "${failures}" -ne 0 ]; then
  echo "--- final state ---" >&2
  iptables -t filter -S >&2
  ipset list "${BLOCKLIST_SET}" >&2 2>/dev/null || true
  tc qdisc show dev "${WG_IF}" >&2
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all traffic checks passed"
