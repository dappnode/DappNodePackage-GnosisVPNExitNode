#!/bin/bash
set -euo pipefail

: "${WIREGUARD_CIDR:?WIREGUARD_CIDR must be set, e.g. 10.128.0.0/24}"
WIREGUARD_MTU="${WIREGUARD_MTU:-1420}"

cidr_ip="${WIREGUARD_CIDR%%/*}"
IFS='.' read -r o1 o2 o3 o4 <<<"${cidr_ip}"
# Same arithmetic as the gnosisvpn-server Ansible role's `set_fact` step: the WireGuard
# server itself takes the first usable address, the client pool starts at the next one, and
# (matching production) always runs to .254 regardless of the exact prefix length.
wg_address="${o1}.${o2}.${o3}.$((o4 + 1))"
wg_start="${o1}.${o2}.${o3}.$((o4 + 2))"
wg_end="${o1}.${o2}.${o3}.254"

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
# here even with NET_ADMIN. In practice it's already 1 on any host capable of running
# Docker/DAppNode at all (dockerd itself needs it host-wide for container networking), and
# this container's network namespace - shared with the node service via docker-compose.yml's
# `network_mode: "service:node"` - inherits that as its default. This is just a sanity check.
current_ip_forward="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
if [ "${current_ip_forward}" != "1" ]; then
  echo "gnosisvpn-server: WARNING: net.ipv4.ip_forward is '${current_ip_forward}', not '1', and this container cannot set it itself. VPN client traffic will not reach the internet until it's enabled on the DAppNode host." >&2
fi

# Run the binary directly as PID 1 (not via the image's wrapper.sh, which launches it as a
# child process) so Docker's SIGTERM on `stop`/`down` reaches gnosis_vpn-server itself. It
# has its own graceful-shutdown handling, which is what actually runs wg-quick down/PreDown.
exec /app/gnosis_vpn-server --config-file /app/config.toml serve --periodically-run-cleanup --sync-wg-interface
