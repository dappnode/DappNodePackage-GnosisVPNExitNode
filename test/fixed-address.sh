#!/usr/bin/env bash
# Checks that node reaches gnosisvpn-server at its fixed address. See test/README.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ADDRESS=172.33.255.254
PREFIX=gnosisvpn-fixed-address-test
DNCORE="${PREFIX}-dncore"
DNPRIVATE="${PREFIX}-dnprivate"
SERVER="${PREFIX}-server"
NODE="${PREFIX}-node"
FILLER="${PREFIX}-filler"
IMAGE="${PREFIX}"
# Seconds between the server's re-claims.
INTERVAL=2
BUILD_DIR=""

wired() { # grep arguments; stops the test naming the missing line
  grep -q "$@" || {
    echo "FAIL: no match for grep $*" >&2
    exit 1
  }
}
wired -x "ADDRESS=${ADDRESS}" gnosisvpn-server/gvpn-fixed-address.sh
wired -x "GNOSISVPN_SERVER_IP=${ADDRESS}" entrypoint.sh
wired '^COPY .*gvpn-fixed-address.sh' gnosisvpn-server/Dockerfile
wired '^RUN apk add .*iputils-arping' gnosisvpn-server/Dockerfile
wired -x '/app/gvpn-fixed-address.sh' gnosisvpn-server/entrypoint.sh
wired -x '/app/gvpn-fixed-address.sh --loop &' gnosisvpn-server/entrypoint.sh
echo "ok: node and gnosisvpn-server agree on ${ADDRESS}, and the image claims and keeps it"

failures=0
pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

cleanup() {
  docker rm -f "${SERVER}" "${NODE}" "${FILLER}" >/dev/null 2>&1 || true
  docker network rm "${DNCORE}" "${DNPRIVATE}" >/dev/null 2>&1 || true
  [ -z "${BUILD_DIR}" ] || rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT
cleanup
BUILD_DIR="$(mktemp -d)"

# Stand-ins for node, the second claimant and the server. The server answers on 8000 with its
# hostname.
cat >"${BUILD_DIR}/Dockerfile" <<'EOF'
FROM alpine:3
RUN apk add --no-cache bash iproute2 iputils-arping && \
  printf '#!/bin/sh\nread -r _\nhostname\n' >/answer && chmod +x /answer
EOF
docker build -q -t "${IMAGE}" "${BUILD_DIR}" >/dev/null

# dncore_network and dnprivate_network, which DAppNode attaches every service to.
docker network create --subnet 172.33.0.0/16 "${DNCORE}" >/dev/null
docker network create --subnet 10.20.0.0/24 "${DNPRIVATE}" >/dev/null

if [ -n "${FIXED_ADDRESS_TEST_IMAGE:-}" ]; then
  # The image's own entrypoint and gnosis_vpn-server's control API on 8000.
  SERVER_RUN=(-e WIREGUARD_CIDR=10.128.0.0/24 -e GVPN_BLOCKLIST_FEEDS=file:///nonexistent
    "${FIXED_ADDRESS_TEST_IMAGE}")
  CLAIMANT_RUN=(--entrypoint /app/gvpn-fixed-address.sh "${FIXED_ADDRESS_TEST_IMAGE}")
else
  SERVER_RUN=(-v "${PWD}/gnosisvpn-server/gvpn-fixed-address.sh:/app/gvpn-fixed-address.sh:ro"
    "${IMAGE}" bash -c
    '/app/gvpn-fixed-address.sh && { /app/gvpn-fixed-address.sh --loop & } && exec nc -lk -p 8000 -e /answer')
  CLAIMANT_RUN=(-v "${PWD}/gnosisvpn-server/gvpn-fixed-address.sh:/app/gvpn-fixed-address.sh:ro"
    --entrypoint /app/gvpn-fixed-address.sh "${IMAGE}")
fi

docker_address() { # $1 container: its Docker-assigned address on dncore_network
  docker inspect -f "{{(index .NetworkSettings.Networks \"${DNCORE}\").IPAddress}}" "$1"
}

start_server() {
  docker run -d --name "${SERVER}" --cap-add NET_ADMIN \
    --network "${DNCORE}" --network "${DNPRIVATE}" \
    -e GVPN_FIXED_ADDRESS_INTERVAL="${INTERVAL}" "${SERVER_RUN[@]}" >/dev/null
}

claims() { # $1 = how many claims the server's log must show
  [ "$(docker logs "${SERVER}" 2>&1 | grep -c "claimed ${ADDRESS} on ")" -ge "$1" ]
}

wait_for() { # $1 = seconds, rest = command
  local seconds="$1"
  shift
  for _ in $(seq 1 "${seconds}"); do
    "$@" && return 0
    sleep 1
  done
  return 1
}

answer() { # the first line the server sends back to node on ADDRESS:8000, empty if none
  docker exec "${NODE}" bash -c \
    "exec 3<>/dev/tcp/${ADDRESS}/8000 && printf 'GET / HTTP/1.0\r\n\r\n' >&3 && timeout 5 head -n1 <&3" \
    2>/dev/null || true
}

answers() { [ -n "$(answer)" ]; }

node_neighbour() { # node's cached MAC for ADDRESS
  docker exec "${NODE}" awk -v a="${ADDRESS}" '$1 == a { print $4 }' /proc/net/arp
}

server_mac() { docker inspect -f "{{(index .NetworkSettings.Networks \"${DNCORE}\").MacAddress}}" "${SERVER}"; }

neighbour_is_server() { [ "$(node_neighbour)" = "$(server_mac)" ]; }

# No extra capabilities, like node.
docker run -d --name "${NODE}" --network "${DNCORE}" --network "${DNPRIVATE}" \
  --entrypoint sleep "${IMAGE}" 3600 >/dev/null

echo "### first start"
start_server
if wait_for 30 claims 1; then
  pass "claims ${ADDRESS}"
else
  fail "never claimed ${ADDRESS}: $(docker logs "${SERVER}" 2>&1 | tail -n 5)"
fi
first_address="$(docker_address "${SERVER}")"
dev_addresses="$(docker exec "${SERVER}" sh -c \
  "ip -4 -o addr show dev \$(ip -4 -o addr show to ${ADDRESS}/32 | awk '{ print \$2 }')")"
case "${dev_addresses}" in
*" ${first_address}/16 "*) pass "keeps Docker's own address ${first_address} on the same interface" ;;
*) fail "the interface holding ${ADDRESS} lost Docker's address ${first_address}: ${dev_addresses}" ;;
esac
if wait_for 30 answers; then
  pass "node reaches the server at ${ADDRESS}:8000 ($(answer))"
else
  fail "node gets no answer from ${ADDRESS}:8000"
fi

echo
echo "### a second claimant while the address is held"
if out="$(docker run --rm --cap-add NET_ADMIN --network "${DNCORE}" "${CLAIMANT_RUN[@]}" 2>&1)"; then
  fail "claimed an address another container holds: ${out}"
else
  case "${out}" in
  *"${ADDRESS} is already in use"*) pass "backs off and says why" ;;
  *) fail "failed for another reason: ${out}" ;;
  esac
fi
if answers; then pass "the server keeps answering"; else fail "the server stopped answering"; fi

echo
echo "### recreated at another Docker address"
docker rm -f "${SERVER}" >/dev/null
# Takes the old server's Docker address, so the new one gets another.
docker run -d --name "${FILLER}" --network "${DNCORE}" --entrypoint sleep "${IMAGE}" 3600 >/dev/null
start_server
wait_for 30 claims 1 || true
second_address="$(docker_address "${SERVER}")"
if [ "${second_address}" != "${first_address}" ]; then
  pass "Docker moved the server from ${first_address} to ${second_address}"
else
  fail "Docker gave the server ${first_address} again, so this proves nothing"
fi
# node has the old server's MAC cached for ADDRESS.
if wait_for 3 neighbour_is_server; then
  pass "node's neighbour entry for ${ADDRESS} follows the new server"
else
  fail "node still sends ${ADDRESS} to $(node_neighbour), the server is $(server_mac)"
fi
if wait_for 30 answers; then
  pass "node reaches the new server at the same ${ADDRESS}:8000"
else
  fail "node gets no answer from the new server at ${ADDRESS}:8000"
fi

echo
echo "### reconnected to dncore_network without a restart"
# The new interface doesn't have the address.
docker network disconnect "${DNCORE}" "${SERVER}"
docker network connect "${DNCORE}" "${SERVER}"
if wait_for $((INTERVAL * 5)) claims 2; then
  pass "claims ${ADDRESS} again"
else
  fail "did not claim ${ADDRESS} again"
fi
if wait_for 10 answers; then
  pass "node reaches the server at ${ADDRESS}:8000 again"
else
  fail "node gets no answer from ${ADDRESS}:8000 after the reconnect"
fi

echo
if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
