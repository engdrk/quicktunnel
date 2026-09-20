#!/usr/bin/env bash
# Interactive setup wizard, shared by install.sh and 'quicktunnel-cli reconfigure'.
# Every prompt is pre-filled with the current value (on reconfigure) or a
# sensible default, so pressing Enter through the whole thing is valid.

qt_gen_uuid() {
  local xb
  xb="$(qt_xray_bin 2>/dev/null || true)"
  if [ -n "$xb" ] && [ -x "$xb" ]; then "$xb" uuid; return; fi
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; return; fi
  # Last resort: build a v4 UUID out of urandom.
  od -An -tx1 -N16 /dev/urandom | tr -d ' \n' | awk '{
    printf "%s-%s-4%s-a%s-%s\n", substr($0,1,8), substr($0,9,4),
           substr($0,14,3), substr($0,18,3), substr($0,21,12) }'
}

qt_wizard() {
  local c

  log ""
  printf '%s%s%s\n' "$C_BOLD" "Tunnel mode" "$C_RESET"
  log ""
  printf '  %sQuick%s  — free, no account, random *.trycloudflare.com name.\n' "$C_BOLD" "$C_RESET"
  printf '           The hostname changes on EVERY restart, so clients must be\n'
  printf '           re-imported each time. Cloudflare gives it no uptime guarantee.\n'
  log ""
  printf '  %sNamed%s  — fixed hostname on a domain you already have in Cloudflare.\n' "$C_BOLD" "$C_RESET"
  printf '           Requires a one-time login and DNS route (see README).\n'
  log ""

  case "${QT_MODE:-quick}" in named) c=2 ;; *) c=1 ;; esac
  c="$(ask_choice "Which mode?" "$c" "quick tunnel (no account)" "named tunnel (fixed hostname)")"
  case "$c" in
    1) QT_MODE=quick ;;
    2) QT_MODE=named ;;
  esac

  if [ "$QT_MODE" = named ]; then
    log ""
    printf '  %sBefore this works, run once:%s\n' "$C_DIM" "$C_RESET"
    printf '    cloudflared tunnel login\n'
    printf '    cloudflared tunnel create <name>\n'
    printf '    cloudflared tunnel route dns <name> <hostname>\n'
    log ""
    QT_TUNNEL_NAME="$(ask 'Tunnel name' "${QT_TUNNEL_NAME:-quicktunnel}")"
    QT_HOSTNAME="$(ask 'Public hostname' "${QT_HOSTNAME:-}" valid_host)"
  else
    QT_HOSTNAME=''
    QT_TUNNEL_NAME=''
  fi

  log ""
  printf '%s%s%s\n' "$C_BOLD" "Ports" "$C_RESET"
  log ""
  while :; do
    QT_PORT="$(ask 'Local origin port (cloudflared -> xray, loopback only)' "${QT_PORT:-8080}" valid_port)"
    if port_in_use "$QT_PORT" && ! qt_self_running; then
      warn "port $QT_PORT is already in use by another process"
      ask_yn "Use it anyway?" n && break
    else
      break
    fi
  done
  QT_SOCKS_PORT="$(ask 'SOCKS port to put in the generated client config' "${QT_SOCKS_PORT:-10808}" valid_port)"

  log ""
  printf '%s%s%s\n' "$C_BOLD" "Credentials" "$C_RESET"
  log ""
  if [ -n "${QT_UUID:-}" ]; then
    printf '  current UUID: %s\n' "$QT_UUID"
    ask_yn "Generate a NEW UUID? (invalidates existing clients)" n && QT_UUID="$(qt_gen_uuid)"
  else
    QT_UUID="$(qt_gen_uuid)"
    printf '  generated UUID: %s\n' "$QT_UUID"
    ask_yn "Use a custom UUID instead?" n && QT_UUID="$(ask 'UUID' "$QT_UUID" valid_uuid)"
  fi

  if [ -n "${QT_WSPATH:-}" ]; then
    printf '  current WS path: %s\n' "$QT_WSPATH"
    ask_yn "Generate a NEW WebSocket path?" n && QT_WSPATH="$(rand_path)"
  else
    QT_WSPATH="$(rand_path)"
    printf '  generated WS path: %s\n' "$QT_WSPATH"
    ask_yn "Use a custom path instead?" n && QT_WSPATH="$(ask 'WebSocket path' "$QT_WSPATH" valid_path)"
  fi

  log ""
  printf '%s%s%s\n' "$C_BOLD" "Label" "$C_RESET"
  log ""
  printf '  %sShown as the config name in client apps, and used as the URI fragment.\n' "$C_DIM"
  printf '  Keep it short — it goes into the QR code.%s\n' "$C_RESET"
  QT_REMARK="$(ask 'Config remark' "${QT_REMARK:-quicktunnel}")"

  log ""
  printf '%s%s%s\n' "$C_BOLD" "Tuning" "$C_RESET"
  log ""
  printf '  %sCloudflare drops idle WebSockets after 100s. A ping below that keeps\n' "$C_DIM"
  printf '  long-lived idle sessions (SSH, RDP) from dying silently.%s\n' "$C_RESET"
  QT_HEARTBEAT="$(ask 'WebSocket heartbeat seconds (0 disables)' "${QT_HEARTBEAT:-30}")"
  [[ "$QT_HEARTBEAT" =~ ^[0-9]+$ ]] || QT_HEARTBEAT=30
  if [ "$QT_HEARTBEAT" -ge 100 ]; then
    warn "heartbeat >= 100s will not beat Cloudflare's idle timeout"
  fi

  QT_METRICS="${QT_METRICS:-127.0.0.1:20241}"
  if ask_yn "Change cloudflared metrics address (advanced)?" n; then
    QT_METRICS="$(ask 'Metrics listen address' "$QT_METRICS")"
  fi

  log ""
  printf '%s%s%s\n' "$C_BOLD" "Summary" "$C_RESET"
  log ""
  printf '  mode        %s\n' "$QT_MODE"
  [ "$QT_MODE" = named ] && printf '  hostname    %s (tunnel: %s)\n' "$QT_HOSTNAME" "$QT_TUNNEL_NAME"
  printf '  origin      127.0.0.1:%s\n' "$QT_PORT"
  printf '  socks       127.0.0.1:%s\n' "$QT_SOCKS_PORT"
  printf '  uuid        %s\n' "$QT_UUID"
  printf '  ws path     %s\n' "$QT_WSPATH"
  printf '  remark      %s\n' "$QT_REMARK"
  printf '  heartbeat   %ss\n' "$QT_HEARTBEAT"
  log ""
  ask_yn "Proceed with these settings?" y || die "cancelled"
}
