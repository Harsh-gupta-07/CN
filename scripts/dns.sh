#!/usr/bin/env bash
# dns.sh - dnsmasq on Mac 1 (primary) and Mac 3 (backup).   Guide: Extensions A, B, E
. "$(dirname "$0")/lib.sh"
load_ips

CONF="$BREW/etc/dnsmasq.conf"

usage() { cat <<EOF
Usage: ./dns.sh <command>

  primary              Mac 1: write dnsmasq.conf and (re)start it                    [A1]
  backup               Mac 3: install dnsmasq if needed, write config, open the
                       macOS firewall for it, (re)start                              [A2]
  set <rec> <target>   point a record at mac2 | mac3 | an IP, restart, print time
                       rec = ttl | app | api | edge (edge = app + api together)
                         ./dns.sh set ttl mac3    TTL demo                            [B3]
                         ./dns.sh set ttl mac2    put it back                         [B5]
                         ./dns.sh set edge mac3   edge cutover                        [E5]
                         ./dns.sh set edge mac2   roll back                           [E7]
  show                 the records in the config and what this server answers
  stop | start         stop / start the service                                      [A6, A8]
  apply                rewrite the config for this Mac's existing role (after an IP change)
  render [primary|backup]   print the config without writing it

Run 'set' on BOTH Mac 1 and Mac 3 (each server keeps its own copy of the records).
TTL is $TTL s (override: JIO_TTL=120 ./dns.sh ...).
EOF
}

rec_target() { local v; v=$(state_get "REC_$1"); echo "${v:-mac2}"; }

owner_of() { case $1 in primary) echo mac1 ;; backup) echo mac3 ;; *) die "role must be primary or backup" ;; esac; }

# Template = the team's dnsmasq.conf, byte for byte. Only the IPs (and TTL) are filled in.
render() {
  local listen=$1 app api ttl
  app=$(mac_ip "$(rec_target APP)"); api=$(mac_ip "$(rec_target API)"); ttl=$(mac_ip "$(rec_target TTL)")
  sed -e "s|@LISTEN@|$listen|g" -e "s|@APP@|$app|g" -e "s|@API@|$api|g" -e "s|@TTLHOST@|$ttl|g" -e "s|@TTL@|$TTL|g" <<'EOF'
listen-address=127.0.0.1,@LISTEN@
bind-interfaces
no-resolv
server=8.8.8.8
domain-needed

# name,IP,TTL  - the trailing @TTL@ is the TTL (without it dnsmasq answers with TTL 0)
host-record=app.jio.test,@APP@,@TTL@
host-record=api.jio.test,@API@,@TTL@
host-record=ttl.jio.test,@TTLHOST@,@TTL@

log-queries
log-facility=/tmp/dnsmasq.log
EOF
}

dnsmasq_bin() {
  local p="$BREW/opt/dnsmasq/sbin/dnsmasq"
  [ -x "$p" ] || p="$BREW/sbin/dnsmasq"
  [ -x "$p" ] && echo "$p"
}

open_mac_firewall() {
  # dnsmasq runs as a background service, so macOS never shows the "Allow" prompt; it just
  # drops queries from other Macs. Allow it explicitly (guide A2).
  local fw=/usr/libexec/ApplicationFirewall/socketfilterfw bin
  [ -x "$fw" ] || return 0
  bin=$(realpath_ "$(dnsmasq_bin)")
  sudo "$fw" --add "$bin" >/dev/null 2>&1 || true
  sudo "$fw" --unblockapp "$bin" >/dev/null 2>&1 || true
  if "$fw" --getblockall 2>/dev/null | grep -qi enabled; then
    warn "macOS firewall is set to 'Block all incoming connections'. Turn that off in System Settings -> Network -> Firewall -> Options."
  else
    ok "macOS firewall allows dnsmasq"
  fi
}

restart_and_verify() {
  local listen=$1 want name
  [ -n "$(dnsmasq_bin)" ] || die "dnsmasq isn't installed (brew install dnsmasq)"
  "$(dnsmasq_bin)" --test -C "$CONF" >/dev/null 2>&1 || {
    "$(dnsmasq_bin)" --test -C "$CONF" || true; die "dnsmasq rejected $CONF"; }
  sudo brew services restart dnsmasq >/dev/null
  ok "dnsmasq restarted at $(now)"
  for name in app ttl; do
    want=$(mac_ip "$(rec_target "$(upper $name)")")
    if retry 8 test_answer "$listen" "$name.jio.test" "$want"; then
      ok "dig @$listen $name.jio.test -> $want ($(ip_name "$want")), TTL $TTL"
    else
      fail "dig @$listen $name.jio.test returned '$(dig_a "$listen" "$name.jio.test")', expected $want"
      echo "     Run it in the foreground to see why:  sudo $(dnsmasq_bin) --no-daemon -C $CONF" >&2
      echo "     'Can't assign requested address' means $listen isn't this Mac's IP." >&2
      exit 1
    fi
  done
}
test_answer() { [ "$(dig_a "$1" "$2")" = "$3" ]; }

install_role() {
  local role=$1 owner listen
  owner=$(owner_of "$role")
  expect_role "$owner" "The $role DNS server"
  listen=$(mac_ip "$owner")
  sudo_keepalive
  if [ -z "$(dnsmasq_bin)" ]; then say "Installing dnsmasq"; brew install dnsmasq; fi
  say "dnsmasq ($role) on $(upper "$owner") listening on $listen"
  render "$listen" | install_file "$CONF" "$CONF.phase1"
  state_set DNS_ROLE "$role"
  open_mac_firewall
  restart_and_verify "$listen"
}

this_role() {
  local r; r=$(state_get DNS_ROLE)
  if [ -z "$r" ]; then
    case "$(my_role)" in mac1) r=primary ;; mac3) r=backup ;; *) die "This Mac isn't Mac 1 or Mac 3, so it has no DNS server." ;; esac
  fi
  echo "$r"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
  primary|backup) install_role "$cmd" ;;
  apply) install_role "$(this_role)" ;;
  set)
    [ $# -eq 2 ] || die "usage: ./dns.sh set ttl|app|api|edge mac2|mac3|IP"
    target=$(lower "$2"); mac_ip "$target" >/dev/null
    case "$(lower "$1")" in
      ttl) state_set REC_TTL "$target" ;;
      app) state_set REC_APP "$target" ;;
      api) state_set REC_API "$target" ;;
      edge) state_set REC_APP "$target"; state_set REC_API "$target" ;;
      *) die "record must be ttl, app, api or edge" ;;
    esac
    install_role "$(this_role)"
    say "Change done at $(now). Write this time down."
    other=mac3; [ "$(this_role)" = backup ] && other=mac1
    warn "Now run the same command on $(upper $other):  ./dns.sh set $1 $2"
    ;;
  show)
    r=$(this_role); listen=$(mac_ip "$(owner_of "$r")")
    say "Records in $CONF ($r)"
    grep '^host-record' "$CONF" | sed 's/^/  /'
    say "Answers from @$listen"
    for n in app api ttl; do printf '  %-14s %s\n' "$n.jio.test" "$(dig_a "$listen" $n.jio.test)"; done
    ;;
  stop)  sudo brew services stop dnsmasq;  ok "stopped at $(now)" ;;
  start) sudo brew services start dnsmasq; ok "started at $(now)" ;;
  render)
    r=${1:-$(this_role)}; render "$(mac_ip "$(owner_of "$r")")" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
