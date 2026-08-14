# Railway Tailscale VPN

## Overview

Host personal VPN on Railway using Tailscale

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/new/template/uIBpGp?referralCode=androidquartz)

## How to setup

1. To get started, you should create an account on [tailscale](https://tailscale.com), if you already have an account skip to next step

2. Go to you tailscale admin console settings then to [keys](https://login.tailscale.com/admin/settings/keys)

3. Click on 'Generate auth key ...'

    ![admin_console_keys.png](./readme-screenshots/admin_console_keys.png)

4. Give you key a description then click 'Generate key' when you are finished

    ![generating_auth_key.png](./readme-screenshots/generating_auth_key.png)

    Remember to take a note of the key because you'll see it only once

5. Go to railway and paste in the key in TAILSCALE_AUTHKEY variable

6. Deploy!

7. Go to your tailscale machines and approve railway-app as an exit node

    ![approve_exit_node.png](./readme-screenshots/approve_exit_node.png)

8. Disable key expiry for the machine you just deployed

    ![disable_key_expiry.png](./readme-screenshots/disable_key_expiry.png)

9. Use this command to connect to your VPN

    ```sh
    tailscale up --exit-node railway-app # or replace railway-app with your hostname
    ```

## More Info

[Tailscale](https://tailscale.com/)

[Tailscale Exit nodes](https://tailscale.com/kb/1103/exit-nodes/)

[Using Tailscale Auth Keys](https://tailscale.com/kb/1085/auth-keys/)

---

## Oracle Native TUN Architecture (production code-server environment)

### Why two separate environments?

| | Railway (this repo) | Oracle VPS |
|---|---|---|
| Networking | Userspace (no `/dev/net/tun`) | Kernel TUN (`tailscale0` real interface) |
| Tailscale mode | `--tun=userspace-networking` | `TS_USERSPACE=false` |
| SOCKS5 proxy | Yes (required for userspace path) | **None** |
| code-server traffic | Via SOCKS5/HTTP proxy | Real Layer-3 routing |
| `/dev/net/tun` | Not available | Available (`NET_ADMIN` granted) |
| Use case | Exit-node sidecar, legacy/alternate | **Production code-server workload** |

Railway containers run in a sandboxed environment that does not expose `/dev/net/tun`.
Real kernel TUN networking requires a VPS or bare-metal host.  The Oracle host
provides that environment and is the intended home for the production code-server
workload.

### Reference files

`docker-compose.oracle.yml` in this repository is a reference Compose file for
deploying the native-networking stack on the Oracle host.  It is **not** used by
Railway — copy it to `/opt/tailscale-stack/docker-compose.yml` on the Oracle host.

### Architecture

```
Oracle host
    ↓
Tailscale container (TS_USERSPACE=false, NET_ADMIN, /dev/net/tun)
    ↓
real tailscale0 kernel interface (100.x.x.x)
    ↓
code-server (network_mode: "service:tailscale" — shares Tailscale namespace)
    ↓
Oracle host routing / policy tables
    ↓
AirVPN WireGuard (wg0)
    ↓
Internet
```

### Deployment steps

#### 1 — Install Docker Engine on the Oracle host

```sh
# Add the official Docker APT repository (Ubuntu)
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Verify
docker --version
docker compose version
systemctl is-active docker
```

Do **not** install Docker Desktop.  Do **not** alter WireGuard or Tailscale host
config during this step.

#### 2 — Capture baseline snapshot

Before starting any containers, save the current network state:

```sh
{
  echo "=== ip route ===" && ip route
  echo "=== ip rule ===" && ip rule
  echo "=== ip -4 route ===" && ip -4 route
  echo "=== ip -4 rule ===" && ip -4 rule
  echo "=== ip -6 route ===" && ip -6 route
  echo "=== ip -6 rule ===" && ip -6 rule
  echo "=== wg show ===" && wg show
  echo "=== iptables-save ===" && sudo iptables-save
  echo "=== iptables mangle ===" && sudo iptables -t mangle -S
  echo "=== iptables nat ===" && sudo iptables -t nat -S
  echo "=== iptables filter ===" && sudo iptables -S
  echo "=== tailscale status ===" && tailscale status
  echo "=== tailscale ip ===" && tailscale ip
  echo "=== systemctl tailscaled ===" && systemctl status tailscaled
  echo "=== systemctl wg-quick@airvpn ===" && systemctl status wg-quick@airvpn
  echo "=== /dev/net/tun ===" && ls -l /dev/net/tun
  echo "=== ip_forward ===" && sysctl net.ipv4.ip_forward
  echo "=== ipv6 forwarding ===" && sysctl net.ipv6.conf.all.forwarding
} | sudo tee /root/pre-docker-baseline.txt
```

#### 3 — Prepare directories and env file

```sh
sudo mkdir -p /opt/tailscale-stack/{state,coder-home,workspace}
sudo chown -R 1000:1000 /opt/tailscale-stack/coder-home \
                         /opt/tailscale-stack/workspace

# Copy the reference Compose file
sudo cp docker-compose.oracle.yml /opt/tailscale-stack/docker-compose.yml

# Create the .env file
sudo tee /opt/tailscale-stack/.env <<'EOF'
# Use a ONE-OFF pre-auth key (generate with "Ephemeral" unticked and the key
# marked as one-time-use). TS_AUTH_ONCE=true in the Compose file reuses the
# persisted node state on restart, so the key is only consumed once. A reusable
# key would let an .env leak enroll additional nodes until the key expires.
TS_AUTHKEY=tskey-auth-REPLACE_ME
TS_HOSTNAME=oracle-ts
CODE_SERVER_PASSWORD=
# tailscale up/set flags (example: --advertise-exit-node)
TS_EXTRA_ARGS=
# tailscaled daemon flags (optional)
TS_TAILSCALED_EXTRA_ARGS=
EOF
sudo chmod 600 /opt/tailscale-stack/.env

# Fill in the real auth key and a non-empty code-server password before startup.
sudoedit /opt/tailscale-stack/.env
sudo grep -Eq '^CODE_SERVER_PASSWORD=.+$' /opt/tailscale-stack/.env \
  || { echo "ERROR: CODE_SERVER_PASSWORD is not set in .env"; exit 1; }
```

#### 4 — SSH-safe handoff to containerized Tailscale, then start it

```sh
# If this SSH session is over tailscale0, reconnect via public IP/console first.
SSH_SRC_IP="$(echo "$SSH_CLIENT" | awk '{print $1}')"
if [ -n "$SSH_SRC_IP" ] && ip -o route get "$SSH_SRC_IP" 2>/dev/null | grep -q ' dev tailscale0 '; then
  echo "SSH is currently over tailscale0; reconnect via public IP/console before continuing."
  exit 1
fi

# Stop host tailscaled so containerized tailscaled can own tailscale0 and routes.
sudo systemctl disable --now tailscaled 2>/dev/null || true

cd /opt/tailscale-stack
sudo docker compose up -d tailscale
sudo docker compose logs -f tailscale   # wait for "Startup complete, waiting for shutdown signal"

# Verify a real kernel interface exists
sudo docker exec tailscale ip addr show tailscale0
sudo docker exec tailscale tailscale status
sudo docker exec tailscale tailscale ip
```

Configure this Oracle node to advertise exit-node capability:

```sh
sudo docker exec tailscale tailscale set --advertise-exit-node

# Persist via TS_EXTRA_ARGS in .env for restarts:
# TS_EXTRA_ARGS=--advertise-exit-node
```

Approve the exit-node advertisement in the Tailnet admin console.

#### 5 — Restrict code-server port before startup

Because both containers use host networking, code-server port 8080 binds on all
host interfaces. Install a persistent firewall guard before starting
code-server:

```sh
# Install persistent netfilter helpers once (Debian/Ubuntu example).
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent

# Allow only connections arriving on tailscale0
sudo iptables -C INPUT -p tcp --dport 8080 ! -i tailscale0 -j DROP 2>/dev/null \
  || sudo iptables -I INPUT -p tcp --dport 8080 ! -i tailscale0 -j DROP

# Persist it before the first code-server start or reboot.
sudo netfilter-persistent save
sudo systemctl enable netfilter-persistent

# Verify the DROP guard is present.
sudo iptables -S INPUT | grep -- '--dport 8080'
```

#### 6 — Start code-server

```sh
cd /opt/tailscale-stack
sudo docker compose up -d code-server
sudo docker compose logs -f code-server
```

#### 7 — Verify end-to-end traffic from inside code-server

```sh
# `code-server` shares `tailscale` netns; inspect routes from tailscale image.
sudo docker exec tailscale ip addr show tailscale0
sudo docker exec tailscale ip rule show
sudo docker exec tailscale ip route show table 52

sudo docker exec code-server curl -4 https://ifconfig.me
sudo docker exec code-server curl -4 https://icanhazip.com
sudo docker exec code-server curl -4 https://api.ipify.org
```

All three `curl` results must return the current **AirVPN public IPv4**.

**IPv6 egress must also be verified.** On an IPv6-enabled Oracle host,
`curl` (and code-server) may prefer IPv6 and bypass AirVPN over the host's
public IPv6 route even when IPv4 is correctly routed. Confirm AirVPN routes
IPv6 as well — if it does not, block or disable non-VPN IPv6 egress before
declaring success:

```sh
# Must return the AirVPN IPv6 (or fail/empty if AirVPN is IPv4-only)
sudo docker exec code-server curl -6 https://ifconfig.me
sudo docker exec code-server curl -6 https://api.ipify.org
```

If the IPv6 result is **not** an AirVPN egress address (e.g. it returns the
Oracle host's public IPv6, or times out while the host has a public IPv6 route),
AirVPN is not routing `::/0`. In that case disable IPv6 on the shared network
path so code-server cannot leak traffic outside the VPN:

```sh
# Disable IPv6 on the shared namespace so non-VPN IPv6 cannot bypass AirVPN.
sudo docker exec tailscale sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo docker exec tailscale sysctl -w net.ipv6.conf.default.disable_ipv6=1
# Persist the setting for reboots (systemd-sysctl):
echo 'net.ipv6.conf.all.disable_ipv6=1' | sudo tee /etc/sysctl.d/90-disable-ipv6-leak.conf
echo 'net.ipv6.conf.default.disable_ipv6=1' | sudo tee -a /etc/sysctl.d/90-disable-ipv6-leak.conf
sudo sysctl --system
```

Re-run the `curl -6` checks after applying one of the above. The deployment is
only complete when **both** IPv4 and IPv6 egress from code-server resolve to
AirVPN addresses, or IPv6 is explicitly disabled so no non-VPN IPv6 route exists.

Also verify Oracle's own AirVPN path is intact:

```sh
curl -4 https://ifconfig.me   # must return AirVPN egress IP
wg show                        # must show active handshake
```

#### 8 — Firewall audit post-Docker

After Docker is running, inspect and protect the existing rules:

```sh
sudo iptables-save
sudo iptables -t nat -S
sudo iptables -t mangle -S
```

If Docker's `DOCKER-USER` chain needs to permit Tailscale traffic:

```sh
# Allow traffic from/to tailscale0 in DOCKER-USER (idempotent)
sudo iptables -C DOCKER-USER -i tailscale0 -j ACCEPT 2>/dev/null \
  || sudo iptables -I DOCKER-USER -i tailscale0 -j ACCEPT
sudo iptables -C DOCKER-USER -o tailscale0 -j ACCEPT 2>/dev/null \
  || sudo iptables -I DOCKER-USER -o tailscale0 -j ACCEPT
```

Do **not** flush or overwrite existing WireGuard rules.

#### 9 — Install reboot-safe startup orchestration

`depends_on: condition: service_healthy` only orders `docker compose up`.
After a daemon or host reboot, start `tailscale` first and recreate
`code-server` from the host once Tailscale is healthy:

```sh
sudo tee /etc/systemd/system/tailscale-stack.service <<'EOF'
[Unit]
Description=Start Oracle Tailscale stack in safe order
After=docker.socket
After=docker.service
Wants=docker.socket
Requires=docker.service
# Propagate Docker restarts to this unit. `Requires=` stops this unit when
# Docker is explicitly stopped, but restarting Docker does not pull an
# already-stopped dependent unit back in. `PartOf=` makes `systemctl restart
# docker` (and Docker's own restart) also restart this unit, so code-server
# (which has no restart policy) comes back up with a fresh network namespace.
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=210
WorkingDirectory=/opt/tailscale-stack
ExecStart=/bin/sh -c "set -e; /usr/bin/docker compose up -d tailscale; i=0; until [ \"$$(/usr/bin/docker inspect --format='{{.State.Health.Status}}' tailscale 2>/dev/null)\" = healthy ]; do i=$$((i+1)); if [ $$i -ge 90 ]; then echo 'tailscale did not become healthy within 180 seconds' >&2; exit 1; fi; sleep 2; done; /usr/bin/docker compose up -d --force-recreate code-server"

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable tailscale-stack.service
sudo systemctl start tailscale-stack.service
```

The boot unit above only runs once at startup. Because `code-server` has
`restart: "no"`, a crash after boot leaves the service down. Add a supervised
runtime recovery mechanism — a health-aware systemd timer — that force-recreates
`code-server` whenever Tailscale is healthy but code-server is not running (or
its shared network namespace has gone stale):

```sh
sudo tee /etc/systemd/system/tailscale-stack-recover.service <<'EOF'
[Unit]
Description=Recreate code-server if Tailscale is healthy but code-server is down
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
WorkingDirectory=/opt/tailscale-stack
# Only act when tailscale is healthy and code-server is missing or its netns is stale.
ExecStart=/bin/sh -c 'set -e; ts="$$(/usr/bin/docker inspect --format={{.State.Health.Status}} tailscale 2>/dev/null || true)"; [ "$$ts" = healthy ] || exit 0; if /usr/bin/docker inspect --format={{.State.Running}} code-server 2>/dev/null | grep -q true; then exit 0; fi; /usr/bin/docker compose up -d --force-recreate code-server'
EOF

sudo tee /etc/systemd/system/tailscale-stack-recover.timer <<'EOF'
[Unit]
Description=Run code-server runtime recovery check periodically

[Timer]
OnBootSec=3min
OnUnitActiveSec=1min
Unit=tailscale-stack-recover.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-stack-recover.timer
```

The timer runs the recovery service every minute once the boot unit has
finished. If `tailscale` becomes healthy and `code-server` is down (crash,
manual stop, or a stale namespace after `docker compose restart tailscale`),
it force-recreates `code-server` automatically.

#### 10 — Persistence test

```sh
# Restart Tailscale. code-server's network namespace becomes stale, so the
# recovery timer force-recreates it automatically once tailscale is healthy.
# To recover immediately instead of waiting for the timer:
sudo docker compose restart tailscale
sudo docker compose up -d --force-recreate code-server
sudo docker exec code-server curl -4 https://ifconfig.me  # still AirVPN IP

# Full reboot test (confirm SSH safety first)
# tailscale-stack.service replays the safe startup order after Docker is ready
sudo reboot
```

After the host comes back up, reconnect over SSH, then run:

```sh
sudo systemctl status tailscale-stack.service --no-pager
systemctl status tailscale-stack-recover.timer --no-pager
cd /opt/tailscale-stack
sudo docker compose ps   # wait until tailscale is healthy and code-server is running
sudo docker exec code-server curl -4 https://ifconfig.me
```

### Acceptance criteria

The deployment is successful **only when**:

```
ACTUAL CODE-SERVER PUBLIC IP == ACTUAL AIRVPN PUBLIC IP
```

for **both** address families (or IPv6 is explicitly disabled as described in
step 7), with:
- **NO** SOCKS proxy
- **NO** HTTP/HTTPS proxy
- **REAL** `/dev/net/tun` TUN interface
- **REAL** `tailscale0` kernel interface visible inside code-server
- **REAL** Layer-3 routing through AirVPN WireGuard
