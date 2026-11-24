#!/usr/bin/env bash
# backend.sh - run Backend A (Mac 3 :3001) or Backend B (Mac 4 :3002) in the foreground.
#   ./backend.sh A        # on Mac 3
#   ./backend.sh B        # on Mac 4
# Stop it with Ctrl-C (that's the "kill Backend A" step in D4).
# server.py is looked for in $SERVER_PY, this folder, its parent, then the current folder.
. "$(dirname "$0")/lib.sh"
load_ips

which=$(upper "${1:-}")
case $which in
  A) port=$PORT_A; home=mac3 ;;
  B) port=$PORT_B; home=mac4 ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

expect_role "$home" "Backend $which"

py=""
for p in "${SERVER_PY:-}" "$JIO_DIR/server.py" "$JIO_DIR/../server.py" "$PWD/server.py"; do
  if [ -n "$p" ] && [ -f "$p" ]; then py=$p; break; fi
done
[ -n "$py" ] || die "server.py not found. Put it next to these scripts or run: SERVER_PY=/path/to/server.py $0 $which"

if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  die "Port $port is already in use:
$(lsof -nP -iTCP:"$port" -sTCP:LISTEN)
       Stop that process first (or it's Backend $which already running)."
fi

# 2 s after start, check it listens on all interfaces (127.0.0.1 only -> nginx gets 502)
(
  sleep 2
  l=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | head -1)
  case $l in
    "")            warn "Backend $which isn't listening on :$port yet." ;;
    127.0.0.1:*)   warn "Backend $which listens on $l only. Mac 2 can't reach it: server.py must bind 0.0.0.0." ;;
    *)             ok "Backend $which listening on $l (reachable as $(mac_ip "$home"):$port)" ;;
  esac
) &

say "Backend $which on $(upper "$home"):$port  ($py)  started $(now). Ctrl-C to stop."
echo "  If macOS asks about incoming connections, click Allow."
cd "$(dirname "$py")"
exec python3 "$(basename "$py")" "$which" "$port"
