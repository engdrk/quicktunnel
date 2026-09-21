**English** · [فارسی](README.fa.md) · [简体中文](README.zh.md)

# quicktunnel - [try.cloudflare.com](https://try.cloudflare.com)

Runs an Xray **VLESS over WebSocket** server behind a **Cloudflare Tunnel**, so a
machine with no public IP and no open inbound ports is reachable over `443` at a
`*.trycloudflare.com` address (or your own hostname).

Installs to `/usr/local/quicktunnel`, registers a service, and prints a
`vless://` URI plus a scannable QR code.

```
client ──TLS/WS:443──▶ Cloudflare edge ──▶ cloudflared ──▶ xray (127.0.0.1) ──▶ internet
```

## Install

One command, no clone needed:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/engdrk/quicktunnel/main/install.sh)
```

Interactive by default: it asks for the mode, ports, UUID, WebSocket path,
remark and heartbeat, showing current values as defaults so Enter-through is
safe.

Non-interactive — arguments go straight on the end:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/engdrk/quicktunnel/main/install.sh) --yes
bash <(curl -Ls https://raw.githubusercontent.com/engdrk/quicktunnel/main/install.sh) \
  --mode named --hostname proxy.example.com --tunnel-name xray --yes
```

`install.sh` bootstraps itself: run without the repo beside it, it fetches the
tree into a temp dir, hands off, and cleans up. From a clone `sudo ./install.sh`
still works unchanged. `QT_REF=v1.0.0` pins a tag or commit instead of `main`.

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

**named via the API** — no `cloudflared login`, no cert file. With an API token
scoped to *Zone:Read*, *DNS:Edit* (the zone) and *Cloudflare Tunnel:Edit*
(the account):

```bash
CF_API_TOKEN=… quicktunnel-cli cloudflare proxy.example.com
```

It creates (or reuses) a remotely-managed tunnel, points its ingress at the
local xray port, upserts a proxied CNAME to `<tunnel-id>.cfargotunnel.com`,
stores the tunnel token and switches the service over. UUIDs, path and exits are
unchanged, so only the hostname in client links changes — once. Omit
`CF_API_TOKEN` to be prompted for it; the API token itself is never saved.

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

## Telegram notifications

Quick mode re-issues the hostname on every restart or reboot. To receive the
new links automatically:

```bash
quicktunnel-cli notify telegram <bot-token> <chat-id>   # verifies, saves, sends current links
quicktunnel-cli notify send                             # resend now
quicktunnel-cli notify off
```

A message with every link is sent when the tunnel comes up with a new hostname
and when exits change. Sending runs in the background and never affects the
tunnel.

## Exits: one entry point, many egress IPs

The tunnel is the entry point; each **exit** is an extra Xray outbound (another
VLESS/Reality server, SOCKS, HTTP, WireGuard, `freedom` + `sendThrough`, …).
Every exit gets its own UUID on the same inbound, and routing sends each user
to its outbound. The original UUID keeps leaving directly, so existing clients
are unaffected.

```
             UUID-default ──▶ direct       (this server's IP)
client ─CF─▶ UUID-de      ──▶ exit-de      (Germany server)
             UUID-fr      ──▶ exit-fr      (France server)
```

```bash
quicktunnel-cli exits add de 'vless://…@1.2.3.4:443?security=reality&…'   # share link
quicktunnel-cli exits add fr outbound.json                                 # Xray outbound JSON
quicktunnel-cli exits add wg - --port 10830 < wireguard-outbound.json     # stdin, fixed client port
quicktunnel-cli exits                # list
quicktunnel-cli exits rm fr
quicktunnel-cli links                # one vless:// per exit + its client SOCKS port
quicktunnel-cli qr de                # QR for one exit
quicktunnel-cli test                 # dial every exit through the tunnel, print exit IP/country
```

- `vless://` links are converted to outbounds (Reality/TLS; tcp, ws, grpc,
  xhttp, httpupgrade). A JSON file may be a single outbound, an array, or a full
  config; the first non-`freedom`/`blackhole`/`dns` outbound is used.
- Every change is validated with `xray run -test` before it is saved; a rejected
  config changes nothing.
- Applying exits restarts **only xray** (`quicktunnel-cli reload`, or
  `systemctl reload quicktunnel`). cloudflared stays up, so a quick-mode
  hostname survives.
- `quicktunnel-cli client` emits a client config with one SOCKS port per exit:
  default on `--socks-port` (10808), exits on the following ports unless given
  `--port`.
- Exits are stored in `etc/exits.json` and need `jq`, which the installer adds.

## Why WebSocket only

A Cloudflare Tunnel is an HTTP proxy, which rules out most Xray transports.
Measured against a live quick tunnel:

| transport | result | why |
|---|---|---|
| `ws` | **works** | 101 upgrade to a raw bidirectional pipe, passed through untouched |

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
