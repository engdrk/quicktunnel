#!/usr/bin/env bash
# Terminal QR rendering for the share URI.

# A vless:// URI runs ~200-280 chars. Error-correction level L keeps the symbol
# small enough (~version 11, 61x61 modules) to fit an 80-column terminal; a
# higher level pushes it past the width and makes it unscannable on screen.
qt_qr() {
  local data="$1" cols
  if ! command -v qrencode >/dev/null 2>&1; then
    warn "qrencode not installed — cannot render a QR code"
    log ""
    log "$data"
    return 1
  fi

  cols="$(tput cols 2>/dev/null || echo 80)"
  # UTF8 packs two module rows per text row, so it is half the height of ANSIUTF8
  # and far more likely to fit. Fall back to ANSI blocks if the terminal cannot
  # do UTF-8 half-blocks.
  if [ "${QT_QR_STYLE:-utf8}" = "ansi" ]; then
    qrencode -t ANSIUTF8 -l L -m 1 -o - "$data"
  else
    qrencode -t UTF8 -l L -m 1 -o - "$data"
  fi

  if [ "$cols" -lt 70 ]; then
    warn "terminal is ${cols} columns; a QR code needs ~70 to scan reliably"
  fi
}

qt_show_link_and_qr() {
  local host link
  host="$(cat "$QT_RUN/hostname" 2>/dev/null || true)"
  [ -n "$host" ] || die "no active tunnel hostname — is the service running?"
  link="$(head -1 "$QT_RUN/link.txt")"

  log ""
  printf '  %shost%s  %s\n' "$C_DIM" "$C_RESET" "$host"
  log ""
  qt_qr "$link" || true
  log ""
  printf '%s%s%s\n' "$C_BOLD" "$link" "$C_RESET"
  log ""
}
