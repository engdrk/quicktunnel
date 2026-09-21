#!/usr/bin/env bash
# Supervisor: runs xray and cloudflared together and keeps the published
# connection details in sync. This is what the service unit executes.
#
# In quick mode the *.trycloudflare.com hostname is re-issued on every start,
# so the client config and share URI are regenerated here rather than at
# install time.
set -uo pipefail

QT_PREFIX="${QT_PREFIX:-/usr/local/quicktunnel}"
# shellcheck disable=SC1091
. "$QT_PREFIX/lib/common.sh"
# shellcheck disable=SC1091
. "$QT_PREFIX/lib/deps.sh"
# shellcheck disable=SC1091
. "$QT_PREFIX/lib/config.sh"
# shellcheck disable=SC1091
. "$QT_PREFIX/lib/traffic.sh"

qt_load_conf
mkdir -p "$QT_LOG" "$QT_RUN"

XRAY_BIN="$(qt_xray_bin)"; CFD_BIN="$(qt_cloudflared_bin)"
[ -x "$XRAY_BIN" ] || die "xray not found at $QT_BIN/xray"
[ -x "$CFD_BIN" ]  || die "cloudflared not found at $QT_BIN/cloudflared"

XRAY_PID=''; CFD_PID=''; NAP_PID=''; RELOAD=0
cleanup() {
  [ -n "$XRAY_PID" ] && kill -0 "$XRAY_PID" 2>/dev/null && qt_traffic_collect 2>/dev/null
  [ -n "$XRAY_PID" ] && kill "$XRAY_PID" 2>/dev/null
  [ -n "$CFD_PID" ]  && kill "$CFD_PID"  2>/dev/null
  [ -n "$NAP_PID" ]  && kill "$NAP_PID"  2>/dev/null
  rm -f "$QT_RUN/hostname"
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM
trap 'RELOAD=1' USR1

stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

start_xray() {
  "$XRAY_BIN" run -c "$QT_ETC/server.json" >>"$QT_LOG/xray.log" 2>&1 &
  XRAY_PID=$!
}

reload_xray() {
  RELOAD=0
  local next="$QT_RUN/server.next.json"
  log "$(stamp) reload requested"
  # shellcheck disable=SC1091
  . "$QT_LIB/common.sh"; . "$QT_LIB/deps.sh"; . "$QT_LIB/config.sh"; . "$QT_LIB/traffic.sh"
  qt_load_conf
  if ! qt_gen_server "$next" || ! "$XRAY_BIN" run -test -c "$next" >>"$QT_LOG/xray.log" 2>&1; then
    rm -f "$next"
    log "$(stamp) reload aborted: generated config failed validation, keeping the running xray"
    return
  fi
  mv -f "$next" "$QT_ETC/server.json"
  qt_traffic_collect 2>/dev/null || log "$(stamp) traffic: could not read counters before reload"
  kill "$XRAY_PID" 2>/dev/null
  wait "$XRAY_PID" 2>/dev/null
  start_xray
  qt_gen_client "$HOST"
  qt_write_state "$HOST"
  log "$(stamp) xray reloaded ($(qt_exit_rows | wc -l) exits), tunnel untouched: https://$HOST"
  qt_announce_links "$HOST" "exits changed"
}

qt_gen_server

log "$(stamp) starting xray on 127.0.0.1:$QT_PORT"
start_xray

if [ "$QT_MODE" = named ] && [ -n "$QT_TUNNEL_TOKEN" ]; then
  log "$(stamp) starting remotely-managed tunnel '$QT_TUNNEL_NAME' -> $QT_HOSTNAME"
  TUNNEL_TOKEN="$QT_TUNNEL_TOKEN" "$CFD_BIN" tunnel --no-autoupdate \
    --metrics "$QT_METRICS" run >>"$QT_LOG/tunnel.log" 2>&1 &
  CFD_PID=$!
  HOST="$QT_HOSTNAME"
elif [ "$QT_MODE" = named ]; then
  log "$(date -u '+%Y-%m-%dT%H:%M:%SZ') starting named tunnel '$QT_TUNNEL_NAME' -> $QT_HOSTNAME"
  "$CFD_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:$QT_PORT" \
    --metrics "$QT_METRICS" run "$QT_TUNNEL_NAME" >>"$QT_LOG/tunnel.log" 2>&1 &
  CFD_PID=$!
  HOST="$QT_HOSTNAME"
else
  log "$(date -u '+%Y-%m-%dT%H:%M:%SZ') starting quick tunnel"
  "$CFD_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:$QT_PORT" \
    --metrics "$QT_METRICS" >>"$QT_LOG/tunnel.log" 2>&1 &
  CFD_PID=$!
  # cloudflared publishes the assigned hostname on its metrics server; this is
  # far more robust than scraping the startup banner out of stderr.
  HOST="$(curl -sf --retry 40 --retry-delay 1 --retry-connrefused --retry-all-errors \
           --max-time 90 "http://$QT_METRICS/quicktunnel" \
           | sed 's/.*"hostname":"\([^"]*\)".*/\1/')"
  if [ -z "$HOST" ]; then
    log "ERROR: could not obtain tunnel hostname; see $QT_LOG/tunnel.log"
    exit 1
  fi
fi

qt_gen_client "$HOST"
qt_write_state "$HOST"
log "$(date -u '+%Y-%m-%dT%H:%M:%SZ') up: https://$HOST"
qt_announce_links "$HOST" "tunnel up — new links"

# If either process dies, exit so the service manager restarts the whole pair.
# A lone xray with no tunnel (or vice versa) is useless, and in quick mode a
# cloudflared restart means a new hostname that must be republished.
TICK=0
while :; do
  [ "$RELOAD" -eq 1 ] && reload_xray
  TICK=$((TICK + 1))
  if [ $((TICK % 12)) -eq 0 ]; then
    qt_load_conf
    qt_announce_links "$HOST" "tunnel up — new links"
    qt_traffic_collect 2>/dev/null || true
    qt_traffic_daily_report
  fi
  if ! kill -0 "$XRAY_PID" 2>/dev/null; then log "xray exited"; exit 1; fi
  if ! kill -0 "$CFD_PID"  2>/dev/null; then log "cloudflared exited"; exit 1; fi
  sleep 5 & NAP_PID=$!
  wait "$NAP_PID" 2>/dev/null
  kill "$NAP_PID" 2>/dev/null
  NAP_PID=''
done
