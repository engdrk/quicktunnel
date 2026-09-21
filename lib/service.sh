#!/usr/bin/env bash
# Service integration: systemd on Linux, launchd on macOS.
# The unit runs lib/run.sh, which supervises xray + cloudflared together.

QT_SYSTEMD_UNIT="/etc/systemd/system/${QT_SERVICE_NAME}.service"
QT_PLIST="/Library/LaunchDaemons/${QT_PLIST_LABEL}.plist"

qt_service_install() {
  case "$(qt_service_kind)" in
    systemd)
      cat > "$QT_SYSTEMD_UNIT" <<UNIT
[Unit]
Description=quicktunnel — Xray (VLESS/WS) behind a Cloudflare Tunnel
Documentation=https://developers.cloudflare.com/cloudflare-one/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=QT_PREFIX=$QT_PREFIX
ExecStart=$QT_LIB/run.sh
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload
      systemctl enable "$QT_SERVICE_NAME" >/dev/null 2>&1
      ok "systemd unit installed: $QT_SYSTEMD_UNIT"
      ;;
    launchd)
      mkdir -p "$QT_LOG"
      cat > "$QT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$QT_PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$QT_LIB/run.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>QT_PREFIX</key><string>$QT_PREFIX</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$QT_LOG/daemon.log</string>
  <key>StandardErrorPath</key><string>$QT_LOG/daemon.log</string>
</dict>
</plist>
PLIST
      chmod 644 "$QT_PLIST"
      ok "launchd daemon installed: $QT_PLIST"
      ;;
    *)
      warn "no supported service manager found — run '$QT_LIB/run.sh' manually"
      return 1
      ;;
  esac
}

qt_service_start() {
  case "$(qt_service_kind)" in
    systemd) systemctl start "$QT_SERVICE_NAME" ;;
    launchd)
      launchctl bootstrap system "$QT_PLIST" 2>/dev/null \
        || launchctl load -w "$QT_PLIST" 2>/dev/null \
        || die "could not start launchd job"
      ;;
    *) return 1 ;;
  esac
}

qt_service_stop() {
  case "$(qt_service_kind)" in
    systemd) systemctl stop "$QT_SERVICE_NAME" 2>/dev/null || true ;;
    launchd)
      launchctl bootout "system/$QT_PLIST_LABEL" 2>/dev/null \
        || launchctl unload -w "$QT_PLIST" 2>/dev/null || true
      ;;
  esac
}

qt_service_restart() { qt_service_stop; qt_service_start; }

qt_service_reload() {
  case "$(qt_service_kind)" in
    systemd)
      if qt_service_running; then systemctl reload "$QT_SERVICE_NAME"; return; fi ;;
    launchd)
      if qt_service_running; then launchctl kill USR1 "system/$QT_PLIST_LABEL"; return; fi ;;
  esac
  pkill -USR1 -f "$QT_LIB/run.sh"
}

qt_service_running() {
  case "$(qt_service_kind)" in
    systemd) systemctl is-active --quiet "$QT_SERVICE_NAME" ;;
    launchd) launchctl print "system/$QT_PLIST_LABEL" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

qt_service_uninstall() {
  qt_service_stop
  case "$(qt_service_kind)" in
    systemd)
      systemctl disable "$QT_SERVICE_NAME" >/dev/null 2>&1 || true
      rm -f "$QT_SYSTEMD_UNIT"
      systemctl daemon-reload
      ;;
    launchd) rm -f "$QT_PLIST" ;;
  esac
}
