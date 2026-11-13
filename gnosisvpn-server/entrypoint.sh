#!/bin/bash
set -euo pipefail

: "${WIREGUARD_CIDR:?WIREGUARD_CIDR must be set, e.g. 10.128.0.0/24}"
WIREGUARD_MTU="${WIREGUARD_MTU:-1420}"
# Maximum number of peers (available slots) that can connect to this exit node.
max_slots="${MAX_SLOTS:-4}"

cidr_ip="${WIREGUARD_CIDR%%/*}"
IFS='.' read -r o1 o2 o3 o4 <<<"${cidr_ip}"
# Same arithmetic as the gnosisvpn-server Ansible role's `set_fact` step: the WireGuard
# server itself takes the first usable address, the client pool starts at the next one, and
# (matching production) always runs to .254 regardless of the exact prefix length.
wg_address="${o1}.${o2}.${o3}.$((o4 + 1))"
wg_start="${o1}.${o2}.${o3}.$((o4 + 2))"
wg_end="${o1}.${o2}.${o3}.$((o4 + 1 + max_slots))"

# The pool has to stay inside the CIDR's last /24: per-peer shaping steers packets by
# the last octet only, and .255 is the broadcast address.
if (( o4 + 1 + max_slots > 254 )); then
  echo "gnosisvpn-server: FATAL: WIREGUARD_CIDR ${WIREGUARD_CIDR} with MAX_SLOTS=${max_slots} needs last octets .$((o4 + 1))-.$((o4 + 1 + max_slots)), past .254" >&2
  exit 1
fi

# Consumed by wg-hooks.sh through gvpn-peer-shaping.sh, which wg-quick runs with this
# process's environment (gnosis_vpn-server spawns wg-quick as a plain child process).
export GVPN_PEER_SUBNET_PREFIX="${o1}.${o2}.${o3}"
export GVPN_PEER_MIN_OCTET=$((o4 + 2))
export GVPN_PEER_MAX_OCTET=$((o4 + 1 + max_slots))

# gnosis_vpn-server's own wrapper.sh generates a WireGuard key when PRIVATE_KEY isn't set,
# but doesn't persist it - a fresh key on every restart would break peer registration.
# Persist it in the /data volume instead, generating it once here.
mkdir -p /data
KEY_FILE=/data/privatekey
if [ ! -s "${KEY_FILE}" ]; then
  echo "gnosisvpn-server: no persisted WireGuard key found in /data, generating one"
  umask 077
  wg genkey >"${KEY_FILE}"
fi
private_key="$(cat "${KEY_FILE}")"
echo "gnosisvpn-server: WireGuard public key: $(echo "${private_key}" | wg pubkey)"

sed \
  -e "s|__WG_ADDRESS__|${wg_address}|g" \
  -e "s|__WG_MTU__|${WIREGUARD_MTU}|g" \
  -e "s|__WG_CIDR__|${WIREGUARD_CIDR}|g" \
  -e "s|<private key>|${private_key}|g" \
  /app/wggvpn.conf.tpl >/app/wggvpn.conf
chmod 600 /app/wggvpn.conf

sed \
  -e "s|__WG_START__|${wg_start}|g" \
  -e "s|__WG_END__|${wg_end}|g" \
  /app/config.toml.tpl >/app/config.toml

# Without network_mode: host (not available to regular DAppNode packages - see README),
# /proc/sys/net/ipv4/ip_forward is read-only from inside this container, so it can't be set
# here even with NET_ADMIN. In practice it's already 1: new network namespaces inherit the
# current value from their parent netns at creation time (verified directly - not reset to a
# hard-coded default), and any host capable of running Docker at all already has it enabled
# for dockerd's own bridge networking. This is just a sanity check, unrelated to which
# network(s) this container is on.
current_ip_forward="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
if [ "${current_ip_forward}" != "1" ]; then
  echo "gnosisvpn-server: WARNING: net.ipv4.ip_forward is '${current_ip_forward}', not '1', and this container cannot set it itself. VPN client traffic will not reach the internet until it's enabled on the DAppNode host." >&2
fi

# wg-quick brings wggvpn up (with its peers) before PostUp runs wg-hooks.sh, so close
# FORWARD now; wg-hooks.sh then opens only the public path. If this fails, the container
# fails: the exit node must not start without it.
iptables -P FORWARD DROP

# The blocklist set lives in this container's namespace, so its cache lives in the /data
# volume and the refresh runs as a child process: a container has no timer. Loading the
# cache first (no network) filters the first forwarded packet with the last known-good
# list; the refresher then replaces it from the feeds in the background, failing open.
/app/gvpn-blocklist-update.sh --from-cache
/app/gvpn-blocklist-update.sh --loop &

# Run the binary directly as PID 1 (not via the image's wrapper.sh, which launches it as a
# child process) so Docker's SIGTERM on `stop`/`down` reaches gnosis_vpn-server itself. It
# has its own graceful-shutdown handling, which is what actually runs wg-quick down/PreDown.
exec /app/gnosis_vpn-server --config-file /app/config.toml serve --periodically-run-cleanup --sync-wg-interface
