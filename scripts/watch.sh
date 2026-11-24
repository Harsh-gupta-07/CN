#!/usr/bin/env bash
# watch.sh - the two watcher loops from the guide, saved to a file as they run. Ctrl-C to stop.
#   ./watch.sh dns  [name] [file]   what the OS resolver returns every 2 s   [B2]  (default ttl.jio.test)
#   ./watch.sh http [file]          one HTTPS request every 2 s              [D3, E4]
# Files default to evidence/phase2/... next to these scripts' parent (the repo root).
. "$(dirname "$0")/lib.sh"
load_ips

EVID="${JIO_EVIDENCE:-$JIO_DIR/../evidence/phase2}"

case ${1:-} in
  dns)
    name=${2:-ttl.jio.test}; out=${3:-$EVID/B_ttl/watch.txt}
    mkdir -p "$(dirname "$out")"
    flush_dns
    say "Watching $name via the OS resolver -> $out   (Ctrl-C to stop)"
    while true; do
      line=$(ping -c1 -t1 "$name" 2>&1 | head -1 || true)
      ip=$(echo "$line" | sed -n 's/.*(\([0-9.]*\)).*/\1/p')
      printf '%s  %s%s\n' "$(now)" "$line" "${ip:+   [$(ip_name "$ip")]}"
      sleep 2
    done | tee "$out"
    ;;
  http)
    out=${2:-$EVID/D_ha_failover/watch.txt}
    mkdir -p "$(dirname "$out")"
    say "One request to https://app.jio.test/api/status every 2 s -> $out   (Ctrl-C to stop)"
    while true; do
      printf '%s  ' "$(now)"
      "$CURL" -s -m 5 -o /dev/null -D - https://app.jio.test/api/status 2>/dev/null \
        | grep -iE '^HTTP|x-edge|x-backend' | tr -d '\r' | tr '\n' ' ' || printf 'no response'
      echo
      sleep 2
    done | tee "$out"
    ;;
  *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
