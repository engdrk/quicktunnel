# quicktunnel

Runs an Xray **VLESS over WebSocket** server behind a **Cloudflare Tunnel**, so a
machine with no public IP and no open inbound ports is reachable over `443` at a
`*.trycloudflare.com` address (or your own hostname).

Installs to `/usr/local/quicktunnel`, registers a service, and prints a
`vless://` URI plus a scannable QR code.

```
client ──TLS/WS:443──▶ Cloudflare edge ──▶ cloudflared ──▶ xray (127.0.0.1) ──▶ internet
```

## Install

```bash
sudo ./install.sh
```

Interactive by default: it asks for the mode, ports, UUID, WebSocket path and
heartbeat, showing current values as defaults so Enter-through is safe.

Non-interactive:

```bash
sudo ./install.sh --yes
sudo ./install.sh --mode named --hostname proxy.example.com --tunnel-name xray --yes
```

| flag | meaning |
|---|---|
| `--yes` | accept defaults, no prompts |
| `--mode quick\|named` | tunnel mode |
| `--hostname H` | public hostname (named mode) |
| `--tunnel-name N` | cloudflared tunnel name (named mode) |
| `--port N` | loopback origin port cloudflared forwards to (default 8080) |
| `--socks-port N` | SOCKS port written into the client config (default 10808) |
| `--uuid U` / `--ws-path P` | supply instead of generating |
| `--remark R` | config name shown in client apps (default `quicktunnel`) |
| `--heartbeat N` | WebSocket ping interval, seconds (default 30) |
| `--prefix DIR` | install elsewhere (default `/usr/local/quicktunnel`) |
| `--no-service` | install files only, no service |

The installer verifies the Xray download against its published `SHA2-256`
digest and refuses to install on mismatch.

## Modes

**quick** — free, no Cloudflare account. The hostname is assigned randomly and
**re-issued on every restart**, so clients must be re-imported each time.
Cloudflare gives these no uptime guarantee.

**named** — a fixed hostname on a domain already in your Cloudflare account.
One-time setup:

```bash
cloudflared tunnel login
cloudflared tunnel create xray
cloudflared tunnel route dns xray proxy.example.com
```

Then install with `--mode named --hostname proxy.example.com --tunnel-name xray`.
The URI and QR stay valid across restarts.

## Managing it

```bash
quicktunnel-cli status         # service state, mode, current hostname
quicktunnel-cli qr             # QR code for the current URI
quicktunnel-cli link           # the vless:// URI
quicktunnel-cli link --full    # same, with redundant sni/host spelled out
quicktunnel-cli client         # client config JSON
quicktunnel-cli log -f tunnel  # daemon | xray | tunnel | access | error
quicktunnel-cli restart        # quick mode: yields a NEW hostname
quicktunnel-cli reconfigure    # re-run the wizard
quicktunnel-cli update         # update xray + cloudflared
quicktunnel-cli uninstall
```

Most commands need `sudo`: the config holds the client credential and is mode `600`.

## The share URI

The URI omits `sni=` and `host=`. Both would equal the address, and Xray
already falls back that way — `wsSettings.Host` -> `tlsSettings.ServerName` ->
destination address in `websocket/dialer.go`, and an empty `ServerName` is set
to the destination address in `tls/config.go`. Dropping them removes three
copies of a ~40-character hostname:

```
341 chars -> 195 chars      QR: 56x33 -> 47x27 characters
```

which is what makes the QR comfortably scannable in a terminal. `link --full`
emits the explicit form for any client that does not default them.

The remark (`--remark`, default `quicktunnel`) becomes the URI fragment and the
config name in client apps.

## Why WebSocket only

A Cloudflare Tunnel is an HTTP proxy, which rules out most Xray transports.
Measured against a live quick tunnel:

| transport | result | why |
|---|---|---|
| `ws` | **works** | 101 upgrade to a raw bidirectional pipe, passed through untouched |
| `xhttp` | fails | the edge buffers whole response bodies, so the downlink never streams |
| `httpupgrade` | fails | Xray omits `Sec-WebSocket-Key`, so the edge rejects the handshake |
| raw/Reality/Vision, mKCP, QUIC | impossible | TLS terminates at the edge; HTTP(S) on 80/443 only |

The XHTTP result was isolated with a plain SSE origin: chunks emitted 1s apart
at the origin arrived at the client **all at once**, after the response closed.
Xray logs a deprecation warning steering you from `ws` to XHTTP — ignore it
here, since XHTTP is exactly what this path cannot carry.

Three settings in the generated configs are load-bearing:

- **`alpn: ["http/1.1"]`** (client) — Xray otherwise offers `h2`, and a
  negotiated `h2` breaks the HTTP/1.1 WebSocket upgrade.
- **`heartbeatPeriod: 30`** — Cloudflare drops idle WebSockets at 100s with a
  TCP RST and no close handshake. Without a ping, idle SSH/RDP sessions die silently.
- **`sockopt.trustedXForwardedFor: ["CF-Connecting-IP"]`** (server) — takes
  **header names**, not IPs. Without it Xray logs a warning per connection and
  attributes every client to `127.0.0.1`.

Do not use the resulting source IP for access control: Cloudflare *appends* to a
client-supplied `X-Forwarded-For` and Xray reads the leftmost value, so it is
forgeable. It is fine for logging.

## Note on use

Cloudflare's own quick-tunnel disclaimer states these account-less tunnels have
no uptime guarantee and that Cloudflare reserves the right to investigate use
for violations of its Online Services Terms. Named mode ties the traffic to your
account and a domain you own. Worth being deliberate about either way.
