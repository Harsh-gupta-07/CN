#!/usr/bin/env bash
# up.sh - start everything this Mac does in Phase 2. It works out which Mac it is from its IP.
#
#   ./up.sh                 Mac 1: primary DNS + client setup
#                           Mac 2: nginx edge
#                           Mac 3: backup DNS, then Backend A in the foreground
#                           Mac 4: client setup, then Backend B in the foreground
#   ./up.sh --firewall      Mac 3 / Mac 4: also turn on the pf isolation (Extension C)
#   ./up.sh --standby       Mac 3: also start the standby edge (Extension E)
#   ./up.sh --as mac3       pretend to be that Mac (skips the IP check)
#
# Suggested order across the Macs: Mac 1 -> Mac 3 -> Mac 4 -> Mac 2, then ./check.sh on a client.
. "$(dirname "$0")/lib.sh"
load_ips

FW=0; STANDBY=0; ROLE=""
while [ $# -gt 0 ]; do
  case $1 in
    --firewall) FW=1 ;;
    --standby) STANDBY=1 ;;
    --as) ROLE=$(lower "${2:-}"); export JIO_FORCE=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[ -n "$ROLE" ] || ROLE=$(my_role)
[ -n "$ROLE" ] || die "This Mac's IP ($(my_ip)) isn't in ips.conf. Check ./set-ips.sh --show, or use --as macN."

D=$JIO_DIR
say "This is $(upper "$ROLE") ($(my_ip))"
sudo_keepalive

case $ROLE in
  mac1)
    "$D/dns.sh" primary
    "$D/client.sh" setup
    ;;
  mac2)
    "$D/edge.sh" start mac2
    ;;
  mac3)
    "$D/dns.sh" backup
    [ "$FW" = 1 ] && "$D/firewall.sh" on
    [ "$STANDBY" = 1 ] && "$D/edge.sh" start mac3
    exec "$D/backend.sh" A
    ;;
  mac4)
    "$D/client.sh" setup
    [ "$FW" = 1 ] && "$D/firewall.sh" on
    exec "$D/backend.sh" B
    ;;
esac
say "Done. From a client, run ./check.sh"
