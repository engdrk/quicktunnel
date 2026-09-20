#!/usr/bin/env bash
# quicktunnel installer — Xray (VLESS/WebSocket) behind a Cloudflare Tunnel.
#
#   sudo ./install.sh                 interactive
#   sudo ./install.sh --yes           non-interactive, defaults
#   sudo ./install.sh --mode named --hostname proxy.example.com --tunnel-name xray --yes
#
# Everything lands under $QT_PREFIX (default /usr/local/quicktunnel) and is
# managed afterwards with `quicktunnel-cli`.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT_PREFIX="${QT_PREFIX:-/usr/local/quicktunnel}"

# shellcheck disable=SC1091
. "$SRC/lib/common.sh"
# shellcheck disable=SC1091
. "$SRC/lib/deps.sh"
# shellcheck disable=SC1091
. "$SRC/lib/config.sh"
# shellcheck disable=SC1091
. "$SRC/lib/qr.sh"
# shellcheck disable=SC1091
. "$SRC/lib/service.sh"
# shellcheck disable=SC1091
. "$SRC/lib/wizard.sh"

ASSUME_YES=0
NO_SERVICE=0

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)        ASSUME_YES=1 ;;
    --prefix)        QT_PREFIX="$2"; shift ;;
    --mode)          QT_MODE="$2"; shift ;;
    --hostname)      QT_HOSTNAME="$2"; shift ;;
    --tunnel-name)   QT_TUNNEL_NAME="$2"; shift ;;
    --port)          QT_PORT="$2"; shift ;;
    --socks-port)    QT_SOCKS_PORT="$2"; shift ;;
    --uuid)          QT_UUID="$2"; shift ;;
    --ws-path)       QT_WSPATH="$2"; shift ;;
    --remark)        QT_REMARK="$2"; shift ;;
    --heartbeat)     QT_HEARTBEAT="$2"; shift ;;
    --no-service)    NO_SERVICE=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# Re-derive the paths in case --prefix moved them.
QT_CONF="$QT_PREFIX/etc/quicktunnel.conf"
QT_BIN="$QT_PREFIX/bin"; QT_ETC="$QT_PREFIX/etc"
QT_LOG="$QT_PREFIX/log"; QT_RUN="$QT_PREFIX/run"; QT_LIB="$QT_PREFIX/lib"
QT_SYSTEMD_UNIT="/etc/systemd/system/${QT_SERVICE_NAME}.service"
QT_PLIST="/Library/LaunchDaemons/${QT_PLIST_LABEL}.plist"

# Root is only genuinely needed for the service manager and for writing under
# /usr/local. A --no-service install into a writable prefix runs unprivileged,
# which also makes the installer testable without touching the system.
qt_writable() { mkdir -p "$1" 2>/dev/null && [ -w "$1" ]; }
if [ "$NO_SERVICE" -eq 0 ] || ! qt_writable "$QT_PREFIX"; then
  need_root
fi
qt_need_tools

log ""
printf '%s  quicktunnel%s — Xray over Cloudflare Tunnel\n' "$C_BOLD" "$C_RESET"
printf '  %s%s / %s -> %s%s\n' "$C_DIM" "$(qt_os)" "$(qt_arch)" "$QT_PREFIX" "$C_RESET"
log ""

# Carry forward an existing install so re-running is an upgrade, not a reset.
if [ -f "$QT_CONF" ]; then
  info "existing install found — current settings will be offered as defaults"
  # shellcheck disable=SC1090
  . "$QT_CONF"
fi

mkdir -p "$QT_BIN" "$QT_ETC" "$QT_LOG" "$QT_RUN" "$QT_LIB"

info "installing scripts"
install -m 0644 "$SRC"/lib/common.sh "$SRC"/lib/deps.sh "$SRC"/lib/config.sh \
                "$SRC"/lib/qr.sh "$SRC"/lib/service.sh "$SRC"/lib/wizard.sh "$QT_LIB/"
install -m 0755 "$SRC"/lib/run.sh "$QT_LIB/run.sh"
install -m 0755 "$SRC"/bin/quicktunnel-cli "$QT_BIN/quicktunnel-cli"
if mkdir -p /usr/local/bin 2>/dev/null && [ -w /usr/local/bin ]; then
  ln -sf "$QT_BIN/quicktunnel-cli" /usr/local/bin/quicktunnel-cli
  ok "quicktunnel-cli -> /usr/local/bin/quicktunnel-cli"
else
  warn "/usr/local/bin not writable — call $QT_BIN/quicktunnel-cli directly"
fi

# Binaries first: the wizard uses `xray uuid` when it is available.
[ -x "$QT_BIN/xray" ]        || qt_fetch_xray
[ -x "$QT_BIN/cloudflared" ] || qt_fetch_cloudflared
qt_ensure_qrencode || true

if [ "$ASSUME_YES" -eq 1 ]; then
  QT_MODE="${QT_MODE:-quick}"
  QT_PORT="${QT_PORT:-8080}"
  QT_SOCKS_PORT="${QT_SOCKS_PORT:-10808}"
  QT_HEARTBEAT="${QT_HEARTBEAT:-30}"
  QT_METRICS="${QT_METRICS:-127.0.0.1:20241}"
  QT_UUID="${QT_UUID:-$(qt_gen_uuid)}"
  QT_WSPATH="${QT_WSPATH:-$(rand_path)}"
  QT_REMARK="${QT_REMARK:-quicktunnel}"
  QT_HOSTNAME="${QT_HOSTNAME:-}"
  QT_TUNNEL_NAME="${QT_TUNNEL_NAME:-}"
  [ "$QT_MODE" = named ] && [ -z "$QT_HOSTNAME" ] && die "--mode named requires --hostname"
else
  qt_wizard
fi

qt_save_conf
qt_gen_server
ok "config written to $QT_CONF"

if [ "$NO_SERVICE" -eq 1 ]; then
  warn "skipping service installation (--no-service)"
  log ""
  log "run it manually with:  sudo $QT_LIB/run.sh"
  exit 0
fi

info "installing service ($(qt_service_kind))"
qt_service_install || { warn "no service manager — start manually: sudo $QT_LIB/run.sh"; exit 0; }

info "starting"
qt_service_stop
qt_service_start

# In quick mode the hostname only exists once cloudflared has registered.
printf '  waiting for the tunnel'
HOST=''
for _ in $(seq 1 60); do
  if [ -s "$QT_RUN/hostname" ]; then HOST="$(cat "$QT_RUN/hostname")"; break; fi
  printf '.'; sleep 1
done
printf '\n'

if [ -z "$HOST" ]; then
  warn "the tunnel did not come up in 60s"
  log "check:  quicktunnel-cli log tunnel"
  exit 1
fi

ok "tunnel up: https://$HOST"
qt_show_link_and_qr

cat <<DONE
  ${C_BOLD}next${C_RESET}
    quicktunnel-cli status      service state and hostname
    quicktunnel-cli qr          show the QR code again
    quicktunnel-cli client      print the client config JSON

DONE

if [ "$QT_MODE" = quick ]; then
  printf '  %sQuick mode: the hostname changes on every restart, so re-scan the QR\n' "$C_YELLOW"
  printf '  after each restart. Use named mode for a stable address.%s\n\n' "$C_RESET"
fi
