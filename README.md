## Team Members

| Name | Enrollment Number | Mac Number |
| --- | --- | --- |
| Harshvardhan Gupta | 2401010185 | 1 |
| Shivansh Upadayay | 2401020115 | 2 |
| Harsha Gonela | 2401010181 | 3 |
| Saumya kumar | 2401010432 | 4 |


# Team Jio: Phase 1 (Build & Observe)

A private LAN deployment: dnsmasq DNS, an nginx HTTPS load balancer, and two backends. A client opens `https://app.jio.test:8443` and gets responses from Backend A and Backend B in turn.

## Machines and IPs

| Machine | Role | IP | Ports |
| --- | --- | --- | --- |
| Mac 1 | DNS server (dnsmasq) + client | `10.7.22.173` | 53 (UDP/TCP) |
| Mac 2 | nginx edge: load balancer + TLS + client | `10.7.8.211` | 8080 (redirect), 8443 (HTTPS) |
| Mac 3 | Backend A + client | `10.7.16.102` | 3001 |
| Mac 4 | Backend B (same IP as Mac 3) | `10.7.16.102` | 3002 |

Domain: `app.jio.test`, `api.jio.test` (both resolve to Mac 2). CA name: `Jio Local CA`.

If any IP changes, update: `listen-address` and `host-record` (Mac 1 dnsmasq), the `upstream` block (Mac 2 nginx), and each client's DNS setting. Check with `ipconfig getifaddr en0`.

## Repository layout

```
configs/   dnsmasq.conf, nginx.conf        (no private keys)
backend/   server.py
docs/      architecture.md
evidence/  screenshots, pcaps, outputs
```

## Prerequisites

- All Macs on the same Wi-Fi, with working Mac-to-Mac ping.
- Homebrew paths assume Apple Silicon (`/opt/homebrew`). If `brew --prefix` prints `/usr/local`, replace the prefix.
- Mac 1: `brew install dnsmasq bind`
- Mac 2: `brew install nginx openssl`
- Mac 3 / Mac 4: Python 3 (`brew install python`)

## One-time setup

### Mac 1: DNS config

`/opt/homebrew/etc/dnsmasq.conf`:

```conf
listen-address=127.0.0.1,10.7.22.173
no-resolv
server=8.8.8.8
domain-needed
host-record=app.jio.test,10.7.8.211
host-record=api.jio.test,10.7.8.211
log-queries
log-facility=/tmp/dnsmasq.log
```

### Mac 2: certificate (CA + server cert)

```bash
export PATH="/opt/homebrew/opt/openssl/bin:$PATH"
mkdir -p ~/jio-ca && cd ~/jio-ca
openssl genrsa -out ca.key 4096
openssl req -x509 -new -key ca.key -sha256 -days 365 -subj "/CN=Jio Local CA" \
  -addext "basicConstraints=critical,CA:TRUE" -out ca.crt
openssl genrsa -out app.key 2048
openssl req -new -key app.key -subj "/CN=app.jio.test" -out app.csr
cat > san.ext <<EOF
subjectAltName=DNS:app.jio.test,DNS:api.jio.test
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in app.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out app.crt -days 90 -sha256 -extfile san.ext
sudo mkdir -p /opt/homebrew/etc/nginx/certs
sudo cp app.crt app.key /opt/homebrew/etc/nginx/certs/
```

Never commit `ca.key` or `app.key`. Share only `ca.crt`.

### Mac 2: nginx config

`/opt/homebrew/etc/nginx/nginx.conf`:

```nginx
worker_processes 1;
events { worker_connections 1024; }

http {
  upstream app_backend {
    server 10.7.16.102:3001 max_fails=2 fail_timeout=10s;
    server 10.7.16.102:3002 max_fails=2 fail_timeout=10s;
  }

  server {
    listen 8080;
    server_name app.jio.test api.jio.test;
    return 301 https://$host:8443$request_uri;
  }

  server {
    listen 8443 ssl;
    http2 on;
    server_name app.jio.test api.jio.test;
    ssl_certificate     /opt/homebrew/etc/nginx/certs/app.crt;
    ssl_certificate_key /opt/homebrew/etc/nginx/certs/app.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
      proxy_pass http://app_backend;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_connect_timeout 2s;
      proxy_next_upstream error timeout http_502 http_503;
    }
  }
}
```

### Every client Mac: trust the CA

Copy `ca.crt` to the Mac (AirDrop or `scp`), then from its folder:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
```

Use `/usr/bin/curl` for tests: it uses the macOS keychain, Homebrew's curl does not.

## Run the project (in this order)

DNS first, then backends, then the edge, then clients.

**1. All Macs:** same Wi-Fi, IPs unchanged, keep awake.

```bash
ipconfig getifaddr en0
caffeinate -d &
```

**2. Mac 1: start DNS**

```bash
sudo brew services start dnsmasq
sudo lsof -nP -i :53                       # shows dnsmasq
dig @10.7.22.173 app.jio.test +short       # prints 10.7.8.211
```

**3. Mac 3 / Mac 4: start the backends** (from the `backend/` folder)

```bash
python3 server.py A 3001
python3 server.py B 3002
```

Click **Allow** on any firewall prompt. Verify from Mac 2:

```bash
curl -i http://10.7.16.102:3001/api/status     # X-Backend: A
curl -i http://10.7.16.102:3002/api/status     # X-Backend: B
```

**4. Mac 2: start nginx**

```bash
sudo nginx -t && sudo nginx                    # reload later: sudo nginx -s reload
lsof -iTCP:8443 -sTCP:LISTEN
```

**5. Every client Mac: use Mac 1 as DNS**

Before changing anything, check that this works from the client: `dig @10.7.22.173 app.jio.test +short`. Then:

```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.22.173
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
networksetup -getdnsservers Wi-Fi              # 10.7.22.173
```

**6. Verify from a client**

```bash
dig app.jio.test                               # SERVER: 10.7.22.173, answer 10.7.8.211
for i in 1 2 3 4 5 6; do /usr/bin/curl -sI https://app.jio.test:8443/api/status | grep -i x-backend; done
```

Expected: `A` and `B` alternating, with no certificate warning and no `-k`.

Other checks:

```bash
/usr/bin/curl -I https://app.jio.test:8443/api/static    # Cache-Control: max-age=60 + ETag
curl -I http://app.jio.test:8080/                         # 301 to https://app.jio.test:8443/
```

## Shut down (restore every Mac)

```bash
# Mac 1
sudo brew services stop dnsmasq
sudo lsof -nP -i :53                                      # prints nothing
# Mac 2
sudo nginx -s stop
# Mac 3 / Mac 4: Ctrl-C each server.py
# Every Mac
sudo networksetup -setdnsservers Wi-Fi Empty
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
networksetup -getdnsservers Wi-Fi                         # "There aren't any DNS Servers set"
```

To remove the trusted CA (use the exact name from `openssl x509 -in ca.crt -noout -subject`):

```bash
sudo security delete-certificate -c "Jio Local CA" /Library/Keychains/System.keychain
sudo security remove-trusted-cert -d ca.crt
```

## Failure demos (summary)

| # | Break | Expected |
| --- | --- | --- |
| 1 | Client DNS set to `192.0.2.1` | name fails, `ping 10.7.8.211` works |
| 2 | Change `host-record` to a wrong IP, restart dnsmasq | resolves to the wrong host, timeout |
| 3 | Stop Backend A | all requests succeed from B |
| 4 | Stop both backends | `502 Bad Gateway` |
| 5 | `curl https://app.jio.test:4443` | connection refused |

Restore after each demo and re-run the A/B loop.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `dig` times out, even to `127.0.0.1` | dnsmasq not running or started without `sudo` | `sudo brew services restart dnsmasq`; run it in the foreground to see errors |
| `app.jio.test` resolves to the wrong IP | wrong `host-record`, dnsmasq not restarted, or stale cache | fix the record to `10.7.8.211`, restart dnsmasq, flush the client cache |
| `Connection refused` on 8443 | nginx not running, or the name points at the wrong Mac | `sudo nginx -t && sudo nginx`; check `dig app.jio.test +short` |
| `502 Bad Gateway` | backends down or wrong upstream IP | start both `server.py`, check `curl http://10.7.16.102:3001/api/status` from Mac 2 |
| Certificate error | CA not trusted on this client, or Homebrew curl | install `ca.crt`; use `/usr/bin/curl` |
| Chrome says unreachable or cancelled | no Local Network permission, or secure DNS enabled | Settings → Privacy & Security → Local Network → enable Chrome; turn off "Use secure DNS" |
| Works on Mac 2, fails on other Macs | firewall or Wi-Fi client isolation | allow incoming connections for nginx/Python, or use a network without isolation |
| Only `A` appears | Backend B not running or missing from `upstream` | start `server.py B 3002`; check `nginx.conf` |

Always include the port in URLs (`:8080` / `:8443`).