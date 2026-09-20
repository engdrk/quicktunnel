[English](README.md) · [فارسی](README.fa.md) · **简体中文**

# quicktunnel

在 **Cloudflare Tunnel** 之后运行一个 **VLESS over WebSocket** 的 Xray 服务端，
让没有公网 IP、也没有开放任何入站端口的机器，可以通过 `443` 端口以
`*.trycloudflare.com` 地址（或你自己的域名）对外提供服务。

安装到 `/usr/local/quicktunnel`，注册为系统服务，并打印 `vless://` 链接和一个
可直接扫描的终端二维码。

```
client ──TLS/WS:443──▶ Cloudflare edge ──▶ cloudflared ──▶ xray (127.0.0.1) ──▶ internet
```

## 安装

一条命令，无需克隆仓库：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hossinasaadi/quicktunnel/main/install.sh)
```

默认是交互式的：会依次询问隧道模式、端口、UUID、WebSocket 路径、备注名和心跳间隔。
每一项都会把当前值作为默认值显示，所以一路回车是安全的。

需要非交互安装时，直接在后面追加参数：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hossinasaadi/quicktunnel/main/install.sh) --yes
bash <(curl -Ls https://raw.githubusercontent.com/hossinasaadi/quicktunnel/main/install.sh) \
  --mode named --hostname proxy.example.com --tunnel-name xray --yes
```

| 参数 | 说明 |
|---|---|
| `--yes` | 不提问，全部使用默认值 |
| `--mode quick\|named` | 隧道模式 |
| `--hostname H` | 公开主机名（`named` 模式） |
| `--tunnel-name N` | cloudflared 隧道名称（`named` 模式） |
| `--port N` | cloudflared 回源的本地端口，仅监听回环（默认 `8080`） |
| `--socks-port N` | 写入客户端配置的 SOCKS 端口（默认 `10808`） |
| `--uuid U` / `--ws-path P` | 指定值，而不是自动生成 |
| `--remark R` | 在客户端 App 中显示的配置名称（默认 `quicktunnel`） |
| `--heartbeat N` | WebSocket ping 间隔，单位秒（默认 `30`） |
| `--prefix DIR` | 安装到其他目录（默认 `/usr/local/quicktunnel`） |
| `--no-service` | 只安装文件，不创建服务 |

安装程序会用 Xray 官方发布的 `SHA2-256` 校验下载的文件，校验不通过就中止安装。

## 两种模式

**quick** — 免费，无需 Cloudflare 账号。主机名随机分配，且**每次重启都会变**，
因此客户端每次都得重新导入。Cloudflare 对这类隧道不提供可用性保证。

**named** — 使用你 Cloudflare 账号下已有域名的固定主机名。只需一次性配置：

```bash
cloudflared tunnel login
cloudflared tunnel create xray
cloudflared tunnel route dns xray proxy.example.com
```

然后用 `--mode named --hostname proxy.example.com --tunnel-name xray` 安装。
这种模式下，链接和二维码在重启后依然有效。

## 日常管理

```bash
quicktunnel-cli status         # 服务状态、模式、当前主机名
quicktunnel-cli qr             # 当前链接的二维码
quicktunnel-cli link           # vless:// 链接
quicktunnel-cli link --full    # 同上，但显式写出 sni 和 host
quicktunnel-cli client         # 客户端配置 JSON
quicktunnel-cli log -f tunnel  # daemon | xray | tunnel | access | error
quicktunnel-cli restart        # quick 模式下会得到一个新主机名
quicktunnel-cli reconfigure    # 重新运行配置向导
quicktunnel-cli update         # 更新 xray 和 cloudflared
quicktunnel-cli uninstall
```

大多数命令需要 `sudo`：配置文件保存着客户端凭据，权限是 `600`。

## 为什么只用 WebSocket

Cloudflare Tunnel 本质上是一个 HTTP 代理，这就排除了 Xray 的大部分传输方式。
以下是在真实隧道上实测的结果：

| 传输方式 | 结果 | 原因 |
|---|---|---|
| `ws` | **可用** | 101 升级成裸双向通道，边缘节点原样转发 |

生成的配置里有三项设置是关键：

- **`alpn: ["http/1.1"]`**（客户端）—— 否则 Xray 还会提供 `h2`，一旦协商成 `h2`，
  基于 HTTP/1.1 的 WebSocket 升级就会失败。
- **`heartbeatPeriod: 30`** —— Cloudflare 会在 100 秒空闲后用 TCP RST 断开 WebSocket，
  且不做关闭握手。没有 ping，空闲的 SSH / RDP 会话会悄无声息地断掉。
- **`sockopt.trustedXForwardedFor: ["CF-Connecting-IP"]`**（服务端）—— 这里填的是
  **HTTP 头名称**，不是 IP。不配置的话，Xray 每条连接都会打一条警告，
  并把所有客户端都记成 `127.0.0.1`。

不要用由此得到的来源 IP 做访问控制：Cloudflare 是把客户端自带的 `X-Forwarded-For`
*追加*到链上，而 Xray 读取最左边那个值，所以它是可以伪造的。用来记日志没问题。

## 使用须知

Cloudflare 自己的提示中写明：这类免账号隧道不提供可用性保证，
且 Cloudflare 保留就其服务条款调查相关使用行为的权利。
`named` 模式则会把流量与你的账号和自有域名绑定。两种方式都值得先想清楚再用。
