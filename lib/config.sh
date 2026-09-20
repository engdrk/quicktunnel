#!/usr/bin/env bash
# Generates the Xray server/client configs and the vless:// share URI.
#
# Transport is fixed to WebSocket on purpose. It is the only Xray transport that
# survives a Cloudflare Tunnel: the edge buffers whole response bodies (so
# XHTTP's downlink never streams) and rejects httpupgrade's handshake because
# Xray omits Sec-WebSocket-Key. WS is a 101 upgrade to a raw bidirectional pipe,
# which the edge passes through untouched.

# Cloudflare terminates TLS at the edge, so the inbound is plaintext on
# loopback. cloudflared is the only thing that ever connects to it.
#
# sockopt.trustedXForwardedFor takes HEADER NAMES, not IPs: Xray trusts the
# X-Forwarded-For value only when one of these headers is present. CF-Connecting-IP
# is always set by Cloudflare, so it works as the "this came via CF" marker and
# stops the per-connection "X-Forwarded-For ... is not configured" warning.
qt_gen_server() {
  mkdir -p "$QT_ETC"
  cat > "$QT_ETC/server.json" <<JSON
{
  "log": { "loglevel": "warning", "access": "$QT_LOG/access.log", "error": "$QT_LOG/error.log" },
  "inbounds": [{
    "tag": "in-ws",
    "listen": "127.0.0.1",
    "port": $QT_PORT,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$QT_UUID" }], "decryption": "none" },
    "streamSettings": {
      "network": "ws",
      "security": "none",
      "wsSettings": { "path": "$QT_WSPATH", "heartbeatPeriod": $QT_HEARTBEAT },
      "sockopt": { "trustedXForwardedFor": ["CF-Connecting-IP"] }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
JSON
  chmod 600 "$QT_ETC/server.json"
}

# $1 = public hostname
qt_gen_client() {
  local host="$1"
  mkdir -p "$QT_ETC"
  cat > "$QT_ETC/client.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "tag": "socks-in",
    "listen": "127.0.0.1",
    "port": $QT_SOCKS_PORT,
    "protocol": "socks",
    "settings": { "udp": true, "auth": "noauth" }
  }],
  "outbounds": [{
    "tag": "proxy",
    "protocol": "vless",
    "settings": { "vnext": [{
      "address": "$host",
      "port": 443,
      "users": [{ "id": "$QT_UUID", "encryption": "none" }]
    }]},
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": { "serverName": "$host", "alpn": ["http/1.1"] },
      "wsSettings": { "path": "$QT_WSPATH", "host": "$host", "heartbeatPeriod": $QT_HEARTBEAT }
    }
  }]
}
JSON
  chmod 600 "$QT_ETC/client.json"
}

# Builds the share URI.
#
# sni= and host= are deliberately omitted: both equal the address, and Xray
# already falls back that way — wsSettings.Host -> tlsSettings.ServerName ->
# destination address (websocket/dialer.go), and an empty ServerName is set to
# the destination address (tls/config.go). Dropping them removes three copies
# of a ~40-char hostname, which is what makes the QR code small enough to scan
# comfortably. Pass "full" to spell them out anyway.
#
# alpn stays: it is pinned to http/1.1 because Xray otherwise offers h2, and a
# negotiated h2 breaks the HTTP/1.1 WebSocket upgrade at the Cloudflare edge.
qt_build_link() {
  local host="$1" form="${2:-short}" encpath remark extra=''
  encpath="${QT_WSPATH//\//%2F}"
  remark="$(qt_urlencode "${QT_REMARK:-quicktunnel}")"
  if [ "$form" = full ]; then
    extra="&sni=$host&host=$host"
  fi
  printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&alpn=http%%2F1.1&fp=chrome&path=%s%s#%s' \
    "$QT_UUID" "$host" "$encpath" "$extra" "$remark"
}

# Percent-encode anything outside the unreserved set, so a remark may contain
# spaces or non-ASCII without breaking the URI fragment.
#
# LC_ALL=C makes `?` match one BYTE rather than one character, so multi-byte
# UTF-8 is encoded per byte as RFC 3986 requires. Uses only POSIX parameter
# expansion — ${s:i:1} is bash-only and silently misbehaves under zsh.
qt_urlencode() {
  local LC_ALL=C s="$1" out='' c
  while [ -n "$s" ]; do
    c="${s%"${s#?}"}"
    s="${s#?}"
    case "$c" in
      [A-Za-z0-9.~_-]) out="$out$c" ;;
      # & 0xFF because bash treats a high byte as a signed char and would
      # otherwise emit a sign-extended %FFFFFFFFFFFFFFD9 instead of %D9.
      *) out="$out$(printf '%%%02X' "$(( $(printf '%d' "'$c") & 0xFF ))")" ;;
    esac
  done
  printf '%s' "$out"
}

qt_write_state() {
  local host="$1"
  mkdir -p "$QT_RUN"
  printf '%s\n' "$host" > "$QT_RUN/hostname"
  qt_build_link "$host" > "$QT_RUN/link.txt"
  printf '\n' >> "$QT_RUN/link.txt"
  chmod 600 "$QT_RUN/link.txt"
}
