# scripts/: Phase 2 automation

These scripts write the Phase 2 configs (dnsmasq, nginx, pf) from the four Mac IPs, start the services and check them. You don't hand-edit configs any more, and when an IP changes you run one command.

Clone the repo on all four Macs and run everything from `scripts/`. The scripts find `../backend/server.py` and `../ca.crt` on their own (override with `SERVER_PY=` or pass the path).

## 1. Set the IPs (every Mac, same command)

```bash
cd scripts
./set-ips.sh 10.7.17.214 10.7.2.8 10.7.19.127 10.7.24.144 --zshrc   # MAC1 MAC2 MAC3 MAC4
```

- `--zshrc` makes `$MAC1_IP`..`$MAC4_IP` available in every new terminal, so the guide's own commands work too.
- `./set-ips.sh --show` shows the IPs and which Mac this is. Each script uses this Mac's `en0` IP to work out which Mac it's running on, and refuses to run on the wrong Mac.
- **If an IP changes:** run `./set-ips.sh` with the new IPs on every Mac. Each Mac then rewrites and restarts whatever it already runs (dnsmasq, nginx, pf rules, client DNS servers). Record changes such as "ttl → mac3" are saved as *which Mac* rather than as an IP, so they follow the new IP too.

## 2. Start everything

Each Mac runs `./up.sh`, in this order: Mac 1 → Mac 3 → Mac 4 → Mac 2.

| Mac | `./up.sh` does |
| --- | --- |
| Mac 1 | primary dnsmasq + client setup (trusts `ca.crt`, DNS = MAC1, MAC3) |
| Mac 2 | nginx edge (writes the D1 config) + self-test |
| Mac 3 | backup dnsmasq (opens the macOS firewall for it), then Backend A in the foreground |
| Mac 4 | client setup, then Backend B in the foreground |

Options: `--firewall` (Mac 3/4, turns on Extension C), `--standby` (Mac 3, starts the standby edge).

Then, from a client: `./check.sh`

## 3. Extension cheat sheet

| Step | Command |
| --- | --- |
| 0.2 ping all | `./check.sh ping` |
| A6 / A8 stop / start primary DNS (Mac 1) | `./dns.sh stop` / `./dns.sh start` |
| B2 TTL watcher (client) | `./watch.sh dns` |
| B3 change record (**Mac 1 and Mac 3**) | `./dns.sh set ttl mac3` |
| B5 put it back (**both**) + flush client | `./dns.sh set ttl mac2` then `./client.sh flush` |
| C4 firewall on (Mac 3, Mac 4) | `./firewall.sh on` (keeps the pf token for you) |
| C1 / C5 prove isolation (any Mac) | `./firewall.sh test` |
| C6 rollback (Mac 3, Mac 4) | `./firewall.sh off` |
| D2 edge logs (Mac 2) | `./edge.sh logs` |
| D3 HTTP watcher (client) | `./watch.sh http` |
| D4 / D5 kill / restart Backend A | Ctrl-C / `./backend.sh A` |
| E1 certificate to Mac 3 | Mac 2: `./edge.sh push-certs <mac3-user>` · Mac 3: `./edge.sh install-certs` |
| E2 standby edge (Mac 3) + allow it (Mac 4) | `./edge.sh start mac3` · `./firewall.sh allow mac3` |
| E4 watcher (Mac 1) | `./watch.sh http ../evidence/phase2/E_edge_migration/client1.txt` |
| E5 cutover (**both DNS Macs**) | `./dns.sh set edge mac3` |
| E7 rollback | `./dns.sh set edge mac2` (both) · Mac 3 `./edge.sh stop` · Mac 4 `./firewall.sh deny mac3` |
| F1 ladder | `./check.sh` (stops at the first failing layer), `./check.sh --all`, `./check.sh server` |
| Clean-up | `./cleanup.sh` on every Mac (`--restore` also puts the original files back) |

## Notes

- Run the scripts as your normal user. They ask for `sudo` themselves.
- The Homebrew path is detected (`/opt/homebrew` or `/usr/local`).
- Overrides: `JIO_IF=en1`, `JIO_NET_SERVICE="USB 10/100/1000 LAN"`, `JIO_TTL=120`, `JIO_FORCE=1` (skip the "wrong Mac" check).
- `ips.conf` and `.state` are per-checkout files and are already in `scripts/.gitignore`.
- Each server keeps its own copy of the DNS records, so run `dns.sh set` on **both** Mac 1 and Mac 3. The script reminds you.
- The generated configs are your team's own files with only the IPs filled in. With the current IPs they are byte-identical to the files in `../configs/phase2/`.

## Backups

Before a script changes anything for the first time, it saves the original. It never overwrites a backup.

| What | Backup |
| --- | --- |
| `dnsmasq.conf` (Mac 1, Mac 3) | `dnsmasq.conf.phase1` next to it |
| `nginx.conf` (Mac 2, Mac 3) | `nginx.conf.phase1` next to it |
| `/etc/pf.anchors/jio-isolation` | `~/pf-backup/jio-isolation.orig` |
| pf state | `~/pf-backup/pf.conf.orig`, `status-before.txt`, `rules-before.txt`, `token` |
| Mac 3 TLS cert/key (`install-certs`) | `app.crt.orig`, `app.key.orig` |
| Client DNS servers | remembered in `.state`; `./client.sh reset` puts them back |

`./cleanup.sh --restore` stops everything and copies every original back. Any file that didn't exist before is removed. The backups themselves are kept.
