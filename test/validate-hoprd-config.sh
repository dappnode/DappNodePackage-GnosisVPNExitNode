#!/usr/bin/env bash
# Validates hoprd.cfg.yaml.tpl against the real hoprd binary's own config parser
# (`hoprd-cfg --validate-args`), the same check the container's entrypoint runs before
# launching hoprd. Keep HOPRD_IMAGE in sync with docker-compose.yml's UPSTREAM_VERSION.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HOPRD_IMAGE="europe-west3-docker.pkg.dev/hoprassociation/docker-images/hoprd:4.0.3"

TMP_CFG="$(mktemp)"
trap 'rm -f "${TMP_CFG}"' EXIT
# Same substitution entrypoint.sh does at container startup, with a placeholder IP instead of
# a real resolved one.
template="$(cat hoprd.cfg.yaml.tpl)"
printf '%s\n' "${template//__GNOSISVPN_SERVER_IP__/172.30.0.10}" >"${TMP_CFG}"

docker run --rm \
  -v "${TMP_CFG}:/app/hoprd.cfg.yaml:ro" \
  --entrypoint /bin/hoprd-cfg \
  "${HOPRD_IMAGE}" \
  --validate-args -- \
  --identity /app/hopr.id \
  --data /app/data \
  --password validation-password \
  --apiToken validation-token-123456 \
  --safeAddress 0x0000000000000000000000000000000000000001 \
  --moduleAddress 0x0000000000000000000000000000000000000002 \
  --host 1.2.3.4:9091 \
  --configurationFilePath /app/hoprd.cfg.yaml

echo "hoprd.cfg.yaml.tpl renders to a valid config for ${HOPRD_IMAGE}."
