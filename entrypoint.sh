#!/bin/bash
set -euo pipefail

# hoprd's --blokliUrl has strict URL validation that rejects an explicit empty string (it
# doesn't treat "" as "not set") - unset it so the value already in hoprd.cfg.yaml wins,
# unless the setup wizard actually provided one.
if [ -z "${HOPRD_BLOKLI_URL:-}" ]; then
  unset HOPRD_BLOKLI_URL
fi

CUSTOM_CONFIG=/app/hoprd/conf/hoprd.custom.cfg.yaml
RENDERED_CONFIG=/app/hoprd/conf/hoprd.cfg.yaml

if [ -s "${CUSTOM_CONFIG}" ]; then
  # A config was uploaded via the setup wizard's "Custom HOPR node configuration file"
  # field - use it as-is and skip rendering, so we never clobber a deliberate override.
  echo "entrypoint.sh: using uploaded ${CUSTOM_CONFIG}"
  export HOPRD_CONFIGURATION_FILE_PATH="${CUSTOM_CONFIG}"
else
  # hoprd's session_ip_forwarding config requires a literal ip:port (hostnames are rejected
  # by hoprd's own config parser - verified directly against the 4.0.3 image), and this
  # package can't pin a static IP for gnosisvpn-server (no custom docker networks allowed for
  # non-core DAppNode packages - see README). So resolve it here, at every startup, and
  # render the real config file from the template that ships in the image.
  gnosisvpn_server_host="${GNOSISVPN_SERVER_HOST:-gnosisvpn-server}"
  gnosisvpn_server_ip=""
  for _ in $(seq 1 30); do
    candidate="$(dig +short "${gnosisvpn_server_host}" A 2>/dev/null | tail -n1)"
    if [[ "${candidate}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      gnosisvpn_server_ip="${candidate}"
      break
    fi
    sleep 2
  done

  if [ -z "${gnosisvpn_server_ip}" ]; then
    echo "entrypoint.sh: WARNING: could not resolve ${gnosisvpn_server_host}, falling back to 127.0.0.1 in ${RENDERED_CONFIG}. GnosisVPN session forwarding will not work until gnosisvpn-server is reachable and this container restarts." >&2
    gnosisvpn_server_ip="127.0.0.1"
  else
    echo "entrypoint.sh: resolved ${gnosisvpn_server_host} to ${gnosisvpn_server_ip}"
  fi

  template="$(cat /app/hoprd.cfg.yaml.tpl)"
  printf '%s\n' "${template//__GNOSISVPN_SERVER_IP__/${gnosisvpn_server_ip}}" >"${RENDERED_CONFIG}"
  export HOPRD_CONFIGURATION_FILE_PATH="${RENDERED_CONFIG}"
fi

env ${ADDITIONAL_ENVIRONMENT_VARS} /bin/docker-entrypoint.sh ${ADDITIONAL_CMDLINE_ARGS}
