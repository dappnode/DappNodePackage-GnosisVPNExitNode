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
BLOKLI_PLACEHOLDER=__BLOKLI_URL__
# What the template's placeholder becomes when neither the upload nor the setup wizard's
# HOPRD_BLOKLI_URL sets a URL. hoprd requires a Blokli URL in the config either way.
DEFAULT_BLOKLI_URL=https://blokli.piz-palu.gnosisvpn.io
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

# Whether a config is an older version's output: every template they rendered has this
# WireGuard entry, which they filled in with gnosisvpn-server's dynamic address.
rendered_by_older_version() {
  local line wg_entry="^ *- \"([0-9]{1,3}(\\.[0-9]{1,3}){3}):51820\" +# gnosisvpn-server's WireGuard interface"
  while IFS= read -r line; do
    if [[ "${line}" =~ ${wg_entry} ]] && [ "${BASH_REMATCH[1]}" != "${GNOSISVPN_SERVER_IP}" ]; then
      return 0
    fi
  done <<<"$1"
  return 1
}

# A config's top-level blokli_url.
config_blokli_url() {
  local line
  while IFS= read -r line; do
    if [[ "${line}" =~ ^blokli_url:[[:space:]]*\"?([^\"#[:space:]]+) ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return
    fi
  done <<<"$1"
}

# A config with the line config_blokli_url reads set to blokli_url $2.
with_config_blokli_url() {
  local line eol=$'\n'
  while IFS= read -r line || { eol=""; [ -n "${line}" ]; }; do
    if [[ "${line}" =~ ^blokli_url:[[:space:]]*\"?([^\"#[:space:]]+) ]]; then
      line="blokli_url: $2"
    fi
    printf '%s%s' "${line}" "${eol}"
  done < <(printf '%s' "$1")
}

template_contents="$(read_config "${TEMPLATE_CONFIG}")"
source_contents="${template_contents}"

if [ -s "${CUSTOM_CONFIG}" ]; then
  custom_contents="$(read_config "${CUSTOM_CONFIG}")"
  if rendered_by_older_version "${custom_contents}"; then
    # Using it would keep its stale address and miss newer template settings.
    echo "entrypoint.sh: ignoring ${CUSTOM_CONFIG}: an older version of this package rendered it. Upload your config again if it was a custom one." >&2
  else
    echo "entrypoint.sh: using uploaded ${CUSTOM_CONFIG}"
    source_contents="${custom_contents}"
    custom_body="$(config_body "${custom_contents}")"
    case "${custom_body}" in
    *"${PLACEHOLDER}"* | *"${GNOSISVPN_SERVER_IP}"*) ;;
    *)
      echo "entrypoint.sh: WARNING: ${CUSTOM_CONFIG} does not forward to gnosisvpn-server at ${GNOSISVPN_SERVER_IP}; add ${GNOSISVPN_SERVER_IP}:51820 and ${GNOSISVPN_SERVER_IP}:8000 to session_ip_forwarding.target_allow_list." >&2
      ;;
    esac
    case "${custom_body}" in
    *"${BLOKLI_PLACEHOLDER}"*) ;;
    *)
      echo "entrypoint.sh: WARNING: ${CUSTOM_CONFIG} does not set the Pix strategy's pool.blokli_url to ${BLOKLI_PLACEHOLDER}, so PIX payments may not work; see hoprd.cfg.yaml.tpl." >&2
      ;;
    esac
  fi
fi

# hoprd prefers HOPRD_BLOKLI_URL to the config's URL; the PIX pool only reads the config.
# A URL set through ADDITIONAL_ENVIRONMENT_VARS or ADDITIONAL_CMDLINE_ARGS reaches only hoprd.
blokli_url="${HOPRD_BLOKLI_URL:-$(config_blokli_url "${source_contents}")}"
# The template, and uploads that leave it in place, ask for the default.
if [ "${blokli_url}" = "${BLOKLI_PLACEHOLDER}" ]; then
  blokli_url="${DEFAULT_BLOKLI_URL}"
fi
if [ -z "${blokli_url}" ] && [[ "$(config_body "${source_contents}")" == *"${BLOKLI_PLACEHOLDER}"* ]]; then
  echo "entrypoint.sh: no blokli_url for the PIX pool: write the top-level blokli_url as \"blokli_url: <url>\" on one line, or set HOPRD_BLOKLI_URL." >&2
  exit 1
fi
rendered="${source_contents//${PLACEHOLDER}/${GNOSISVPN_SERVER_IP}}"
rendered="${rendered//${BLOKLI_PLACEHOLDER}/"${blokli_url}"}"
# An upload can set its own top-level URL; when the setup wizard overrides it, write the URL
# hoprd actually uses into the config too.
if [ -n "${HOPRD_BLOKLI_URL:-}" ]; then
  rendered="$(with_config_blokli_url "${rendered}" "${HOPRD_BLOKLI_URL}"; echo x)"
  rendered="${rendered%x}"
fi
printf '%s' "${rendered}" >"${GENERATED_CONFIG}"
export HOPRD_CONFIGURATION_FILE_PATH="${GENERATED_CONFIG}"

# exec, so tini's SIGTERM reaches hoprd.
exec env ${ADDITIONAL_ENVIRONMENT_VARS:-} /bin/docker-entrypoint.sh ${ADDITIONAL_CMDLINE_ARGS:-}
