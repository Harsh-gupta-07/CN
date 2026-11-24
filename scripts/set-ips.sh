#!/usr/bin/env bash
# set-ips.sh - save the four Mac IPs and rewrite every config this Mac uses.
#
#   ./set-ips.sh 10.7.17.214 10.7.2.8 10.7.19.127 10.7.24.144   # MAC1 MAC2 MAC3 MAC4
#   ./set-ips.sh                 # asks for each IP (Enter keeps the current one)
#   ./set-ips.sh --show          # print the saved IPs and which Mac this is
#   ./set-ips.sh --zshrc         # also load the IPs in every new terminal ($MAC1_IP etc.)
#   ./set-ips.sh --no-apply ...  # save only; don't touch dnsmasq/nginx/pf/client DNS
#
# Run it with the SAME four IPs on every Mac. When an IP changes (Wi-Fi DHCP), run it again
# on every Mac: it regenerates whatever this Mac already runs (dnsmasq, nginx, pf rules,
# client DNS servers) and restarts it.
. "$(dirname "$0")/lib.sh"

APPLY=1; ZSHRC=0; SHOW=0; IPS=""
for a in "$@"; do
  case $a in
    --no-apply) APPLY=0 ;;
    --zshrc) ZSHRC=1 ;;
    --show) SHOW=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $a" ;;
    *) IPS="$IPS $a" ;;
  esac
done

OLD1=""; OLD2=""; OLD3=""; OLD4=""
if [ -f "$IPS_FILE" ]; then
  # shellcheck source=/dev/null
  . "$IPS_FILE"
  OLD1=${MAC1_IP:-}; OLD2=${MAC2_IP:-}; OLD3=${MAC3_IP:-}; OLD4=${MAC4_IP:-}
fi

show() {
  load_ips
  local me role; me=$(my_ip); role=$(my_role)
  printf '  MAC1_IP=%-15s  primary DNS + client\n' "$MAC1_IP"
  printf '  MAC2_IP=%-15s  edge (nginx :443)\n' "$MAC2_IP"
  printf '  MAC3_IP=%-15s  Backend A :3001 + backup DNS + standby edge\n' "$MAC3_IP"
  printf '  MAC4_IP=%-15s  Backend B :3002 + client\n' "$MAC4_IP"
  if [ -n "$role" ]; then ok "This Mac ($me) is $(upper "$role")"
  else warn "This Mac's IP (${me:-none on $IFACE}) is not in the list."; fi
}

if [ "$SHOW" = 1 ]; then show; exit 0; fi

# ---- collect the IPs ----
# shellcheck disable=SC2086
set -- $IPS
if [ $# -eq 0 ]; then
  echo "This Mac's IP on $IFACE: $(my_ip)"
  for n in 1 2 3 4; do
    eval "cur=\$OLD$n"
    # shellcheck disable=SC2154
    read -r -p "MAC${n}_IP [${cur}]: " v
    eval "NEW$n=\${v:-\$cur}"
  done
elif [ $# -eq 4 ]; then
  NEW1=$1; NEW2=$2; NEW3=$3; NEW4=$4
else
  die "Give all four IPs in order: MAC1 MAC2 MAC3 MAC4 (you gave $#)."
fi

for n in 1 2 3 4; do
  eval "v=\$NEW$n"
  is_ip "$v" || die "MAC${n}_IP '$v' is not a valid IPv4 address."
done
# shellcheck disable=SC2154
if [ "$(printf '%s\n' "$NEW1" "$NEW2" "$NEW3" "$NEW4" | sort -u | wc -l | tr -d ' ')" != 4 ]; then
  die "The four IPs must all be different."
fi

CHANGED=0
[ "$NEW1 $NEW2 $NEW3 $NEW4" = "$OLD1 $OLD2 $OLD3 $OLD4" ] || CHANGED=1

if [ "$CHANGED" = 1 ]; then
  cat >"$IPS_FILE" <<EOF
# Team Jio Mac IPs - written by set-ips.sh on $(date '+%Y-%m-%d %H:%M'). Use ./set-ips.sh to change.
export MAC1_IP=$NEW1 MAC2_IP=$NEW2 MAC3_IP=$NEW3 MAC4_IP=$NEW4
EOF
  say "Saved $IPS_FILE"
  for n in 1 2 3 4; do
    eval "o=\$OLD$n; v=\$NEW$n"
    # shellcheck disable=SC2154
    if [ -n "$o" ] && [ "$o" != "$v" ]; then ok "MAC$n: $o -> $v"; fi
  done
else
  say "IPs unchanged"
fi
show

# ---- optional: load the IPs in every new terminal ----
if [ "$ZSHRC" = 1 ]; then
  line="[ -f \"$IPS_FILE\" ] && source \"$IPS_FILE\"   # Team Jio IPs"
  if grep -qF "$IPS_FILE" ~/.zshrc 2>/dev/null; then ok "~/.zshrc already loads ips.conf"
  else echo "$line" >>~/.zshrc; ok "added to ~/.zshrc: new terminals get \$MAC1_IP..\$MAC4_IP (and follow future changes)"; fi
fi

# ---- regenerate what this Mac already runs ----
if [ "$APPLY" = 1 ] && [ "$CHANGED" = 1 ] && [ -f "$STATE_FILE" ]; then
  did=0
  if [ -n "$(state_get DNS_ROLE)" ];   then say "Updating dnsmasq";        "$JIO_DIR/dns.sh" apply;      did=1; fi
  if [ -n "$(state_get EDGE_NAME)" ];  then say "Updating nginx";          "$JIO_DIR/edge.sh" apply;     did=1; fi
  if [ -n "$(state_get FW_ON)" ];      then say "Updating pf rules";       "$JIO_DIR/firewall.sh" apply; did=1; fi
  if [ -n "$(state_get CLIENT_DNS)" ]; then say "Updating client DNS";     "$JIO_DIR/client.sh" apply;   did=1; fi
  [ "$did" = 1 ] || ok "nothing installed on this Mac yet, so nothing to update"
  warn "Backends (server.py) don't use the IPs, but restart them if this Mac's IP changed."
fi

echo
echo "Next: run the same ./set-ips.sh command on the other Macs, then ./up.sh on each."
