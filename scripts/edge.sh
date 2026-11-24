#!/usr/bin/env bash
# edge.sh - nginx edge on Mac 2 (and the standby edge on Mac 3).   Guide: Extensions D, E
. "$(dirname "$0")/lib.sh"
load_ips

CONF="$BREW/etc/nginx/nginx.conf"
CERTS="$BREW/etc/nginx/certs"
LOGS="$BREW/var/log/nginx"

usage() { cat <<EOF
Usage: ./edge.sh <command>

  start [mac2|mac3]      write nginx.conf (upstreams = Backend A on MAC3, Backend B on MAC4),
                         test it, start or reload nginx, then self-test.    [D1, E2]
                         Defaults to this Mac's name; X-Edge is set to it.
  stop                   stop nginx                                         [E7]
  logs                   follow access.log and error.log together           [D2]
  push-certs <mac3-user> Mac 2: scp app.crt + app.key to Mac 3's home folder [E1]
  install-certs [dir]    Mac 3: move app.crt + app.key from dir (default ~) into place [E1]
  apply                  rewrite the config after an IP change (reloads only if running)
  render [mac2|mac3]     print the config without writing it
EOF
}

# Template = the team's nginx.conf, byte for byte. Filled in: backend IPs, X-Edge name,
# Homebrew path (/opt/homebrew on Apple Silicon, so unchanged there).
render() {
  local name=$1
  sed -e "s|@BREW@|$BREW|g" -e "s|@A@|$MAC3_IP:$PORT_A|g" -e "s|@B@|$MAC4_IP:$PORT_B|g" -e "s|@EDGE@|$name|g" <<'EOF'
worker_processes 1;
events { worker_connections 1024; }

http {
  # Phase 2: log WHICH backend served each request (and any retry: "ustatus=502, 200")
  log_format upstreamlog '$time_local client=$remote_addr "$request" status=$status '
                         'upstream=$upstream_addr ustatus=$upstream_status '
                         'urt=$upstream_response_time';
  access_log @BREW@/var/log/nginx/access.log upstreamlog;
  error_log  @BREW@/var/log/nginx/error.log warn;   # warn: shows "upstream server temporarily disabled"

  upstream app_backend {                 # round-robin by default
    server @A@ max_fails=1 fail_timeout=10s;   # Backend A (Mac 3)
    server @B@ max_fails=1 fail_timeout=10s;   # Backend B (Mac 4)
  }

  # HTTP: redirect everything to HTTPS
  server {
    listen 80;
    server_name app.jio.test api.jio.test;
    return 301 https://$host$request_uri;
  }

  # HTTPS: TLS terminates here
  server {
    listen 443 ssl;
    http2 on;                            # needs nginx >= 1.25.1
    server_name app.jio.test api.jio.test;

    ssl_certificate     @BREW@/etc/nginx/certs/app.crt;
    ssl_certificate_key @BREW@/etc/nginx/certs/app.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    add_header X-Edge "@EDGE@" always;     # Phase 2: which edge answered (Extension E)

    location / {
      proxy_pass http://app_backend;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_connect_timeout 2s;
      proxy_read_timeout    5s;                                   # Phase 2: hung backend = failed
      proxy_next_upstream error timeout http_502 http_503 http_504;
      proxy_next_upstream_tries 2;                                # Phase 2: retry once on the other backend
    }
  }
}
EOF
}

edge_name() {
  local n=${1:-$(state_get EDGE_NAME)}
  [ -n "$n" ] || n=$(my_role)
  n=$(lower "$n")
  case $n in mac2|mac3) echo "$n" ;; *) die "The edge runs on mac2 (or the standby on mac3); this Mac is '${n:-unknown}'." ;; esac
}

running() { pgrep -x nginx >/dev/null 2>&1; }

write_conf() {
  local name=$1
  command -v nginx >/dev/null || { say "Installing nginx"; brew install nginx; }
  sudo test -f "$CERTS/app.crt" && sudo test -f "$CERTS/app.key" || die "Missing $CERTS/app.crt or app.key.
       On Mac 3: copy them from Mac 2 first (./edge.sh push-certs on Mac 2, then ./edge.sh install-certs here)."
  sudo mkdir -p "$LOGS"
  render "$name" | install_file "$CONF" "$CONF.phase1"
  sudo nginx -t -q 2>/dev/null || { sudo nginx -t || true; die "nginx -t failed"; }
  ok "nginx -t: config OK"
  state_set EDGE_NAME "$name"
}

self_test() {
  local ip; ip=$(mac_ip "$1")
  sleep 1
  say "Self-test through this edge (curl --resolve to $ip, cert not verified here)"
  local i
  for i in 1 2 3 4; do
    "$CURL" -sk -m 5 -o /dev/null -D - --resolve "app.jio.test:443:$ip" https://app.jio.test/api/status \
      | tr -d '\r' | grep -iE '^HTTP|^x-edge|^x-backend' | tr '\n' ' ' || true
    echo
  done | sed 's/^/  /'
  echo "  (502 = nginx is up but no backend answers: start server.py on Mac 3 / Mac 4)"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
  start)
    name=$(edge_name "${1:-}")
    expect_role "$name" "The $name edge"
    sudo_keepalive
    say "nginx edge on $(upper "$name"): upstream A=$MAC3_IP:$PORT_A  B=$MAC4_IP:$PORT_B"
    write_conf "$name"
    if running; then sudo nginx -s reload; ok "nginx reloaded"; else sudo nginx; ok "nginx started"; fi
    sudo lsof -nP -iTCP:443 -sTCP:LISTEN 2>/dev/null | grep -q nginx && ok "listening on :443" || warn "nothing on :443 yet"
    self_test "$name"
    if [ "$name" = mac3 ]; then
      warn "If Extension C's firewall is on, run on Mac 4:  ./firewall.sh allow mac3"
      echo "  Then test from a client:  curl -sI --resolve app.jio.test:443:$MAC3_IP https://app.jio.test/api/status"
    fi
    ;;
  apply)
    name=$(edge_name)
    write_conf "$name"
    if running; then sudo nginx -s reload; ok "nginx reloaded"; else ok "nginx not running; config saved for next start"; fi
    ;;
  stop)
    if running; then sudo nginx -s stop; ok "nginx stopped at $(now)"; else ok "nginx wasn't running"; fi ;;
  logs)
    echo "Ctrl-C to stop."; tail -n 5 -f "$LOGS/access.log" "$LOGS/error.log" ;;
  push-certs)
    [ $# -eq 1 ] || die "usage: ./edge.sh push-certs <mac3-username>   (needs Remote Login on Mac 3)"
    sudo cat "$CERTS/app.key" >/tmp/jio-app.key && chmod 600 /tmp/jio-app.key
    scp "$CERTS/app.crt" /tmp/jio-app.key "$1@$MAC3_IP:~/" && ok "copied to $1@$MAC3_IP:~/"
    rm -f /tmp/jio-app.key
    echo "  On Mac 3 run:  ./edge.sh install-certs"
    ;;
  install-certs)
    dir=${1:-$HOME}
    key="$dir/app.key"; [ -f "$key" ] || key="$dir/jio-app.key"
    [ -f "$dir/app.crt" ] && [ -f "$key" ] || die "app.crt and app.key not found in $dir"
    sudo mkdir -p "$CERTS"
    backup_once "$CERTS/app.crt"; backup_once "$CERTS/app.key"
    sudo mv "$dir/app.crt" "$CERTS/app.crt"
    sudo mv "$key" "$CERTS/app.key"
    sudo chmod 600 "$CERTS/app.key"
    ok "certificate and key installed in $CERTS (never commit app.key)"
    ;;
  render) render "$(edge_name "${1:-}")" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
