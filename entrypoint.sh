#!/bin/bash
set -euo pipefail

# hoprd's --blokliUrl has strict URL validation that rejects an explicit empty string (it
# doesn't treat "" as "not set") - unset it so the value already in hoprd.cfg.yaml.tpl wins,
# unless the setup wizard actually provided one.
if [ -z "${HOPRD_BLOKLI_URL:-}" ]; then
  unset HOPRD_BLOKLI_URL
fi

PLACEHOLDER=__GNOSISVPN_SERVER_IP__
# gnosisvpn-server claims this address itself; must match ADDRESS in
# gnosisvpn-server/gvpn-fixed-address.sh.
GNOSISVPN_SERVER_IP=172.33.255.254
# The setup wizard's upload. Only read, never written: older versions rendered here, and the
# next boot took that output for an upload.
CUSTOM_CONFIG=/app/hoprd/conf/hoprd.custom.cfg.yaml
TEMPLATE_CONFIG=/app/hoprd.cfg.yaml.tpl
# What hoprd reads. Hardcoded so it can't be pointed back at CUSTOM_CONFIG.
GENERATED_CONFIG=/app/hoprd/conf/hoprd.generated.cfg.yaml

# This image has no sed. The `echo x` / `%x` keeps the trailing newline `$(cat)` strips.
read_config() {
  local contents
  contents="$(cat "$1"; echo x)"
  printf '%s' "${contents%x}"
}

# A config without comments and blank lines.
config_body() {
  local line body=""
  while IFS= read -r line; do
    line="${line%%#*}"
    [ -z "${line//[[:space:]]/}" ] && continue
    body+="${line}"$'\n'
  done <<<"$1"
  printf '%s' "${body}"
}

# A config without comments, blank lines and addresses, so a config an older version rendered
# from the template compares equal to the template.
config_fingerprint() {
  local config
  config="$(config_body "$1")"
  config="${config//${PLACEHOLDER}/<server-address>}"
  while [[ "${config}" =~ ([0-9]{1,3}\.){3}[0-9]{1,3} ]]; do
    config="${config/"${BASH_REMATCH[0]}"/<server-address>}"
  done
  printf '%s' "${config}"
}

template_contents="$(read_config "${TEMPLATE_CONFIG}")"
source_contents="${template_contents}"

if [ -s "${CUSTOM_CONFIG}" ]; then
  custom_contents="$(read_config "${CUSTOM_CONFIG}")"
  if [ "$(config_fingerprint "${custom_contents}")" = "$(config_fingerprint "${template_contents}")" ]; then
    # An older version's output: using it would keep its stale address.
    echo "entrypoint.sh: ignoring ${CUSTOM_CONFIG}: an older version of this package rendered it, it is not an upload." >&2
  else
    echo "entrypoint.sh: using uploaded ${CUSTOM_CONFIG}"
    source_contents="${custom_contents}"
    case "$(config_body "${custom_contents}")" in
    *"${PLACEHOLDER}"* | *"${GNOSISVPN_SERVER_IP}"*) ;;
    *)
      echo "entrypoint.sh: WARNING: ${CUSTOM_CONFIG} does not forward to gnosisvpn-server at ${GNOSISVPN_SERVER_IP}; add ${GNOSISVPN_SERVER_IP}:51820 and ${GNOSISVPN_SERVER_IP}:8000 to session_ip_forwarding.target_allow_list." >&2
      ;;
    esac
  fi
fi

printf '%s' "${source_contents//${PLACEHOLDER}/${GNOSISVPN_SERVER_IP}}" >"${GENERATED_CONFIG}"
export HOPRD_CONFIGURATION_FILE_PATH="${GENERATED_CONFIG}"

# exec, so tini's SIGTERM reaches hoprd.
exec env ${ADDITIONAL_ENVIRONMENT_VARS:-} /bin/docker-entrypoint.sh ${ADDITIONAL_CMDLINE_ARGS:-}
