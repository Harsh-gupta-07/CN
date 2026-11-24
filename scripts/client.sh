#!/usr/bin/env bash
# client.sh - point a client Mac at the team DNS servers and trust the CA.   Guide: 0.2 step 6, A4
. "$(dirname "$0")/lib.sh"
load_ips

usage() { cat <<EOF
Usage: ./client.sh <command>

  setup [ca.crt]     trust the CA (if not trusted yet) and set DNS to MAC1 + MAC3, flush   [0.2, A4]
  dns [both|primary] set DNS servers: both = MAC1 then MAC3 (default), primary = MAC1 only
  flush              flush the macOS DNS cache
  reset              put back the DNS servers this Mac had before setup, and flush         [clean-up]
  apply              re-set the DNS servers after an IP change
ca.crt is looked for in the argument, this folder, its parent, then the current folder.
EOF
}

set_dns() {
  local mode=${1:-both} servers want got
  case $mode in
    both) servers="$MAC1_IP $MAC3_IP" ;;
    primary) servers="$MAC1_IP" ;;
    *) die "dns mode must be both or primary" ;;
  esac
  if [ -z "$(state_get CLIENT_DNS_ORIG)" ]; then
    local orig; orig=$(networksetup -getdnsservers "$NET_SERVICE" 2>/dev/null | grep -E '^[0-9a-fA-F.:]+$' | tr '\n' ' ' || true)
    orig=$(echo $orig); [ -n "$orig" ] || orig=Empty
    state_set CLIENT_DNS_ORIG "$orig"; ok "backed up original DNS servers: $orig"
  fi
  # shellcheck disable=SC2086
  sudo networksetup -setdnsservers "$NET_SERVICE" $servers
  flush_dns
  state_set CLIENT_DNS "$mode"
  sleep 1
  want=$(echo $servers)
  got=$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | awk '!s[$0]++' | head -2 | tr '\n' ' ' || true)
  got=$(echo $got)
  if [ "$mode" = primary ]; then got=${got%% *}; fi
  if [ "$got" = "$want" ]; then ok "DNS servers: $want  ($(for s in $servers; do printf '%s ' "$(ip_name "$s")"; done))"
  else warn "scutil shows '$got', expected '$want'. Is the network service called '$NET_SERVICE'? (JIO_NET_SERVICE=...)"; fi
  if grep -v '^[[:space:]]*#' /etc/hosts | grep -qi 'jio\.test'; then
    warn "/etc/hosts has a jio.test line; it overrides DNS:"; grep -i 'jio\.test' /etc/hosts | sed 's/^/      /'
  fi
  local a; a=$(dscacheutil -q host -a name app.jio.test 2>/dev/null | awk '/ip_address/{print $2; exit}' || true)
  if [ -n "$a" ]; then ok "app.jio.test -> $a ($(ip_name "$a"))"; else warn "app.jio.test doesn't resolve yet (is dnsmasq running on Mac 1?)"; fi
}

trust_ca() {
  local ca=""
  for p in "${1:-}" "$JIO_DIR/ca.crt" "$JIO_DIR/../ca.crt" "$PWD/ca.crt"; do
    if [ -n "$p" ] && [ -f "$p" ]; then ca=$p; break; fi
  done
  if [ -z "$ca" ]; then
    warn "ca.crt not found; skipping CA trust (copy it from Mac 2, then: ./client.sh setup /path/to/ca.crt)"
    return 0
  fi
  if security verify-cert -c "$ca" >/dev/null 2>&1; then ok "CA already trusted ($ca)"; return 0; fi
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca"
  ok "CA trusted ($ca)"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
  setup) sudo_keepalive; say "Client setup on $(upper "$(my_role)") ($(my_ip))"; trust_ca "${1:-}"; set_dns both ;;
  dns) set_dns "${1:-both}" ;;
  apply) m=$(state_get CLIENT_DNS); if [ -n "$m" ]; then set_dns "$m"; else ok "client DNS not configured by this script"; fi ;;
  flush) flush_dns; ok "DNS cache flushed at $(now)" ;;
  reset)
    orig=$(state_get CLIENT_DNS_ORIG); orig=${orig:-Empty}
    # shellcheck disable=SC2086
    sudo networksetup -setdnsservers "$NET_SERVICE" $orig; flush_dns
    state_set CLIENT_DNS ""; state_set CLIENT_DNS_ORIG ""
    ok "DNS servers restored to the original: $orig" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
