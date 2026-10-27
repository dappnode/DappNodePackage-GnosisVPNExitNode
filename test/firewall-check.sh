#!/bin/bash
# Runs inside a throwaway privileged container (see test/firewall.sh), so the
# rules wg-hooks.sh installs land in a network namespace the test can discard.
# A veth pair named wggvpn stands in for WireGuard and a second namespace for a
# VPN client, so probes are really forwarded across wggvpn, not just checked
# against the ruleset.
set -euo pipefail

HOOK=/app/wg-hooks.sh
WG_IF=wggvpn
CHAIN_PRIVATE=GVPN_PRIVATE
CLIENT_CIDR=10.128.0.0/24
SERVER_ADDRESS=10.128.0.1
CLIENT_ADDRESS=10.128.0.2
# The uplink is a dummy on a public-looking range, so the subnet wg-hooks.sh
# derives from it can't be confused with a static private range.
UPLINK=eth1
UPLINK_SUBNET=198.51.100.0/24
# TEST-NET-3, routed out the uplink: public but never reachable, so a probe to
# it can only prove that FORWARD accepted it.
PUBLIC_PROBE=203.0.113.1
CLIENT_NS=vpn-client
CLIENT_IF=veth-client

# Every destination the hook should drop, including the uplink subnet it
# derives at runtime.
DROPPED_NETS=(
  10.0.0.0/8
  172.16.0.0/12
  192.168.0.0/16
  100.64.0.0/10
  169.254.0.0/16
  127.0.0.0/8
  0.0.0.0/8
  224.0.0.0/3
  172.33.0.0/16
  "${UPLINK_SUBNET}"
)

failures=0
pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

setup() {
  # The uplink is the default route, like eth0 on the real exit node, so a
  # private destination the hook missed would leave through it and match the
  # client ACCEPT.
  ip link add "${UPLINK}" type dummy
  ip addr add 198.51.100.10/24 dev "${UPLINK}"
  ip link set "${UPLINK}" up
  ip route replace default dev "${UPLINK}"

  # The tunnel, and the client behind it.
  ip netns add "${CLIENT_NS}"
  ip link add "${WG_IF}" type veth peer name "${CLIENT_IF}"
  ip link set "${CLIENT_IF}" netns "${CLIENT_NS}"
  ip addr add "${SERVER_ADDRESS}/24" dev "${WG_IF}"
  ip link set "${WG_IF}" up
  ip -n "${CLIENT_NS}" addr add "${CLIENT_ADDRESS}/24" dev "${CLIENT_IF}"
  ip -n "${CLIENT_NS}" link set "${CLIENT_IF}" up
  ip -n "${CLIENT_NS}" link set lo up
  # Full tunnel: all client traffic goes through wggvpn (the client's
  # wireguard.allowed_ips defaults to 0.0.0.0/0).
  ip -n "${CLIENT_NS}" route add default via "${SERVER_ADDRESS}"

  # An address outside the uplink and tunnel networks, standing in for the
  # exit node's other interfaces.
  OTHER_ADDRESS="$(ip -4 -o addr show dev eth0 | awk '{ print $4 }' | cut -d/ -f1)"
  [ -n "${OTHER_ADDRESS}" ] || {
    echo "no IPv4 address on eth0 to probe the control API on" >&2
    exit 1
  }
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
  '
}

# expect_rule_count CHAIN SPEC COUNT DESCRIPTION
expect_rule_count() {
  local chain="$1" spec="$2" count="$3" description="$4" actual
  actual="$(iptables -t filter -S "${chain}" | grep -cF -- "${spec}" || true)"
  if [ "${actual}" -eq "${count}" ]; then
    pass "${description}"
  else
    fail "${description}: ${actual} rules match '${spec}' in ${chain}, expected ${count}"
  fi
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

# expect_no_private_drop DESCRIPTION: none of the private-range rules matched.
expect_no_private_drop() {
  local description="$1" net pkts
  for net in "${DROPPED_NETS[@]}"; do
    pkts="$(counter "${CHAIN_PRIVATE}" "-d ${net} -j DROP")"
    if [ "${pkts}" = missing ]; then
      fail "${description}: no rule for ${net} in ${CHAIN_PRIVATE}"
      return 0
    elif [ "${pkts}" -ne 0 ]; then
      fail "${description}: ${CHAIN_PRIVATE} dropped ${pkts} packets to ${net}"
      return 0
    fi
  done
  pass "${description}"
}

# probe_from_client DESTINATION: one ICMP echo sent as the VPN client.
probe_from_client() {
  ip netns exec "${CLIENT_NS}" ping -c 1 -W 1 "$1" >/dev/null 2>&1 || true
}

zero_counters() {
  local chain
  for chain in FORWARD INPUT "${CHAIN_PRIVATE}"; do
    iptables -t filter -Z "${chain}"
  done
}

setup

# --- the hook installs isolation, and installing it twice does not stack ------
"${HOOK}" up "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}"
"${HOOK}" up "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}"

forward_policy="$(iptables -t filter -S FORWARD | sed -n '1p')"
if [ "${forward_policy}" = "-P FORWARD DROP" ]; then
  pass "FORWARD policy is DROP"
else
  fail "FORWARD policy is '${forward_policy}', expected '-P FORWARD DROP'"
fi

# hoprd opens new connections to the control API and WireGuard port from
# dncore_network via eth0, so INPUT must stay ACCEPT or the exit node breaks.
# Only the tunnel is filtered.
input_policy="$(iptables -t filter -S INPUT | sed -n '1p')"
if [ "${input_policy}" = "-P INPUT ACCEPT" ]; then
  pass "INPUT policy is ACCEPT, so hoprd can still reach the exit node"
else
  fail "INPUT policy is '${input_policy}', expected '-P INPUT ACCEPT'"
fi

# One jump and one accept, not a stack of them from the second `up`.
expect_rule_count FORWARD "-i ${WG_IF}" 2 "FORWARD has exactly one jump and one client accept"
expect_rule_count INPUT "-i ${WG_IF}" 2 "INPUT has exactly one ping accept and one client drop"

first_forward_rule="$(iptables -t filter -S FORWARD | sed -n '2p')"
if [ "${first_forward_rule}" = "-A FORWARD -i ${WG_IF} -j ${CHAIN_PRIVATE}" ]; then
  pass "the private-range jump is the first FORWARD rule"
else
  fail "first FORWARD rule is '${first_forward_rule}', expected the ${CHAIN_PRIVATE} jump"
fi

for net in "${DROPPED_NETS[@]}"; do
  if iptables -t filter -S "${CHAIN_PRIVATE}" | grep -qxF -- "-A ${CHAIN_PRIVATE} -d ${net} -j DROP"; then
    pass "${CHAIN_PRIVATE} drops ${net}"
  else
    fail "${CHAIN_PRIVATE} does not drop ${net}"
  fi
done

masquerade_count="$(iptables -t nat -S POSTROUTING | grep -cF -- "-s ${CLIENT_CIDR} -o ${UPLINK} -j MASQUERADE" || true)"
if [ "${masquerade_count}" -eq 1 ]; then
  pass "exactly one MASQUERADE rule for ${CLIENT_CIDR}"
else
  fail "found ${masquerade_count} MASQUERADE rules for ${CLIENT_CIDR}, expected 1"
fi

# --- a VPN client cannot reach private destinations ---------------------------
zero_counters
probe_from_client 192.168.1.1
expect_matched "${CHAIN_PRIVATE}" "-d 192.168.0.0/16" "client to a LAN address hits the private drop"
expect_unmatched FORWARD "-i ${WG_IF} -o ${UPLINK} -j ACCEPT" "client to a LAN address is not forwarded"

zero_counters
probe_from_client 172.33.0.1
expect_matched "${CHAIN_PRIVATE}" "-d 172.33.0.0/16" "client to the DAppNode host hits the private drop"
expect_unmatched FORWARD "-i ${WG_IF} -o ${UPLINK} -j ACCEPT" "client to the DAppNode host is not forwarded"

zero_counters
probe_from_client 198.51.100.20
expect_matched "${CHAIN_PRIVATE}" "-d ${UPLINK_SUBNET}" "client to another host on the exit's own network hits the private drop"

zero_counters
probe_from_client 10.99.0.1
expect_matched "${CHAIN_PRIVATE}" "-d 10.0.0.0/8" "client to an address in the tunnel's own /8 hits the private drop"

# --- a VPN client still reaches public destinations ---------------------------
zero_counters
probe_from_client "${PUBLIC_PROBE}"
expect_matched FORWARD "-i ${WG_IF} -o ${UPLINK} -j ACCEPT" "client to a public address is forwarded"
expect_no_private_drop "client to a public address is not dropped by the private ranges"

# --- the client's tunnel-verification ping still reaches the exit -------------
zero_counters
probe_from_client "${SERVER_ADDRESS}"
expect_matched INPUT "-i ${WG_IF} -p icmp -m icmp --icmp-type 8 -j ACCEPT" "client ping to the WireGuard address is accepted"
expect_unmatched INPUT "-i ${WG_IF} -j DROP" "client ping to the WireGuard address is not dropped"

# --- ...and nothing else from the tunnel reaches the exit ---------------------
# The drop is protocol- and port-agnostic, so an echo to the exit's own
# address proves the control API on it is unreachable.
zero_counters
probe_from_client "${OTHER_ADDRESS}"
expect_matched INPUT "-i ${WG_IF} -j DROP" "client to the exit's other addresses is dropped"

# --- down removes everything the hook installed -------------------------------
"${HOOK}" down "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}"

if iptables -t filter -S "${CHAIN_PRIVATE}" >/dev/null 2>&1; then
  fail "${CHAIN_PRIVATE} still exists after down"
else
  pass "${CHAIN_PRIVATE} is gone after down"
fi
if iptables -t filter -S FORWARD | grep -qF -- "-i ${WG_IF}"; then
  fail "FORWARD still has ${WG_IF} rules after down"
else
  pass "FORWARD has no ${WG_IF} rules after down"
fi
forward_policy_after_down="$(iptables -t filter -S FORWARD | sed -n '1p')"
if [ "${forward_policy_after_down}" = "-P FORWARD DROP" ]; then
  pass "FORWARD stays DROP after down"
else
  fail "FORWARD policy is '${forward_policy_after_down}' after down, expected DROP"
fi
if iptables -t nat -S POSTROUTING | grep -qF -- "-j MASQUERADE"; then
  fail "POSTROUTING still masquerades after down"
else
  pass "POSTROUTING has no MASQUERADE rule after down"
fi

# --- a hook that fails half way leaves the namespace closed -------------------
# Fail each install step in turn with a mocked iptables on PATH, then check the
# half-installed state still isolates clients: policy DROP, and the private
# jump before any ACCEPT.
closed_after_partial_install() {
  local policy first
  policy="$(iptables -t filter -S FORWARD | sed -n '1p')"
  [ "${policy}" = "-P FORWARD DROP" ] || return 1
  first="$(iptables -t filter -S FORWARD | sed -n '2p')"
  if iptables -t filter -S FORWARD | grep -q -- "-j ACCEPT"; then
    [ "${first}" = "-A FORWARD -i ${WG_IF} -j ${CHAIN_PRIVATE}" ] || return 1
  fi
  if iptables -t filter -S INPUT | grep -q -- "-i ${WG_IF} .*-j ACCEPT"; then
    iptables -t filter -S INPUT | grep -qxF -- "-A INPUT -i ${WG_IF} -j DROP" || return 1
  fi
  return 0
}

mock_bin="$(mktemp -d)"
real_iptables="$(command -v iptables)"
cat >"${mock_bin}/iptables" <<MOCK
#!/bin/bash
# Deletes are always allowed, so the cleanup that starts every install works.
if [ -n "\${FAIL_ON:-}" ] && [[ "\$*" == *"\${FAIL_ON}"* ]] && [[ "\$*" != *"-D "* ]]; then
  echo "mock iptables: failing on '\$*'" >&2
  exit 1
fi
exec "${real_iptables}" "\$@"
MOCK
chmod +x "${mock_bin}/iptables"

for step in "-j ACCEPT" "--ctstate" "--icmp-type"; do
  "${HOOK}" down "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}"
  if FAIL_ON="${step}" PATH="${mock_bin}:${PATH}" \
    "${HOOK}" up "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}" 2>/dev/null; then
    fail "the hook reported success although installing '${step}' failed"
  else
    pass "the hook fails when installing '${step}' fails"
  fi
  if closed_after_partial_install; then
    pass "a half-installed hook (failed '${step}') still isolates VPN clients"
  else
    fail "after failing '${step}' a VPN client is no longer isolated"
  fi
done
"${HOOK}" down "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}"

# --- a hook that cannot read the uplink's subnet refuses to install ----------
# Without the uplink subnet only the static ranges cover the exit's own
# network, so an `ip` failure must stop the hook.
real_ip="$(command -v ip)"
cat >"${mock_bin}/ip" <<MOCK
#!/bin/bash
if [[ "\$*" == *"route show"* ]]; then
  echo "mock ip: failing on '\$*'" >&2
  exit 1
fi
exec "${real_ip}" "\$@"
MOCK
chmod +x "${mock_bin}/ip"

if PATH="${mock_bin}:${PATH}" \
  "${HOOK}" up "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}" 2>/dev/null; then
  fail "the hook reported success although reading the routes of ${UPLINK} failed"
else
  pass "the hook fails when reading the routes of ${UPLINK} fails"
fi
if closed_after_partial_install; then
  pass "a hook that could not read the routes of ${UPLINK} still isolates VPN clients"
else
  fail "after failing to read the routes of ${UPLINK} a VPN client is no longer isolated"
fi
"${HOOK}" down "${CLIENT_CIDR}" "${SERVER_ADDRESS}" "${UPLINK}"
rm -rf "${mock_bin}"

if [ "${failures}" -ne 0 ]; then
  echo "--- final ruleset ---" >&2
  iptables -t filter -S >&2
  iptables -t nat -S >&2
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all firewall checks passed"
