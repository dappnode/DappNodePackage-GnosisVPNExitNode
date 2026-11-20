#!/bin/bash
# Populates the blocklist ipset the FORWARD DROP rules in wg-hooks.sh use.
# Ported from gvpn-exit-os (itself from gnosis_vpn-infrastructure,
# roles/gnosisvpn-blocklist): the Ansible variables arrive here as environment
# variables instead of exit.env.
#
# Three modes:
#   --from-cache  load the local cache file only (no network). entrypoint.sh
#                 runs this before gnosis_vpn-server, so the last known-good
#                 list is in effect for the first forwarded packet.
#   --refresh     fetch the threat feeds, refresh the cache, swap into the set.
#   --loop        refresh now, then every REFRESH_INTERVAL_S plus jitter. The
#                 appliance uses a systemd timer for this; a container has no
#                 timer, so entrypoint.sh runs this mode as a child process.
#
# Populating the live set always goes through an atomic `ipset swap`, so in-flight
# packets never see a partially-built set. The set is fail-open: any degraded
# path keeps the existing set (or an empty one) and the script still exits 0,
# reporting the problem in the log rather than failing the exit node.
set -euo pipefail

IPSET_NAME="${GVPN_BLOCKLIST_IPSET_NAME:-gvpn-blocklist}"
IPSET_STAGING="${IPSET_NAME}-staging-$$"
IPSET_MAXELEM="${GVPN_BLOCKLIST_MAXELEM:-131072}"
CACHE_DIR="${GVPN_BLOCKLIST_CACHE_DIR:-/data/blocklist}"
CACHE_FILE="${CACHE_DIR}/blocklist.cidr"
MIN_ENTRIES="${GVPN_BLOCKLIST_MIN_ENTRIES:-1000}"
CURL_TIMEOUT="${GVPN_BLOCKLIST_CURL_TIMEOUT:-30}"
# Hard cap on each feed's download size. Bounds disk/memory use if a feed is
# compromised or misbehaving and streams an unexpectedly large body.
MAX_FILESIZE="${GVPN_BLOCKLIST_MAX_FILESIZE:-67108864}"
REFRESH_INTERVAL_S="${GVPN_BLOCKLIST_REFRESH_INTERVAL_S:-43200}"
REFRESH_JITTER_S="${GVPN_BLOCKLIST_REFRESH_JITTER_S:-3600}"
# Space-separated feed URLs.
FEEDS="${GVPN_BLOCKLIST_FEEDS:-https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset}"

# Space- or newline-separated, so a value entered with one URL per line works
# too: `read` on its own would keep only the first line.
read -r -a FEED_LIST <<<"${FEEDS//$'\n'/ }"

TMP_DIR=""
RESTORE_FILE=""

usage() {
  echo "usage: ${0} --from-cache|--refresh|--loop" >&2
  exit 64
}

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] gvpn-blocklist: $*"; }

cleanup() {
  [[ -n "${RESTORE_FILE}" ]] && rm -f "${RESTORE_FILE}"
  [[ -n "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
  ipset destroy "${IPSET_STAGING}" 2>/dev/null || true
}
trap cleanup EXIT

# Strip comments (; and #), drop whitespace, keep only valid IPv4 / IPv4-CIDR
# tokens (bare IPs are valid hash:net members, treated as /32).
#
# IPv4-only by design: the live set is `family inet` and this parser rejects any
# non-IPv4 token. That is safe only while client IPv6 never enters the tunnel,
# which holds because gnosis_vpn-server adds every peer with an IPv4 /32
# allowed-ips and wggvpn carries no IPv6 address. If that ever changes, blocked
# destinations become reachable over IPv6 and a family inet6 set is needed.
#
# The octet (0-255) and prefix (/0../32) sub-patterns are validated here so that
# ipset never sees an out-of-range token that would abort the whole restore.
# Prefixes shorter than /8 are accepted only for the statically dropped 224/3
# bogon range: a single 0.0.0.0/1 or 128.0.0.0/1 would send every VPN session
# into the blocklist DROP while the entry-count checks stay green.
parse_feed() {
  sed -e 's/[;#].*$//' -e 's/[[:space:]]//g' \
    | grep -E '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(/(3[0-2]|[12][0-9]|[0-9]))?$' \
    | awk -F '[./]' 'NF == 4 || $5 >= 8 || $0 == "224.0.0.0/3"' || true
}

# Whether a parsed entry count is within the acceptable [MIN_ENTRIES, IPSET_MAXELEM]
# range. A count outside this band is treated as a degraded/broken list and the
# caller keeps the existing set instead of swapping (fail-safe).
count_within_bounds() {
  local count="$1"
  if [[ "${count}" -lt "${MIN_ENTRIES}" ]]; then
    log "ERROR ${count} entries (< ${MIN_ENTRIES}); keeping existing set"
    return 1
  fi
  if [[ "${count}" -gt "${IPSET_MAXELEM}" ]]; then
    log "ERROR ${count} entries (> maxelem ${IPSET_MAXELEM}); keeping existing set"
    return 1
  fi
  return 0
}

# Ensure the live set exists so the iptables DROP rules always resolve, even when
# we have nothing to populate it with.
ensure_live_set() {
  ipset create "${IPSET_NAME}" hash:net family inet maxelem "${IPSET_MAXELEM}" -exist
}

# Build and validate the staging set from $1. This is intentionally separated
# from cache publication so malformed feed/cache data never becomes the new
# known-good cache.
stage_set() {
  local src="$1"
  ipset destroy "${IPSET_STAGING}" 2>/dev/null || true
  RESTORE_FILE=$(mktemp) || return 1
  {
    echo "create ${IPSET_STAGING} hash:net family inet maxelem ${IPSET_MAXELEM}"
    sed "s|^|add ${IPSET_STAGING} |" "${src}"
  } >"${RESTORE_FILE}" || return 1
  # -exist makes the adds idempotent: a duplicate CIDR (e.g. a bare IP from one
  # feed colliding with the same X/32 from another) no longer aborts the whole
  # restore.
  ipset restore -exist <"${RESTORE_FILE}" || return 1
  rm -f "${RESTORE_FILE}"
  RESTORE_FILE=""
}

# Atomically replace the live set's contents with the already-validated CIDRs in
# $1.
swap_in() {
  local src="$1"
  stage_set "${src}" || return 1
  ensure_live_set || return 1
  ipset swap "${IPSET_STAGING}" "${IPSET_NAME}" || return 1
  ipset destroy "${IPSET_STAGING}" 2>/dev/null || true
}

publish_cache() {
  local src="$1"
  mkdir -p "${CACHE_DIR}" || return 1
  cp "${src}" "${CACHE_FILE}.tmp" || return 1
  mv "${CACHE_FILE}.tmp" "${CACHE_FILE}" || return 1
}

# Entries currently in the live set, for the log.
live_entries() {
  ipset list "${IPSET_NAME}" 2>/dev/null | awk '/Number of entries/ { print $4 }'
}

# Log what the live set holds after a degraded run: the set is fail-open, so a
# failed refresh keeps the previous list and shows up here only.
report_live_set() {
  local entries
  entries="$(live_entries || true)"
  log "live set holds ${entries:-unknown} entries"
}

populate_from_cache() {
  local count
  if [[ ! -s "${CACHE_FILE}" ]]; then
    log "ERROR cache file ${CACHE_FILE} missing or empty; leaving set empty"
    ensure_live_set || log "ERROR could not create ${IPSET_NAME}"
    report_live_set
    return 0
  fi
  count=$(wc -l <"${CACHE_FILE}")
  if ! count_within_bounds "${count}"; then
    report_live_set
    return 0
  fi
  if ! swap_in "${CACHE_FILE}"; then
    log "ERROR cache failed ipset validation; keeping existing set"
    report_live_set
    return 0
  fi
  log "populated from cache: ${count} entries"
}

refresh() {
  local all url feed_failed=0 feed_success=0 count
  # --loop calls this repeatedly and never reaches the EXIT trap, so each run
  # clears the previous run's directory.
  [[ -n "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
  TMP_DIR=$(mktemp -d)
  all="${TMP_DIR}/all.cidr"
  : >"${all}"
  for url in "${FEED_LIST[@]}"; do
    if curl -fsSL --max-time "${CURL_TIMEOUT}" --max-filesize "${MAX_FILESIZE}" --retry 3 --retry-delay 5 "${url}" >"${TMP_DIR}/feed"; then
      parse_feed <"${TMP_DIR}/feed" >>"${all}"
      feed_success=$((feed_success + 1))
      log "fetched ${url}"
    else
      feed_failed=1
      log "WARN failed to fetch ${url}"
    fi
  done

  if [[ "${feed_success}" -eq 0 ]]; then
    log "ERROR all feeds failed; falling back to cache"
    populate_from_cache
    return 0
  fi
  if [[ "${feed_failed}" -ne 0 ]]; then
    log "ERROR one or more feeds failed; keeping existing set and cache"
    report_live_set
    return 0
  fi

  sort -u "${all}" -o "${all}"
  count=$(wc -l <"${all}")
  if ! count_within_bounds "${count}"; then
    report_live_set
    return 0
  fi

  if ! swap_in "${all}"; then
    log "ERROR parsed CIDR list failed ipset validation; keeping existing set and cache"
    report_live_set
    return 0
  fi
  if ! publish_cache "${all}"; then
    log "ERROR failed to update cache after live swap"
    report_live_set
    return 0
  fi
  log "refresh complete: ${count} entries"
}

loop() {
  local delay interval="${REFRESH_INTERVAL_S}" jitter="${REFRESH_JITTER_S}"
  # A value that is not a number makes `sleep` fail, which would turn this into
  # a busy refresh loop against the feeds. Fall back to the defaults instead.
  if ! [[ "${interval}" =~ ^[1-9][0-9]*$ ]]; then
    log "WARN GVPN_BLOCKLIST_REFRESH_INTERVAL_S='${interval}' is not a positive integer; using 43200"
    interval=43200
  fi
  if ! [[ "${jitter}" =~ ^[0-9]+$ ]]; then
    log "WARN GVPN_BLOCKLIST_REFRESH_JITTER_S='${jitter}' is not a whole number; using 3600"
    jitter=3600
  fi
  while :; do
    refresh || true
    delay=$((interval + RANDOM % (jitter + 1)))
    log "next refresh in ${delay}s"
    sleep "${delay}"
  done
}

main() {
  case "${1:-}" in
    --from-cache) populate_from_cache ;;
    --refresh) refresh ;;
    --loop) loop ;;
    *) usage ;;
  esac
}

# Only dispatch when executed directly, not when sourced (the check scripts
# exercise parse_feed and count_within_bounds in isolation).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
