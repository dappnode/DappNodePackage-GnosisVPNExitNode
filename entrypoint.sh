#!/bin/bash
set -euo pipefail

# hoprd's --blokliUrl has strict URL validation that rejects an explicit empty string (it
# doesn't treat "" as "not set") - unset it so the value already in hoprd.cfg.yaml wins,
# unless the setup wizard actually provided one.
if [ -z "${HOPRD_BLOKLI_URL:-}" ]; then
  unset HOPRD_BLOKLI_URL
fi

CUSTOM_CONFIG=/app/hoprd/conf/hoprd.custom.cfg.yaml
STATIC_CONFIG=/app/hoprd.cfg.yaml

if [ -s "${CUSTOM_CONFIG}" ]; then
  # A config was uploaded via the setup wizard's "Custom HOPR node configuration file"
  # field - use it as-is, so we never clobber a deliberate override.
  echo "entrypoint.sh: using uploaded ${CUSTOM_CONFIG}"
  export HOPRD_CONFIGURATION_FILE_PATH="${CUSTOM_CONFIG}"
else
  export HOPRD_CONFIGURATION_FILE_PATH="${STATIC_CONFIG}"
fi

env ${ADDITIONAL_ENVIRONMENT_VARS} /bin/docker-entrypoint.sh ${ADDITIONAL_CMDLINE_ARGS}
