#!/usr/bin/env bash
# Validates hoprd.cfg.yaml.tpl against the real hoprd binary's own config parser
# (`hoprd-cfg --validate-args`), the same check the container's entrypoint effectively runs
# (via hoprd itself) before launching. Keep HOPRD_IMAGE in sync with docker-compose.yml's
# UPSTREAM_VERSION. Renders the template with a dummy IP first - entrypoint.sh does the same
# substitution with gnosisvpn-server's real resolved IP - since hoprd's parser requires a
# literal ip:port and won't accept the __GNOSISVPN_SERVER_IP__ placeholder as-is.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HOPRD_IMAGE="europe-west3-docker.pkg.dev/hoprassociation/docker-images/hoprd:4.0.3"

RENDERED_CONFIG="$(mktemp)"
trap 'rm -f "${RENDERED_CONFIG}"' EXIT
sed "s|__GNOSISVPN_SERVER_IP__|127.0.0.1|g" hoprd.cfg.yaml.tpl >"${RENDERED_CONFIG}"

docker run --rm \
  -v "${RENDERED_CONFIG}:/app/hoprd.cfg.yaml:ro" \
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

echo "hoprd.cfg.yaml.tpl is a valid config for ${HOPRD_IMAGE} (rendered with a dummy IP)."
