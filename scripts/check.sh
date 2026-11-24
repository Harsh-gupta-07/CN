#!/usr/bin/env bash
# check.sh - the F1 diagnostic ladder, run for you.   Guide: F1, 0.2 step 2, 0.3
. "$(dirname "$0")/lib.sh"
load_ips

usage() { cat <<EOF
Usage: ./check.sh [client] [--all] [--edge mac2|mac3]
         walk the ladder L0 client config -> L1 DNS -> L2 IP -> L3 TCP -> L4 TLS -> L5 HTTP
         -> L6 edge->backend (L6 only on the edge Mac). Stops at the first failing layer
         unless --all. --edge mac3 while the cutover (Extension E) is active.
       ./check.sh server   server-side checks for whatever this Mac runs
       ./check.sh ping     ping all four Macs (0.2 step 2)
EOF
}

MODE=client; ALL=0; EDGE=mac2
while [ $# -gt 0 ]; do
  case $1 in
    client|server|ping) MODE=$1 ;;
    --all) ALL=1 ;;
    --edge) EDGE=$(lower "${2:-}"); shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  shift
done
EDGE_IP=$(mac_ip "$EDGE")
FAILS=0

level() { printf '\n%sL%s  %s%s\n' "$B" "$1" "$2" "$N"; }
bad() {
  fail "$1"
  [ -z "${2:-}" ] || printf '     suspect: %s\n' "$2" >&2
  FAILS=$((FAILS + 1))
  if [ "$ALL" = 0 ]; then
    printf '\n%sStopped at the first failing layer.%s Fix it, then run ./check.sh again (or --all to see everything).\n' "$R$B" "$N" >&2
    exit 1
  fi
}

ping_all() {
  say "Ping from $(upper "$(my_role)") ($(my_ip))"
  local n ip
  for n in 1 2 3 4; do
    ip=$(mac_ip "mac$n")
    if ping -c1 -t2 "$ip" >/dev/null 2>&1; then ok "MAC$n $ip"; else fail "MAC$n $ip FAIL"; fi
  done
}

client_ladder() {
  say "Diagnostic ladder from $(upper "$(my_role)") ($(my_ip)), expecting the edge on $(upper "$EDGE") ($EDGE_IP)"

  level 0 "Client config"
  local ns; ns=$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | awk '!s[$0]++' | head -2 | tr '\n' ' ' || true)
  ns=$(echo $ns)
  if [ "$ns" = "$MAC1_IP $MAC3_IP" ]; then ok "DNS servers: MAC1 then MAC3"
  elif [ "${ns%% *}" = "$MAC1_IP" ]; then warn "DNS servers: '$ns' (only MAC1 first; backup not listed - ./client.sh dns both)"
  else bad "DNS servers are '$ns', expected '$MAC1_IP $MAC3_IP'" "client DNS changed -> ./client.sh dns"; fi
  if grep -v '^[[:space:]]*#' /etc/hosts | grep -qi 'jio\.test'; then
    bad "/etc/hosts overrides jio.test: $(grep -i 'jio\.test' /etc/hosts | head -1)" "remove that line from /etc/hosts, then ./client.sh flush"
  else ok "no jio.test line in /etc/hosts"; fi
  if [ -n "$(my_role)" ]; then ok "this Mac's IP $(my_ip) matches ips.conf"
  else warn "this Mac's IP $(my_ip) isn't in ips.conf (DHCP change? ./set-ips.sh)"; fi

  level 1 "DNS"
  local a1 a3 sys
  a1=$(dig_a "$MAC1_IP" app.jio.test); a3=$(dig_a "$MAC3_IP" app.jio.test)
  sys=$(dscacheutil -q host -a name app.jio.test 2>/dev/null | awk '/ip_address/{print $2; exit}' || true)
  printf '  dig @MAC1 -> %-15s dig @MAC3 -> %-15s OS resolver -> %s\n' "${a1:-no answer}" "${a3:-no answer}" "${sys:-no answer}"
  if [ -z "$a1" ] && [ -z "$a3" ]; then bad "neither DNS server answers" "dnsmasq stopped on both -> ./dns.sh start on Mac 1 and Mac 3"; fi
  if [ -n "$a1" ] && [ -n "$a3" ] && [ "$a1" != "$a3" ]; then bad "the two DNS servers disagree" "records differ -> ./dns.sh show on Mac 1 and Mac 3"; fi
  [ -n "$a1" ] || warn "primary (MAC1) not answering; the backup covers it"
  [ -n "$a3" ] || warn "backup (MAC3) not answering"
  if [ -z "$sys" ]; then bad "the OS resolver can't resolve app.jio.test" "client DNS settings / cache -> ./client.sh setup"
  elif [ "$sys" != "$EDGE_IP" ]; then bad "OS resolver gives $sys ($(ip_name "$sys")), expected $EDGE_IP" "wrong host-record, stale cache (./client.sh flush), or /etc/hosts"
  else ok "app.jio.test -> $sys ($(ip_name "$sys"))"; fi

  level 2 "IP"
  if ping -c2 -t3 "$EDGE_IP" >/dev/null 2>&1; then ok "ping $EDGE_IP replies"
  else bad "no ping reply from $EDGE_IP" "$(upper "$EDGE") off the network or its IP changed"; fi

  level 3 "TCP :443"
  local nc; nc=$(nc -vz -G 3 app.jio.test 443 2>&1 || true)
  if echo "$nc" | grep -qi succeeded; then ok "TCP 443 open"
  elif echo "$nc" | grep -qi refused; then bad "connection refused on 443" "nothing listening: nginx stopped or 'listen 443' changed -> ./edge.sh start"
  else bad "TCP 443: $(echo "$nc" | tail -1)" "timeout = filtered (firewall) or host gone"; fi

  level 4 "TLS"
  local rc=0 out
  out=$("$CURL" -sS -o /dev/null -m 6 https://app.jio.test/ 2>&1) || rc=$?
  case $rc in
    0|22) ok "TLS handshake OK and certificate trusted" ;;
    60) bad "certificate not trusted: $out" "CA missing from this Mac's keychain (./client.sh setup ca.crt) or cert for the wrong name" ;;
    35) bad "TLS handshake failed: $out" "'ssl' missing on listen, or wrong cert/key" ;;
    *) bad "curl exit $rc: $out" "see the curl error" ;;
  esac
  echo | openssl s_client -connect "$EDGE_IP:443" -servername app.jio.test 2>/dev/null \
    | openssl x509 -noout -subject -issuer -enddate 2>/dev/null | sed 's/^/     /' || true

  level 5 "HTTP through the edge"
  local h st xb xe
  h=$("$CURL" -s -m 6 -o /dev/null -D - https://app.jio.test/api/status 2>/dev/null | tr -d '\r' || true)
  st=$(echo "$h" | awk 'NR==1{print $2}')
  xb=$(echo "$h" | awk -F': *' 'tolower($1)=="x-backend"{print $2}')
  xe=$(echo "$h" | awk -F': *' 'tolower($1)=="x-edge"{print $2}')
  case $st in
    200) if [ -n "$xb" ]; then ok "HTTP 200, x-backend: $xb, x-edge: ${xe:-?}"; else bad "200 but no X-Backend header" "proxy_pass / location"; fi ;;
    502|504) bad "HTTP $st from the edge" "backends: stopped, wrong upstream IP/port, bound to 127.0.0.1, or pf blocking the edge -> run ./check.sh on the edge Mac for L6" ;;
    404) bad "HTTP 404" "proxy_pass / location block" ;;
    *) bad "HTTP '${st:-no response}'" "see L3/L4" ;;
  esac
  local seq="" i
  for i in 1 2 3 4; do
    seq="$seq $("$CURL" -s -m 6 -o /dev/null -D - https://app.jio.test/api/status 2>/dev/null | tr -d '\r' | awk -F': *' 'tolower($1)=="x-backend"{print $2}' || true)"
  done
  echo "     4 requests -> backends:$seq   (A and B should alternate)"

  level 6 "Edge -> backend"
  if [ "$(my_role)" = "$EDGE" ]; then edge_to_backend
  else echo "  (run ./check.sh on $(upper "$EDGE") to test this layer from the edge itself)"; fi

  echo
  if [ "$FAILS" = 0 ]; then printf '%sAll layers OK.%s\n' "$G$B" "$N"; else printf '%s%s layer(s) failed.%s\n' "$R$B" "$FAILS" "$N"; exit 1; fi
}

edge_to_backend() {
  local ip port name code
  for name in A B; do
    if [ $name = A ]; then ip=$MAC3_IP; port=$PORT_A; else ip=$MAC4_IP; port=$PORT_B; fi
    code=$("$CURL" -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://$ip:$port/api/status" || true)
    if [ "$code" = 200 ]; then ok "Backend $name $ip:$port -> 200"
    else bad "Backend $name $ip:$port -> ${code/000/no connection}" "backend stopped, bound to 127.0.0.1, or pf not allowing this edge (./firewall.sh status on that Mac)"; fi
  done
  echo "  last error.log lines:"; tail -n 4 "$BREW/var/log/nginx/error.log" 2>/dev/null | sed 's/^/     /' || true
}

server_checks() {
  local role; role=$(my_role)
  say "Server-side checks on $(upper "${role:-unknown}") ($(my_ip))"
  case $role in
    mac1|mac3)
      echo "  DNS (port 53):"; sudo lsof -nP -i :53 2>/dev/null | awk 'NR>1{print "     "$1, $9}' | sort -u || true
      echo "  records:"; grep '^host-record' "$BREW/etc/dnsmasq.conf" 2>/dev/null | sed 's/^/     /' || true
      echo "  last queries:"; tail -n 4 /tmp/dnsmasq.log 2>/dev/null | sed 's/^/     /' || true ;;
  esac
  case $role in
    mac2|mac3)
      if pgrep -x nginx >/dev/null 2>&1; then
        sudo nginx -t -q 2>/dev/null && ok "nginx running, config OK" || fail "nginx -t fails"
        echo "  listening:"; sudo lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '$1=="nginx"{print "     "$9}' | sort -u || true
      elif [ "$role" = mac2 ]; then fail "nginx is not running (./edge.sh start)"
      fi
      [ "$role" = mac2 ] && edge_to_backend ;;
  esac
  case $role in
    mac3|mac4)
      echo "  backends listening:"; lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '$9 ~ /:300[12]$/{print "     "$1, $9}' || true
      echo "  (must be *:3001 / *:3002, not 127.0.0.1)"
      echo "  pf:"; sudo pfctl -s info 2>/dev/null | head -1 | sed 's/^/     /' || true
      sudo pfctl -a com.apple/jio-isolation -t edges -T show 2>/dev/null | sed 's/^/     allowed: /' || true ;;
  esac
  [ -n "$role" ] || warn "This Mac's IP isn't in ips.conf."
}

case $MODE in
  ping) ping_all ;;
  server) ALL=1; server_checks ;;
  client) client_ladder ;;
esac
