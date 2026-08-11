#!/usr/bin/env bash
# Bring the package's docker-compose stack up/down locally, outside DAppNode, for smoke
# testing before `npx @dappnode/dappnodesdk build`. See test/README.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE=.env.local
if [ ! -f "${ENV_FILE}" ]; then
  echo "No ${ENV_FILE} found - creating one from .env.local.example. Edit it if you want different values." >&2
  cp .env.local.example "${ENV_FILE}"
fi

compose() {
  docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file "${ENV_FILE}" "$@"
}

action="${1:-up}"
case "${action}" in
up)
  compose build
  compose create
  # shellcheck disable=SC1091
  source "${ENV_FILE}"
  if [ -n "${HOPRD_IDENTITY_FILE:-}" ]; then
    if [ ! -f "${HOPRD_IDENTITY_FILE}" ]; then
      echo "HOPRD_IDENTITY_FILE=${HOPRD_IDENTITY_FILE} does not exist" >&2
      exit 1
    fi
    echo "Seeding hoprd identity from ${HOPRD_IDENTITY_FILE}..."
    docker cp "${HOPRD_IDENTITY_FILE}" "$(compose ps -a -q node):/app/hoprd/conf/hopr.id"
  fi
  compose start
  echo "Waiting for node's API to become healthy (this can take a while on first sync)..."
  for _ in $(seq 1 60); do
    if curl -fs -H "X-Auth-Token: ${HOPRD_API_TOKEN}" http://localhost:3001/healthyz >/dev/null 2>&1; then
      echo "node: healthy."
      break
    fi
    sleep 5
  done
  echo "--- gnosisvpn-server WireGuard public key ---"
  gvpn_container="$(compose ps -q gnosisvpn-server)"
  docker logs "${gvpn_container}" 2>&1 | grep "public key" | tail -1 || echo "(not found yet - check 'just local-logs')"
  echo "--- gnosisvpn-server wg interface ---"
  docker exec "${gvpn_container}" wg show wggvpn || echo "(wggvpn not up yet - check 'just local-logs')"
  ;;
down)
  compose down
  ;;
*)
  echo "usage: $0 [up|down]" >&2
  exit 1
  ;;
esac
