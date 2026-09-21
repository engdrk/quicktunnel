#!/usr/bin/env bash
# Dependency acquisition: xray, cloudflared, qrencode.
# Binaries are installed under $QT_BIN so quicktunnel owns its own toolchain
# and does not depend on whatever happens to be on PATH.

GH_XRAY="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
GH_CFD="https://github.com/cloudflare/cloudflared/releases/latest/download"

qt_have() { command -v "$1" >/dev/null 2>&1; }

qt_need_tools() {
  local missing=()
  for t in curl unzip tar; do qt_have "$t" || missing+=("$t"); done
  [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]}"
}

# Resolve the newest Xray-core tag, or honour an explicit QT_XRAY_VERSION.
qt_xray_latest_tag() {
  if [ -n "${QT_XRAY_VERSION:-}" ]; then printf '%s' "$QT_XRAY_VERSION"; return; fi
  curl -fsSL --max-time 30 "$GH_XRAY" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

qt_sha256() {
  if qt_have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif qt_have shasum;  then shasum -a 256 "$1" | awk '{print $1}'
  else echo ""; fi
}

# Download Xray and verify it against the published .dgst before installing.
qt_fetch_xray() {
  local tag asset url tmp want got
  tag="$(qt_xray_latest_tag)"
  [ -n "$tag" ] || die "could not determine latest Xray version"

  case "$(qt_os)" in
    linux) asset="Xray-linux-$(qt_arch).zip" ;;
    macos) asset="Xray-macos-$(qt_arch).zip" ;;
  esac
  url="https://github.com/XTLS/Xray-core/releases/download/$tag/$asset"

  info "downloading Xray $tag ($asset)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  curl -fsSL --max-time 300 -o "$tmp/x.zip" "$url" || die "download failed: $url"

  # The .dgst sidecar carries several digests; we want the SHA2-256 line.
  if curl -fsSL --max-time 60 -o "$tmp/x.dgst" "$url.dgst" 2>/dev/null; then
    want="$(sed -n 's/^SHA2-256= *//p' "$tmp/x.dgst" | head -1 | tr -d '[:space:]')"
    got="$(qt_sha256 "$tmp/x.zip")"
    if [ -n "$want" ] && [ -n "$got" ]; then
      [ "$want" = "$got" ] || die "checksum mismatch for $asset (expected $want, got $got)"
      ok "checksum verified"
    else
      warn "could not verify checksum (no digest tool or digest line)"
    fi
  else
    warn "no .dgst published for $asset — skipping checksum verification"
  fi

  mkdir -p "$QT_BIN"
  unzip -oq "$tmp/x.zip" -d "$tmp/x" || die "unzip failed"
  install -m 0755 "$tmp/x/xray" "$QT_BIN/xray"
  for d in geoip.dat geosite.dat; do
    [ -f "$tmp/x/$d" ] && install -m 0644 "$tmp/x/$d" "$QT_BIN/$d"
  done
  printf '%s\n' "$tag" > "$QT_BIN/.xray-version"
  ok "xray $tag -> $QT_BIN/xray"
}

qt_fetch_cloudflared() {
  local asset tmp
  mkdir -p "$QT_BIN"
  case "$(qt_os)-$(uname -m)" in
    linux-x86_64|linux-amd64)  asset="cloudflared-linux-amd64" ;;
    linux-aarch64|linux-arm64) asset="cloudflared-linux-arm64" ;;
    linux-armv7l)              asset="cloudflared-linux-arm" ;;
    linux-i386|linux-i686)     asset="cloudflared-linux-386" ;;
    macos-arm64)               asset="cloudflared-darwin-arm64.tgz" ;;
    macos-x86_64)              asset="cloudflared-darwin-amd64.tgz" ;;
    *) die "no cloudflared build for $(uname -s)/$(uname -m)" ;;
  esac

  info "downloading cloudflared ($asset)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  curl -fsSL --max-time 300 -o "$tmp/$asset" "$GH_CFD/$asset" \
    || die "download failed: $GH_CFD/$asset"

  case "$asset" in
    *.tgz)
      tar -xzf "$tmp/$asset" -C "$tmp" || die "extract failed"
      install -m 0755 "$tmp/cloudflared" "$QT_BIN/cloudflared" ;;
    *)
      install -m 0755 "$tmp/$asset" "$QT_BIN/cloudflared" ;;
  esac
  ok "cloudflared -> $QT_BIN/cloudflared"
}

# Prefer our own copies, fall back to whatever is on PATH.
qt_xray_bin()        { [ -x "$QT_BIN/xray" ] && printf '%s' "$QT_BIN/xray" || command -v xray; }
qt_cloudflared_bin() { [ -x "$QT_BIN/cloudflared" ] && printf '%s' "$QT_BIN/cloudflared" || command -v cloudflared; }

qt_ensure_jq() {
  qt_have jq && return 0
  info "installing jq (for exit routing)"
  if   qt_have brew && [ "$(id -u)" -ne 0 ]; then brew install jq >/dev/null 2>&1
  elif qt_have apt-get; then apt-get install -y -qq jq >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq >/dev/null 2>&1; }
  elif qt_have dnf;     then dnf install -y -q jq >/dev/null 2>&1
  elif qt_have yum;     then yum install -y -q jq >/dev/null 2>&1
  elif qt_have pacman;  then pacman -Sy --noconfirm --quiet jq >/dev/null 2>&1
  elif qt_have apk;     then apk add --quiet jq >/dev/null 2>&1
  fi
  qt_have jq && { ok "jq installed"; return 0; }
  warn "could not install jq — exits are unavailable until it is installed"
  return 1
}

# qrencode has no portable static build, so use the platform package manager.
qt_ensure_qrencode() {
  qt_have qrencode && { ok "qrencode already present"; return 0; }
  info "installing qrencode (for terminal QR codes)"
  if   qt_have brew && [ "$(id -u)" -ne 0 ]; then brew install qrencode >/dev/null 2>&1
  elif qt_have apt-get; then apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq qrencode >/dev/null 2>&1
  elif qt_have dnf;     then dnf install -y -q qrencode >/dev/null 2>&1
  elif qt_have yum;     then yum install -y -q qrencode >/dev/null 2>&1
  elif qt_have pacman;  then pacman -Sy --noconfirm --quiet qrencode >/dev/null 2>&1
  elif qt_have apk;     then apk add --quiet libqrencode-tools >/dev/null 2>&1
  fi
  if qt_have qrencode; then ok "qrencode installed"; return 0; fi
  warn "could not install qrencode — 'quicktunnel-cli qr' will print the URI instead"
  return 1
}
