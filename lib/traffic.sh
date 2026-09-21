#!/usr/bin/env bash

qt_traffic_file() { printf '%s' "$QT_ETC/traffic.json"; }

qt_today() { TZ="${QT_TZ:-}" date '+%F'; }

qt_yesterday() {
  TZ="${QT_TZ:-}" date -d 'yesterday' '+%F' 2>/dev/null || TZ="${QT_TZ:-}" date -v-1d '+%F'
}

qt_stats_raw() {
  local reset="${1:-}" raw
  raw="$("$(qt_xray_bin)" api statsquery --server="${QT_API:-127.0.0.1:10085}" -pattern 'user>>>' ${reset:+-reset} 2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1 || raw='{}'
  printf '%s' "$raw"
}

QT_JQ_DELTA='
  [(.stat // [])[] | (.name | split(">>>")) as $p | select($p[0] == "user")
   | {n: $p[1], d: $p[3], v: ((.value // 0) | tonumber)}]
  | group_by(.n)
  | map({key: .[0].n, value: {up: ([.[] | select(.d == "uplink") | .v] | add // 0),
                               down: ([.[] | select(.d == "downlink") | .v] | add // 0)}})
  | from_entries'

qt_traffic_collect() {
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$QT_RUN"
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 15 9 || exit 1; qt_traffic_collect_unlocked ) 9>"$QT_RUN/.traffic.lock"
  else
    qt_traffic_collect_unlocked
  fi
}

qt_traffic_collect_unlocked() {
  local raw now f
  raw="$(qt_stats_raw reset)" || return 1
  now="$(date +%s)"; f="$(qt_traffic_file)"
  [ -s "$f" ] || printf '{}\n' > "$f"
  jq --argjson raw "$raw" --argjson now "$now" --arg day "$(qt_today)" "
    (\$raw | $QT_JQ_DELTA) as \$delta
    | .total //= {} | .days //= {}
    | reduce (\$delta | to_entries[]) as \$e (.;
        .total[\$e.key].up += \$e.value.up | .total[\$e.key].down += \$e.value.down
        | .days[\$day][\$e.key].up += \$e.value.up | .days[\$day][\$e.key].down += \$e.value.down)
    | .rate = {span: (\$now - (.collected // \$now)), delta: \$delta}
    | .collected = \$now
    | .days |= (to_entries | sort_by(.key) | .[-62:] | from_entries)" "$f" > "$f.tmp" \
    && mv -f "$f.tmp" "$f" && chmod 600 "$f"
}

qt_online_counts() {
  local name n
  for name in "$@"; do
    n="$("$(qt_xray_bin)" api statsonline --server="${QT_API:-127.0.0.1:10085}" -email "$name" 2>/dev/null \
         | jq -r '.stat.value // 0' 2>/dev/null)"
    printf '%s\t%s\n' "$name" "${n:-0}"
  done
}

qt_node_labels() {
  if [ -s "$QT_RUN/links.tsv" ]; then
    jq -Rn '[inputs | split("\t") | {key: .[0], value: .[2]}] | from_entries' "$QT_RUN/links.tsv"
  else
    printf '{}'
  fi
}

QT_JQ_HUMAN='
  def h: . as $b
    | if $b < 1024 then "\($b | floor) B"
      elif $b < 1048576 then "\($b / 1024 * 10 | floor / 10) KB"
      elif $b < 1073741824 then "\($b / 1048576 * 10 | floor / 10) MB"
      elif $b < 1099511627776 then "\($b / 1073741824 * 100 | floor / 100) GB"
      else "\($b / 1099511627776 * 100 | floor / 100) TB" end;
  def pair: "↓\(.down // 0 | h)  ↑\(.up // 0 | h)";'

qt_traffic_rows() {
  local f live labels online names
  f="$(qt_traffic_file)"; [ -s "$f" ] || printf '{}\n' > "$f"
  live="$(qt_stats_raw | jq -c "$QT_JQ_DELTA" 2>/dev/null)"; [ -n "$live" ] || live='{}'
  labels="$(qt_node_labels)"
  names="$(jq -rn --argjson l "$labels" --slurpfile t "$f" '($l | keys_unsorted) + (($t[0].total // {}) | keys) | unique[]')"
  online="$(qt_online_counts $names | jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries')"
  jq -r --argjson live "$live" --argjson l "$labels" --argjson on "$online" --arg today "$(qt_today)" "
    $QT_JQ_HUMAN
    def add2(a; b): {up: ((a.up // 0) + (b.up // 0)), down: ((a.down // 0) + (b.down // 0))};
    . as \$t
    | ([\$l | keys_unsorted[]] + ((\$t.total // {}) | keys) | reduce .[] as \$k ([]; if index([\$k]) then . else . + [\$k] end)) as \$nodes
    | (\$t.days // {} | to_entries | sort_by(.key) | .[-30:]) as \$month
    | \$nodes[] as \$n
    | (\$t.rate.span // 0) as \$span
    | (\$t.rate.delta[\$n] // {}) as \$d
    | [ (\$l[\$n] // \$n),
        (\$on[\$n] // 0 | tostring),
        (if \$span > 0 then {up: ((\$d.up // 0) / \$span), down: ((\$d.down // 0) / \$span)} | \"↓\(.down | h)/s  ↑\(.up | h)/s\" else \"-\" end),
        (add2(\$t.days[\$today][\$n] // {}; \$live[\$n] // {}) | pair),
        (reduce \$month[] as \$m ({}; add2(.; \$m.value[\$n] // {})) | add2(.; \$live[\$n] // {}) | pair),
        (add2(\$t.total[\$n] // {}; \$live[\$n] // {}) | pair) ] | @tsv" "$f"
}

qt_traffic_report_message() {
  local day="$1" f labels
  f="$(qt_traffic_file)"; labels="$(qt_node_labels)"
  jq -r --arg day "$day" --argjson l "$labels" "
    $QT_JQ_HUMAN
    def esc: gsub(\"&\"; \"&amp;\") | gsub(\"<\"; \"&lt;\") | gsub(\">\"; \"&gt;\");
    (.days[\$day] // {}) as \$d
    | (\$d | to_entries | sort_by(-((.value.down // 0) + (.value.up // 0)))) as \$rows
    | \"<b>quicktunnel</b> traffic · \(\$day)\n\"
      + (if (\$rows | length) == 0 then \"\nno traffic\"
         else (\$rows | map(\"\n<b>\(\$l[.key] // .key | esc)</b>\n\(.value | pair)\") | join(\"\n\"))
              + \"\n\n<b>day total</b>  \" + ([\$rows[].value] | {up: (map(.up // 0) | add), down: (map(.down // 0) | add)} | pair)
         end)
      + \"\n<b>all time</b>  \" + ([(.total // {})[]] | {up: (map(.up // 0) | add // 0), down: (map(.down // 0) | add // 0)} | pair)" "$f"
}

qt_traffic_daily_report() {
  local day marker="$QT_ETC/.traffic-reported"
  [ -n "${QT_TG_TOKEN:-}" ] && [ -n "${QT_TG_CHAT:-}" ] && [ -s "$(qt_traffic_file)" ] || return 0
  day="$(qt_yesterday)" || return 0
  if [ ! -s "$marker" ]; then printf '%s' "$day" > "$marker"; return 0; fi
  [ "$(cat "$marker")" \< "$day" ] || return 0
  [ -n "${QT_REPORT_PID:-}" ] && kill -0 "$QT_REPORT_PID" 2>/dev/null && return 0
  (
    if qt_tg_send "$(qt_traffic_report_message "$day")"; then
      printf '%s' "$day" > "$marker"
      printf '%s telegram: traffic report for %s sent\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$day"
    else
      printf '%s telegram: traffic report failed, retrying in 60s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi
  ) &
  QT_REPORT_PID=$!
}
