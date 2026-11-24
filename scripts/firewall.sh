#!/usr/bin/env bash
# firewall.sh - pf rules so only the edge can reach the backends (Mac 3 and Mac 4).   Guide: Extension C
. "$(dirname "$0")/lib.sh"
load_ips

ANCHOR=com.apple/jio-isolation
RULES=/etc/pf.anchors/jio-isolation
BACKUP=~/pf-backup

usage() { cat <<EOF
Usage: ./firewall.sh <command>          (run on Mac 3 AND Mac 4)

  on                 back up pf state, write the rules (allowed edge = MAC2), load them,
                     enable pf and keep the token for 'off'                   [C2-C4]
  off                remove the rules and give the pf token back (rollback)   [C6]
  allow <mac3|IP>    let another machine in, e.g. the standby edge            [E2]
  deny  <mac3|IP>    remove it again                                          [E7]
  status             pf status, the loaded rules and the allowed table
  test               from ANY Mac: try both backends directly and say allowed/blocked [C1, C5]
  apply              rewrite and reload the rules after an IP change
  render             print the rules without loading them
EOF
}

extras() { state_get FW_EXTRA; }   # extra allowed machines, stored as mac3 / IP

render() {
  local list="$MAC2_IP" e
  for e in $(extras); do list="$list, $(mac_ip "$e")"; done
  cat <<EOF
table <edges> persist { $list }
pass in quick on lo0 all
pass in quick proto tcp from <edges> to any port { $PORT_A, $PORT_B }
block drop in quick proto tcp from any to any port { $PORT_A, $PORT_B }
EOF
}

need_backend_mac() {
  case "$(my_role)" in mac3|mac4) return 0 ;; esac
  expect_role mac3 "The backend firewall (Mac 3 or Mac 4)"
}

load_rules() {
  render | install_file "$RULES" "$BACKUP/jio-isolation.orig"
  if sudo pfctl -vnf "$RULES" 2>&1 | grep -qi 'syntax error'; then
    sudo pfctl -vnf "$RULES" 2>&1 | grep -i 'syntax' >&2; die "pf rejected $RULES"
  fi
  ok "pf syntax check passed"
  if ! sudo pfctl -sr 2>/dev/null | grep -q 'com.apple'; then
    sudo pfctl -f /etc/pf.conf 2>&1 | grep -v -e ALTQ -e 'flushing' -e '^$' || true
  fi
  sudo pfctl -a "$ANCHOR" -f "$RULES" 2>&1 | grep -v -e ALTQ -e 'flushing' -e '^$' || true
  ok "rules loaded into anchor $ANCHOR"
}

show_status() {
  sudo pfctl -s info 2>/dev/null | head -1 | sed 's/^/  /'
  echo "  rules:"; sudo pfctl -a "$ANCHOR" -sr 2>/dev/null | sed 's/^/    /'
  echo "  allowed (<edges>):"; sudo pfctl -a "$ANCHOR" -t edges -T show 2>/dev/null | sed 's/^/    /'
  local t; t=$(state_get FW_TOKEN); [ -z "$t" ] || echo "  token: $t"
}

probe() {   # probe ip port -> prints result
  local code
  code=$("$CURL" -s -o /dev/null -w '%{http_code}' --connect-timeout 4 "http://$1:$2/api/status" 2>/dev/null || true)
  case $code in
    200) printf '  %s:%-5s %s200 reachable%s\n' "$(ip_name "$1")" "$2" "$G" "$N" ;;
    000|"") printf '  %s:%-5s %sblocked / timed out%s\n' "$(ip_name "$1")" "$2" "$Y" "$N" ;;
    *) printf '  %s:%-5s HTTP %s\n' "$(ip_name "$1")" "$2" "$code" ;;
  esac
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
  on)
    need_backend_mac; sudo_keepalive
    say "pf isolation on $(upper "$(my_role)"): only $(render | head -1 | sed 's/.*{ \(.*\) }/\1/') may reach :$PORT_A/:$PORT_B"
    mkdir -p "$BACKUP"
    if [ ! -f "$BACKUP/pf.conf.orig" ]; then
      cp -p /etc/pf.conf "$BACKUP/pf.conf.orig"
      sudo pfctl -s info 2>/dev/null | head -1 >"$BACKUP/status-before.txt" || true
      sudo pfctl -sr 2>/dev/null >"$BACKUP/rules-before.txt" || true
      ok "backed up pf state to $BACKUP ($(cat "$BACKUP/status-before.txt"))"
    fi
    load_rules
    if [ -z "$(state_get FW_TOKEN)" ]; then
      out=$(sudo pfctl -E 2>&1 || true)
      token=$(printf '%s\n' "$out" | awk -F': *' '/Token/{print $2}' | tr -d ' ')
      [ -n "$token" ] || die "pfctl -E gave no token: $out"
      state_set FW_TOKEN "$token"; echo "$token" >"$BACKUP/token"
      ok "pf enabled, token $token (saved; './firewall.sh off' uses it)"
    else
      ok "pf already enabled by this script (token $(state_get FW_TOKEN))"
    fi
    state_set FW_ON 1
    show_status
    echo "  Prove it from Mac 1 and Mac 2:  ./firewall.sh test"
    ;;
  apply)
    [ -n "$(state_get FW_ON)" ] || { ok "firewall not on; nothing to update"; exit 0; }
    load_rules; show_status ;;
  off)
    need_backend_mac; sudo_keepalive
    sudo pfctl -a "$ANCHOR" -F all 2>&1 | grep -v -e ALTQ -e '^$' || true
    ok "rules and table removed"
    token=$(state_get FW_TOKEN)
    if [ -n "$token" ]; then
      sudo pfctl -X "$token" 2>&1 | grep -v ALTQ || true; ok "released pf token $token"
    elif grep -q Disabled "$BACKUP/status-before.txt" 2>/dev/null; then
      sudo pfctl -d 2>&1 | grep -v ALTQ || true; ok "pf disabled (it was disabled before)"
    fi
    state_set FW_TOKEN ""; state_set FW_ON ""; state_set FW_EXTRA ""
    echo "  now: $(sudo pfctl -s info 2>/dev/null | head -1)   before: $(cat "$BACKUP/status-before.txt" 2>/dev/null)"
    ;;
  allow|deny)
    [ $# -eq 1 ] || die "usage: ./firewall.sh $cmd mac3|IP"
    need_backend_mac
    who=$(lower "$1"); ip=$(mac_ip "$who")
    new=""
    for e in $(extras); do [ "$e" = "$who" ] || new="$new $e"; done
    if [ "$cmd" = allow ]; then new="$new $who"; op=add; else op=delete; fi
    state_set FW_EXTRA "$(echo $new)"
    if [ -n "$(state_get FW_ON)" ]; then
      sudo pfctl -a "$ANCHOR" -t edges -T "$op" "$ip" 2>&1 | grep -v ALTQ || true
      render | install_file "$RULES" "$BACKUP/jio-isolation.orig" >/dev/null
    else
      warn "firewall isn't on; saved for the next './firewall.sh on'"
    fi
    echo "  allowed now:"; sudo pfctl -a "$ANCHOR" -t edges -T show 2>/dev/null | sed 's/^/    /'
    ;;
  status) show_status ;;
  test)
    say "From $(upper "$(my_role)") ($(my_ip)) straight to the backends, skipping the edge:"
    probe "$MAC3_IP" "$PORT_A"; probe "$MAC4_IP" "$PORT_B"
    echo "  Expected with the firewall on: reachable from Mac 2 only, timed out everywhere else."
    ;;
  render) render ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
