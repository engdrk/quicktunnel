#!/usr/bin/env bash
# Shared helpers: logging, platform detection, config persistence.
# Sourced by install.sh, quicktunnel-cli and lib/run.sh.
#
# shellcheck disable=SC2034
# (the QT_* paths and C_* colours are consumed by the files that source this one,
#  which shellcheck cannot see)

QT_PREFIX="${QT_PREFIX:-/usr/local/quicktunnel}"
QT_CONF="$QT_PREFIX/etc/quicktunnel.conf"
QT_BIN="$QT_PREFIX/bin"
QT_ETC="$QT_PREFIX/etc"
QT_LOG="$QT_PREFIX/log"
QT_RUN="$QT_PREFIX/run"
QT_LIB="$QT_PREFIX/lib"
QT_SERVICE_NAME="quicktunnel"
QT_PLIST_LABEL="com.quicktunnel.daemon"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s==>%s %s\n' "$C_CYAN"   "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%sfail%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- platform ---

qt_os() {
  case "$(uname -s)" in
    Linux)  echo linux ;;
    Darwin) echo macos ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}

# Maps uname -m onto the asset suffix used by Xray-core releases.
qt_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo 64 ;;
    aarch64|arm64) echo arm64-v8a ;;
    armv7l)        echo arm32-v7a ;;
    i386|i686)     echo 32 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

qt_service_kind() {
  if [ "$(qt_os)" = macos ]; then echo launchd
  elif command -v systemctl >/dev/null 2>&1; then echo systemd
  else echo none
  fi
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "this needs root: re-run with sudo"
}

# Root only matters when the target is not already writable. Keeps --prefix
# installs manageable without sudo, same rule the installer uses.
need_write() {
  [ -w "$1" ] || [ -w "$(dirname "$1")" ] || need_root
}

# ------------------------------------------------------------------ config ---

# Config is a plain key=value file so both bash and the service can read it.
qt_load_conf() {
  [ -f "$QT_CONF" ] || die "not installed (no $QT_CONF) — run install.sh first"
  # shellcheck disable=SC1090
  . "$QT_CONF"
  # Defaults for keys added after an install, so upgrading does not break
  # on `set -u` when an older config file lacks them.
  QT_REMARK="${QT_REMARK:-quicktunnel}"
  QT_TUNNEL_TOKEN="${QT_TUNNEL_TOKEN:-}"
  QT_TG_TOKEN="${QT_TG_TOKEN:-}"
  QT_TG_CHAT="${QT_TG_CHAT:-}"
  QT_SUB_TOKEN="${QT_SUB_TOKEN:-}"
  QT_SUB_GIST="${QT_SUB_GIST:-}"
  QT_SUB_URL="${QT_SUB_URL:-}"
  QT_ACCESS_LOG="${QT_ACCESS_LOG:-off}"
}

qt_save_conf() {
  local k
  mkdir -p "$QT_ETC"
  umask 077
  {
    printf '# quicktunnel configuration — generated %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for k in QT_MODE QT_PORT QT_SOCKS_PORT QT_UUID QT_WSPATH QT_REMARK QT_HEARTBEAT QT_METRICS \
             QT_HOSTNAME QT_TUNNEL_NAME QT_TUNNEL_TOKEN QT_TG_TOKEN QT_TG_CHAT QT_SUB_TOKEN QT_SUB_GIST QT_SUB_URL QT_ACCESS_LOG; do
      printf '%s=%q\n' "$k" "${!k:-}"
    done
  } > "$QT_CONF"
  chmod 600 "$QT_CONF"
}

# ------------------------------------------------------------------ prompts ---

# ask <prompt> <default> [validator-fn]
ask() {
  local prompt="$1" default="${2:-}" validate="${3:-}" reply
  while :; do
    if [ -n "$default" ]; then
      printf '%s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$default" >&2
    else
      printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET" >&2
    fi
    if ! read -r reply; then reply=''; fi
    [ -z "$reply" ] && reply="$default"
    if [ -z "$reply" ]; then warn "a value is required"; continue; fi
    if [ -n "$validate" ] && ! "$validate" "$reply"; then continue; fi
    printf '%s' "$reply"; return 0
  done
}

ask_yn() {
  local prompt="$1" default="${2:-y}" reply hint
  case "$default" in y|Y) hint="Y/n" ;; *) hint="y/N" ;; esac
  while :; do
    printf '%s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$hint" >&2
    if ! read -r reply; then reply=''; fi
    [ -z "$reply" ] && reply="$default"
    case "$reply" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
      *) warn "please answer y or n" ;;
    esac
  done
}

# ask_choice <prompt> <default-index> <option>...
ask_choice() {
  local prompt="$1" default="$2"; shift 2
  local opts=("$@") i reply
  printf '%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET" >&2
  for i in "${!opts[@]}"; do
    printf '  %s) %s\n' "$((i+1))" "${opts[$i]}" >&2
  done
  while :; do
    printf 'choice [%s]: ' "$default" >&2
    if ! read -r reply; then reply=''; fi
    [ -z "$reply" ] && reply="$default"
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#opts[@]}" ]; then
      printf '%s' "$reply"; return 0
    fi
    warn "enter a number between 1 and ${#opts[@]}"
  done
}

valid_port() {
  if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then return 0; fi
  warn "not a valid port: $1"; return 1
}

valid_host() {
  if [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$1" == *.* ]]; then return 0; fi
  warn "not a valid hostname: $1"; return 1
}

valid_uuid() {
  if [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then return 0; fi
  warn "not a valid UUID: $1"; return 1
}

valid_path() {
  case "$1" in /*) return 0 ;; esac
  warn "path must start with /"; return 1
}

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

# True when our own supervisor is up: either a service manager owns it, or
# run.sh is alive (it writes run/hostname and clears it on exit). Used so the
# port-in-use check does not flag quicktunnel's own listener during reconfigure.
qt_self_running() {
  qt_service_running 2>/dev/null || [ -s "$QT_RUN/hostname" ]
}

rand_path() { printf '/%s' "$(head -c 9 /dev/urandom | base64 | tr -d '/+=')"; }
