#!/bin/bash
set -euo pipefail

# hoprd's --blokliUrl has strict URL validation that rejects an explicit empty string (it
# doesn't treat "" as "not set") - unset it so the value already in hoprd.cfg.yaml.tpl wins,
# unless the setup wizard actually provided one.
if [ -z "${HOPRD_BLOKLI_URL:-}" ]; then
  unset HOPRD_BLOKLI_URL
fi

CUSTOM_CONFIG=/app/hoprd/conf/hoprd.custom.cfg.yaml
TEMPLATE_CONFIG=/app/hoprd.cfg.yaml.tpl
RENDERED_CONFIG="${HOPRD_CONFIGURATION_FILE_PATH:?HOPRD_CONFIGURATION_FILE_PATH must be set}"

if [ -s "${CUSTOM_CONFIG}" ]; then
  # A config was uploaded via the setup wizard's "Custom HOPR node configuration file"
  # field - use it as-is (modulo the same __GNOSISVPN_SERVER_IP__ substitution below), so we
  # never clobber a deliberate override otherwise.
  echo "entrypoint.sh: using uploaded ${CUSTOM_CONFIG}"
  SOURCE_CONFIG="${CUSTOM_CONFIG}"
else
  SOURCE_CONFIG="${TEMPLATE_CONFIG}"
fi

: "${GNOSISVPN_SERVER_HOST:?GNOSISVPN_SERVER_HOST must be set}"
echo "entrypoint.sh: resolving gnosisvpn-server (${GNOSISVPN_SERVER_HOST})..."
gnosisvpn_server_ip=""
for _ in $(seq 1 30); do
  gnosisvpn_server_ip="$(dig +short "${GNOSISVPN_SERVER_HOST}" A | head -n1)"
  [ -n "${gnosisvpn_server_ip}" ] && break
  sleep 1
done
if [ -z "${gnosisvpn_server_ip}" ]; then
  echo "entrypoint.sh: FATAL: could not resolve ${GNOSISVPN_SERVER_HOST} after 30s - is gnosisvpn-server running?" >&2
  exit 1
fi
# Logged deliberately: this is currently the only way to find gnosisvpn-server's address,
# which a connecting gnosis_vpn-client needs as its session target - see README. hoprd is
# expected to gain a way to tell clients this directly (tracked upstream), making this
# per-install manual lookup unnecessary.
echo "entrypoint.sh: gnosisvpn-server resolved to ${gnosisvpn_server_ip}"

# __GNOSISVPN_SERVER_IP__ is substituted the same way regardless of which file above won -
# see setup-wizard.yml's "Custom HOPR node configuration file" field, which documents using
# the same placeholder in an uploaded config too, instead of requiring the uploader to
# hardcode an address that isn't fixed and that hoprd can't resolve itself.
# No `sed` in this image (it's a minimal coreutils/util-linux build, no busybox either) - do
# the substitution with bash builtins instead. The `; echo x` / `%x` dance preserves a
# trailing newline that a bare `$(cat ...)` would otherwise strip.
config_contents="$(cat "${SOURCE_CONFIG}"; echo x)"
config_contents="${config_contents%x}"
printf '%s' "${config_contents//__GNOSISVPN_SERVER_IP__/${gnosisvpn_server_ip}}" >"${RENDERED_CONFIG}"
export HOPRD_CONFIGURATION_FILE_PATH="${RENDERED_CONFIG}"

env ${ADDITIONAL_ENVIRONMENT_VARS:-} /bin/docker-entrypoint.sh ${ADDITIONAL_CMDLINE_ARGS:-}
