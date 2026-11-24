#!/usr/bin/env bash
# lib.sh - shared helpers for the Team Jio Phase 2 scripts.
# Sourced by every other script; don't run it directly.
# Written for the bash 3.2 that ships with macOS.

set -euo pipefail

JIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPS_FILE="$JIO_DIR/ips.conf"          # the four Mac IPs (written by set-ips.sh)
STATE_FILE="$JIO_DIR/.state"          # what this Mac has installed (roles, record targets, pf token)
IFACE="${JIO_IF:-en0}"                # network interface used to detect this Mac's IP
NET_SERVICE="${JIO_NET_SERVICE:-Wi-Fi}"
TTL="${JIO_TTL:-30}"                  # DNS TTL for the jio.test records
PORT_A=3001
PORT_B=3002
BREW="${BREW:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"
CURL=/usr/bin/curl; [ -x "$CURL" ] || CURL=curl   # Apple curl uses the System keychain (trusted CA)

# ---------- output ----------
if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=''; R=''; G=''; Y=''; C=''; N=''
fi
say()  { printf '%s==>%s %s\n' "$C$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
fail() { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$R$B" "$N" "$*" >&2; exit 1; }
now()  { date +%H:%M:%S; }

if [ "$(id -u)" -eq 0 ] && [ "${JIO_ALLOW_ROOT:-0}" != 1 ]; then
  die "Run this as your normal user, not with sudo. It asks for your password when it needs sudo."
fi

# ---------- IPs ----------
is_ip() {
  local o
  [[ ${1:-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
    [ "$((10#$o))" -le 255 ] || return 1
  done
}

load_ips() {
  [ -f "$IPS_FILE" ] || die "No IPs saved yet. Run first:  ./set-ips.sh MAC1_IP MAC2_IP MAC3_IP MAC4_IP"
  # shellcheck source=/dev/null
  . "$IPS_FILE"
  local n v
  for n in 1 2 3 4; do
    eval "v=\${MAC${n}_IP:-}"
    is_ip "$v" || die "MAC${n}_IP in ips.conf is missing or invalid ('$v'). Re-run ./set-ips.sh."
  done
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# mac_ip mac2 | MAC2 | 2 | 10.0.0.5  ->  the IP
mac_ip() {
  case "$(lower "$1")" in
    mac1|1) echo "$MAC1_IP" ;;
    mac2|2) echo "$MAC2_IP" ;;
    mac3|3) echo "$MAC3_IP" ;;
    mac4|4) echo "$MAC4_IP" ;;
    *) if is_ip "$1"; then echo "$1"; else die "'$1' is not mac1..mac4 or an IPv4 address"; fi ;;
  esac
}

# ip_name 10.7.2.8 -> MAC2 (or the IP itself if it isn't one of ours)
ip_name() {
  case "$1" in
    "$MAC1_IP") echo MAC1 ;; "$MAC2_IP") echo MAC2 ;;
    "$MAC3_IP") echo MAC3 ;; "$MAC4_IP") echo MAC4 ;;
    *) echo "$1" ;;
  esac
}

my_ip() { ipconfig getifaddr "$IFACE" 2>/dev/null || true; }

# which Mac is this? -> mac1..mac4, or empty
my_role() {
  local me; me=$(my_ip)
  [ -n "$me" ] || return 0
  case "$me" in
    "$MAC1_IP") echo mac1 ;; "$MAC2_IP") echo mac2 ;;
    "$MAC3_IP") echo mac3 ;; "$MAC4_IP") echo mac4 ;;
  esac
}

# expect_role mac3 "Backend A"  -> dies if this Mac isn't Mac 3 (JIO_FORCE=1 overrides)
expect_role() {
  local want=$1 what=$2 me ip
  me=$(my_role); ip=$(my_ip)
  [ "$me" = "$want" ] && return 0
  local msg="$what belongs on $(upper "$want") ($(mac_ip "$want")), but this Mac is ${me:+$(upper "$me") }(${ip:-no IP on $IFACE})."
  if [ "${JIO_FORCE:-0}" = 1 ]; then warn "$msg Continuing because JIO_FORCE=1."; return 0; fi
  die "$msg
       If the IP changed, update it everywhere with ./set-ips.sh. To run anyway: JIO_FORCE=1 $0 ..."
}

# ---------- state ----------
state_get() {
  [ -f "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" | tail -1
}
state_set() {
  local tmp; tmp=$(mktemp)
  if [ -f "$STATE_FILE" ]; then grep -v "^$1=" "$STATE_FILE" >"$tmp" || true; fi
  if [ -n "${2:-}" ]; then echo "$1=$2" >>"$tmp"; fi
  mv "$tmp" "$STATE_FILE"
}

# ---------- misc ----------
# ---------- originals ----------
# Every file a script writes is backed up ONCE, the first time, before it is touched.
# .state records "ORIG_<file>=<file>|<backup>" (or "|NONE" if the file didn't exist),
# so later runs never overwrite the backup and ./cleanup.sh --restore can put it all back.
orig_key()     { printf 'ORIG_%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
is_generated() { [ -n "$(state_get "$(orig_key "$1")")" ]; }

# backup_once /path [backup-path]   (default backup: /path.orig)
backup_once() {
  local dst=$1 bak=${2:-$1.orig}
  is_generated "$dst" && return 0
  if sudo test -f "$dst"; then
    if sudo test -f "$bak"; then
      ok "original already backed up: $bak"
    else
      sudo mkdir -p "$(dirname "$bak")"
      sudo cp -p "$dst" "$bak"; ok "backed up original: $dst -> $bak"
    fi
    state_set "$(orig_key "$dst")" "$dst|$bak"
  else
    state_set "$(orig_key "$dst")" "$dst|NONE"
  fi
}

# install_file /path [backup-path] < content   (backs up the original first, then writes)
install_file() {
  local dst=$1 bak=${2:-} tmp; tmp=$(mktemp)
  cat >"$tmp"
  backup_once "$dst" ${bak:+"$bak"}
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    ok "$dst is already up to date"; rm -f "$tmp"; return 0
  fi
  sudo mkdir -p "$(dirname "$dst")"
  sudo cp "$tmp" "$dst"; sudo chmod 644 "$dst"; rm -f "$tmp"
  ok "wrote $dst"
}

flush_dns() { sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null || true; }

# retry N cmd...  -> run cmd up to N times, 1 s apart
retry() {
  local n=$1 i=0; shift
  while [ "$i" -lt "$n" ]; do "$@" && return 0; i=$((i + 1)); sleep 1; done
  return 1
}

# dig_a server name  -> first A record, or empty (dig +short prints errors on stdout, so filter)
dig_a() { dig @"$1" "$2" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true; }

realpath_() { realpath "$1" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"; }

sudo_keepalive() { sudo -v || die "sudo is needed"; }
