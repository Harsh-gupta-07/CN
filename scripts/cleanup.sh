#!/usr/bin/env bash
# cleanup.sh - end-of-session clean-up for this Mac (guide: "Clean-up after each session").
#   ./cleanup.sh             stop what this Mac runs, remove the pf rules, put the original DNS servers back
#   ./cleanup.sh --restore   ALSO copy back every original file the scripts replaced
#                            (dnsmasq.conf.phase1, nginx.conf.phase1, pf anchor, certs).
#                            Files that didn't exist before are removed. Backups are kept.
#   ./cleanup.sh --keep-dns  leave this Mac's DNS client settings alone
. "$(dirname "$0")/lib.sh"
load_ips

KEEP_DNS=0; RESTORE=0
for a in "$@"; do
  case $a in
    --keep-dns) KEEP_DNS=1 ;;
    --restore) RESTORE=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $a" ;;
  esac
done
role=$(my_role)
say "Cleaning up $(upper "${role:-this Mac}")"
sudo_keepalive

# this Mac's .state says it turned these on, so skip the "right Mac?" check and keep going on errors
if [ -n "$(state_get FW_ON)" ] || [ -n "$(state_get FW_TOKEN)" ]; then JIO_FORCE=1 "$JIO_DIR/firewall.sh" off 2>&1 | grep -v 'JIO_FORCE=1' || warn "firewall.sh off had a problem"; fi
if pgrep -x nginx >/dev/null 2>&1; then sudo nginx -s stop; ok "nginx stopped"; fi
if [ -n "$(state_get DNS_ROLE)" ] || [ "$role" = mac1 ] || [ "$role" = mac3 ]; then
  sudo brew services stop dnsmasq >/dev/null 2>&1 || true; ok "dnsmasq stopped"
fi
if pkill -f 'server\.py [AB] 300[12]' 2>/dev/null; then ok "backend stopped"; fi
if [ "$KEEP_DNS" = 0 ] && { [ -n "$(state_get CLIENT_DNS)" ] || [ -n "$(state_get CLIENT_DNS_ORIG)" ]; }; then
  "$JIO_DIR/client.sh" reset || warn "client.sh reset had a problem"
fi

if [ "$RESTORE" = 1 ]; then
  say "Restoring original files"
  found=0
  if [ -f "$STATE_FILE" ]; then
    grep '^ORIG_' "$STATE_FILE" >"$STATE_FILE.tmp" || true
    while IFS='=' read -r key val; do
      found=1
      dst=${val%%|*}; bak=${val#*|}
      if [ "$bak" = NONE ]; then
        sudo rm -f "$dst" </dev/null; ok "removed $dst (it didn't exist before)"
      elif sudo test -f "$bak" </dev/null; then
        sudo cp -p "$bak" "$dst" </dev/null; ok "restored $dst from $bak"
      else
        fail "backup $bak is missing; left $dst as it is"; continue
      fi
      state_set "$key" ""
    done <"$STATE_FILE.tmp"
    rm -f "$STATE_FILE.tmp"
  fi
  [ "$found" = 1 ] || ok "no files were replaced on this Mac"
  state_set DNS_ROLE ""; state_set EDGE_NAME ""
fi
ok "done"
