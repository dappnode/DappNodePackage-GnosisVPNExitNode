#!/usr/bin/env bash
# Checks node's entrypoint.sh and the settings its stored keys depend on. See test/README.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SERVER_ADDRESS=172.33.255.254
# A dynamic address an older version rendered.
STALE_ADDRESS=172.33.0.7
IMAGE=gnosisvpn-entrypoint-test
CONF_VOLUME=gnosisvpn-entrypoint-test-conf
STUB=test/entrypoint-stub.sh
UPLOAD=/app/hoprd/conf/hoprd.custom.cfg.yaml
TEMPLATE_BLOKLI_URL="$(sed -n 's|^blokli_url: ||p' hoprd.cfg.yaml.tpl)"
BUILD_DIR=""

failures=0
pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}
expect_contains() { # $1 haystack, $2 needle, $3 what
  case "$1" in
  *"$2"*) pass "$3" ;;
  *) fail "$3 (missing '$2')" ;;
  esac
}
expect_not_contains() { # $1 haystack, $2 needle, $3 what
  case "$1" in
  *"$2"*) fail "$3 (unexpected '$2')" ;;
  *) pass "$3" ;;
  esac
}
has_line() { # $1 file, $2 whole line as an extended regex, $3 what
  if grep -qxE "$2" "$1"; then pass "$3"; else fail "$3 (no line matching '$2' in $1)"; fi
}

echo "### settings the identity and PIX state depend on"
# Installs keep their identity and PIX funds across updates only while these stay the same.
# Changing one gives them a new identity, or one hoprd can't decrypt.
has_line docker-compose.yml ' *HOPRD_IDENTITY: "?/app/hoprd/conf/hopr\.id"?' \
  "identity stays at /app/hoprd/conf/hopr.id"
has_line docker-compose.yml ' *- "?node-conf:/app/hoprd/conf"?' "on the node-conf volume"
has_line hoprd.cfg.yaml.tpl ' *state_path: /app/hoprd/data/curvy-pix\.redb' \
  "PIX pool state stays at /app/hoprd/data/curvy-pix.redb"
has_line hoprd.cfg.yaml.tpl ' *pix_recovery_db_path: /app/hoprd/data/pix-recovery\.redb' \
  "PIX recovered keys stay at /app/hoprd/data/pix-recovery.redb"
has_line docker-compose.yml ' *- "?node-data:/app/hoprd/data"?' "on the node-data volume"
has_line docker-compose.yml ' *HOPRD_PASSWORD:.*' "the password stays in HOPRD_PASSWORD"
has_line hoprd.cfg.yaml.tpl ' *pix_recovery_password_env: HOPRD_PASSWORD' "PIX state is sealed with it too"
has_line setup-wizard.yml ' *name: HOPRD_PASSWORD' "which the setup wizard sets"
echo

cleanup() {
  docker volume rm "${CONF_VOLUME}" >/dev/null 2>&1 || true
  [ -z "${BUILD_DIR}" ] || rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT
cleanup
BUILD_DIR="$(mktemp -d)"

printf 'FROM alpine:3\nRUN apk add --no-cache bash\n' >"${BUILD_DIR}/Dockerfile"
docker build -q -t "${IMAGE}" "${BUILD_DIR}" >/dev/null
docker volume create "${CONF_VOLUME}" >/dev/null

# As PID 1 with no network. HOPRD_CONFIGURATION_FILE_PATH is the upload path, as in older
# installs, to prove the rendered path doesn't come from it. Arguments are extra docker run
# options.
run_entrypoint() {
  docker run --rm --network none \
    -v "${CONF_VOLUME}:/app/hoprd/conf" \
    -v "${PWD}/entrypoint.sh:/bin/entrypoint.sh:ro" \
    -v "${PWD}/hoprd.cfg.yaml.tpl:/app/hoprd.cfg.yaml.tpl:ro" \
    -v "${PWD}/${STUB}:/bin/docker-entrypoint.sh:ro" \
    -e HOPRD_CONFIGURATION_FILE_PATH="${UPLOAD}" \
    "$@" \
    --entrypoint /bin/entrypoint.sh \
    "${IMAGE}" 2>&1 || true
}

# The template as entrypoint.sh renders it.
render_template() {
  sed -e "s|__GNOSISVPN_SERVER_IP__|${SERVER_ADDRESS}|g" \
    -e "s|__BLOKLI_URL__|${TEMPLATE_BLOKLI_URL}|g" hoprd.cfg.yaml.tpl
}

volume_file() { # $1 = file name inside /app/hoprd/conf, empty when absent
  docker run --rm -v "${CONF_VOLUME}:/conf" --entrypoint cat "${IMAGE}" "/conf/$1" 2>/dev/null || true
}

volume_has() { docker run --rm -v "${CONF_VOLUME}:/conf" --entrypoint test "${IMAGE}" -e "/conf/$1"; }

write_volume_file() { # $1 = file name inside /app/hoprd/conf, stdin = contents
  docker run --rm -i -v "${CONF_VOLUME}:/conf" --entrypoint sh "${IMAGE}" -c "cat >'/conf/$1'"
}

remove_upload() { docker run --rm -v "${CONF_VOLUME}:/conf" --entrypoint rm "${IMAGE}" -f /conf/hoprd.custom.cfg.yaml; }

echo "### boot without a network"
out="$(run_entrypoint)"
rendered="$(volume_file hoprd.generated.cfg.yaml)"
expect_contains "${rendered}" "- \"${SERVER_ADDRESS}:51820\"" "renders gnosisvpn-server's WireGuard address"
expect_contains "${rendered}" "- \"${SERVER_ADDRESS}:8000\"" "renders gnosisvpn-server's control address"
expect_contains "${rendered}" "  blokli_url: ${TEMPLATE_BLOKLI_URL}" "gives the PIX pool the node's Blokli URL"
expect_not_contains "${rendered}" "__" "leaves no placeholder behind"
expect_contains "${out}" "stub: pid=1 ppid=0" "execs into hoprd instead of forking"
if volume_has hoprd.custom.cfg.yaml; then
  fail "wrote to the setup wizard's upload path"
else
  pass "leaves the setup wizard's upload path alone"
fi

echo
echo "### leftover rendered config at the upload path (what older versions wrote there)"
sed "s|__GNOSISVPN_SERVER_IP__|${STALE_ADDRESS}|g" hoprd.cfg.yaml.tpl | write_volume_file hoprd.custom.cfg.yaml
out="$(run_entrypoint)"
rendered="$(volume_file hoprd.generated.cfg.yaml)"
expect_contains "${out}" "ignoring ${UPLOAD}" "ignores it"
expect_contains "${rendered}" "- \"${SERVER_ADDRESS}:51820\"" "renders the fixed address instead"
expect_not_contains "${rendered}" "${STALE_ADDRESS}" "does not let it pin the stale address"
if volume_has hoprd.custom.cfg.yaml; then
  pass "leaves the operator's file in place"
else
  fail "deleted the file at the upload path"
fi

echo
echo "### leftover from an older release whose template had other settings"
# Releases before the probe_interval setting rendered their template without it.
sed -e '/^hopr:/,/probe_interval/d' -e "s|__GNOSISVPN_SERVER_IP__|${STALE_ADDRESS}|g" \
  hoprd.cfg.yaml.tpl | write_volume_file hoprd.custom.cfg.yaml
out="$(run_entrypoint)"
rendered="$(volume_file hoprd.generated.cfg.yaml)"
expect_contains "${out}" "ignoring ${UPLOAD}" "ignores it"
if [ "${rendered}" = "$(render_template)" ]; then
  pass "renders the current template instead"
else
  fail "did not render the current template: $(diff <(echo "${rendered}") <(render_template) | head -n 5)"
fi

echo
echo "### HOPRD_BLOKLI_URL from the setup wizard"
out="$(run_entrypoint -e HOPRD_BLOKLI_URL=https://wizard.invalid)"
rendered="$(volume_file hoprd.generated.cfg.yaml)"
expect_contains "${rendered}" "  blokli_url: https://wizard.invalid" "gives it to the PIX pool"

echo
echo "### a real upload using the placeholder"
sed 's|^blokli_url: .*|blokli_url: https://uploaded.invalid|' hoprd.cfg.yaml.tpl |
  write_volume_file hoprd.custom.cfg.yaml
out="$(run_entrypoint)"
rendered="$(volume_file hoprd.generated.cfg.yaml)"
expect_contains "${out}" "using uploaded ${UPLOAD}" "uses it"
expect_contains "${rendered}" "blokli_url: https://uploaded.invalid" "carries its own content through"
expect_contains "${rendered}" "  blokli_url: https://uploaded.invalid" "gives the PIX pool its Blokli URL"
expect_contains "${rendered}" "- \"${SERVER_ADDRESS}:51820\"" "replaces its placeholder with the fixed address"
expect_not_contains "${out}" "WARNING" "does not warn"

echo
echo "### a real upload that writes the fixed address out"
sed -e 's|^blokli_url: .*|blokli_url: https://uploaded.invalid|' \
  -e "s|__GNOSISVPN_SERVER_IP__|${SERVER_ADDRESS}|g" hoprd.cfg.yaml.tpl |
  write_volume_file hoprd.custom.cfg.yaml
out="$(run_entrypoint)"
expect_contains "${out}" "using uploaded ${UPLOAD}" "uses it"
expect_not_contains "${out}" "WARNING" "does not warn"

echo
echo "### a real upload that hardcodes another address"
# Without the template's comment on the WireGuard entry, which marks older versions' output.
sed -e 's|^blokli_url: .*|blokli_url: https://uploaded.invalid|' \
  -e "s|__GNOSISVPN_SERVER_IP__:51820\".*|${STALE_ADDRESS}:51820\"|" \
  -e "s|__GNOSISVPN_SERVER_IP__|${STALE_ADDRESS}|g" hoprd.cfg.yaml.tpl |
  write_volume_file hoprd.custom.cfg.yaml
out="$(run_entrypoint)"
rendered="$(volume_file hoprd.generated.cfg.yaml)"
expect_contains "${out}" "using uploaded ${UPLOAD}" "uses it"
expect_contains "${out}" "WARNING: ${UPLOAD} does not forward to gnosisvpn-server at ${SERVER_ADDRESS}" "warns that hoprd won't reach gnosisvpn-server"
expect_contains "${rendered}" "- \"${STALE_ADDRESS}:51820\"" "keeps what the operator wrote"

echo
echo "### a real upload without PIX"
sed -e 's|^blokli_url: .*|blokli_url: https://uploaded.invalid|' -e '/^    - Pix:/,$d' hoprd.cfg.yaml.tpl |
  write_volume_file hoprd.custom.cfg.yaml
out="$(run_entrypoint)"
expect_contains "${out}" "using uploaded ${UPLOAD}" "uses it"
expect_contains "${out}" "WARNING: ${UPLOAD} does not set the Pix strategy's pool.blokli_url to __BLOKLI_URL__" \
  "warns that PIX payments may not work"

echo
echo "### a real upload with blokli_url on its own line"
sed 's|^blokli_url: \(.*\)|blokli_url:\n  \1|' hoprd.cfg.yaml.tpl | write_volume_file hoprd.custom.cfg.yaml
out="$(run_entrypoint)"
expect_contains "${out}" "no blokli_url for the PIX pool" "stops with a clear error"
expect_not_contains "${out}" "stub: pid" "does not start hoprd"
remove_upload

echo
if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
