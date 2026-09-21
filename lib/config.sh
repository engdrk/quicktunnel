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
qt_exits_file() { printf '%s' "$QT_ETC/exits.json"; }

qt_exits_nonempty() {
  [ -s "$1" ] && command -v jq >/dev/null 2>&1 && [ "$(jq 'length' "$1" 2>/dev/null || echo 0)" -gt 0 ]
}

qt_has_exits() { qt_exits_nonempty "$(qt_exits_file)"; }

qt_exit_rows() {
  local exits="${1:-$(qt_exits_file)}"
  qt_exits_nonempty "$exits" || return 0
  jq -r --argjson base "$QT_SOCKS_PORT" \
    'to_entries[] | [.value.name, .value.uuid, (.value.port // ($base + .key + 1)), .value.outbound.protocol] | @tsv' "$exits"
}

qt_urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

qt_vless_outbound() {
  local uri="${1#vless://}" rest cred hostport host port query pairs=() kv k v
  uri="${uri%%#*}"
  cred="${uri%%@*}"; rest="${uri#*@}"
  hostport="${rest%%\?*}"; query=''
  [ "$rest" != "$hostport" ] && query="${rest#*\?}"
  hostport="${hostport%/}"
  port="${hostport##*:}"; host="${hostport%:*}"; host="${host#[}"; host="${host%]}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ -n "$cred" ] && [ -n "$host" ] || return 1
  IFS='&' read -r -a pairs <<< "$query"
  local args=(--arg id "$(qt_urldecode "$cred")" --arg address "$host" --argjson port "$port")
  local q='{}'
  for kv in "${pairs[@]}"; do
    [ -n "$kv" ] || continue
    k="${kv%%=*}"; v=''; [ "$kv" != "$k" ] && v="$(qt_urldecode "${kv#*=}")"
    q="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<< "$q")"
  done
  jq -nc "${args[@]}" --argjson q "$q" '
    ($q.type // "tcp") as $net
    | ($q.security // "none") as $sec
    | {
        protocol: "vless",
        settings: {vnext: [{address: $address, port: $port, users: [
          {id: $id, encryption: ($q.encryption // "none")} + (if ($q.flow // "") != "" then {flow: $q.flow} else {} end)
        ]}]},
        streamSettings: ({network: (if $net == "http" then "h2" else $net end), security: $sec}
          + (if $sec == "reality" then {realitySettings: ({
                serverName: ($q.sni // ""), fingerprint: ($q.fp // "chrome"), publicKey: ($q.pbk // ""),
                shortId: ($q.sid // ""), spiderX: ($q.spx // "")} | with_entries(select(.value != "")))}
             elif $sec == "tls" then {tlsSettings: ({
                serverName: ($q.sni // ""), fingerprint: ($q.fp // ""),
                alpn: (if ($q.alpn // "") == "" then "" else ($q.alpn | split(",")) end), allowInsecure: (($q.allowInsecure // "") == "1")}
                | with_entries(select(.value != "" and .value != null and .value != false)))}
             else {} end)
          + (if $net == "ws" then {wsSettings: ({path: ($q.path // "/"), host: ($q.host // "")} | with_entries(select(.value != "")))}
             elif $net == "grpc" then {grpcSettings: {serviceName: ($q.serviceName // ""), multiMode: (($q.mode // "") == "multi")}}
             elif $net == "xhttp" or $net == "splithttp" then {xhttpSettings: ({path: ($q.path // "/"), host: ($q.host // ""), mode: ($q.mode // "auto")} | with_entries(select(.value != "")))}
             elif $net == "httpupgrade" then {httpupgradeSettings: ({path: ($q.path // "/"), host: ($q.host // "")} | with_entries(select(.value != "")))}
             elif $net == "tcp" and ($q.headerType // "none") == "http" then {tcpSettings: {header: {type: "http", request: {path: [($q.path // "/")], headers: {Host: [($q.host // $address)]}}}}}
             else {} end))
      }'
}

qt_server_base_json() {
  cat <<JSON
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
}

qt_server_json() {
  local exits="${1:-$(qt_exits_file)}"
  if qt_exits_nonempty "$exits"; then
    qt_server_base_json | jq --slurpfile e "$exits" '
      $e[0] as $x
      | .inbounds[0].settings.clients[0].email = "default"
      | .inbounds[0].settings.clients += [$x[] | {id: .uuid, email: .name}]
      | .outbounds += [$x[] | .outbound + {tag: ("exit-" + .name)}]
      | .routing = {domainStrategy: "AsIs", rules: [$x[] | {type: "field", user: [.name], outboundTag: ("exit-" + .name)}]}'
  else
    qt_server_base_json
  fi
}

qt_gen_server() {
  local out="${1:-$QT_ETC/server.json}" exits="${2:-}"
  mkdir -p "$(dirname "$out")"
  qt_server_json "$exits" > "$out.tmp" || { rm -f "$out.tmp"; return 1; }
  chmod 600 "$out.tmp"
  mv -f "$out.tmp" "$out"
}

# $1 = public hostname
qt_client_base_json() {
  local host="$1"
  cat <<JSON
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
}

qt_gen_client() {
  local host="$1" out="$QT_ETC/client.json"
  mkdir -p "$QT_ETC"
  if qt_has_exits; then
    qt_client_base_json "$host" | jq --slurpfile e "$(qt_exits_file)" --argjson base "$QT_SOCKS_PORT" '
      $e[0] as $x
      | .outbounds[0] as $tpl
      | .inbounds += [$x | to_entries[] | {tag: ("socks-" + .value.name), listen: "127.0.0.1", port: (.value.port // ($base + .key + 1)), protocol: "socks", settings: {udp: true, auth: "noauth"}}]
      | .outbounds += [$x[] as $i | $tpl | .tag = ("proxy-" + $i.name) | .settings.vnext[0].users[0].id = $i.uuid]
      | .routing = {rules: [$x[] | {type: "field", inboundTag: ["socks-" + .name], outboundTag: ("proxy-" + .name)}]}' > "$out.tmp"
  else
    qt_client_base_json "$host" > "$out.tmp"
  fi
  chmod 600 "$out.tmp"
  mv -f "$out.tmp" "$out"
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
  local host="$1" form="${2:-short}" uuid="${3:-$QT_UUID}" label="${4:-${QT_REMARK:-quicktunnel}}" encpath remark extra=''
  encpath="${QT_WSPATH//\//%2F}"
  remark="$(qt_urlencode "$label")"
  if [ "$form" = full ]; then
    extra="&sni=$host&host=$host"
  fi
  printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&alpn=http%%2F1.1&fp=chrome&path=%s%s#%s' \
    "$uuid" "$host" "$encpath" "$extra" "$remark"
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
  qt_write_links "$host"
}

qt_write_links() {
  local host="$1" name uuid port proto out="$QT_RUN/links.tsv"
  {
    printf 'default\t%s\tdirect\t%s\n' "$QT_SOCKS_PORT" "$(qt_build_link "$host")"
    qt_exit_rows | while IFS=$'\t' read -r name uuid port proto; do
      printf '%s\t%s\t%s\t%s\n' "$name" "$port" "$proto" \
        "$(qt_build_link "$host" short "$uuid" "${QT_REMARK:-quicktunnel}-$name")"
    done
  } > "$out.tmp"
  chmod 600 "$out.tmp"
  mv -f "$out.tmp" "$out"
}
