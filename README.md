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
Tailscale exit node (Oracle/AirVPN identity)
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
TS_AUTHKEY=tskey-auth-REPLACE_ME
TS_HOSTNAME=oracle-ts
CODE_SERVER_PASSWORD=REPLACE_ME
TS_EXTRA_ARGS=
EOF
sudo chmod 600 /opt/tailscale-stack/.env
```

#### 4 — Start Tailscale container and discover exit node

```sh
cd /opt/tailscale-stack
sudo docker compose up -d tailscale
sudo docker compose logs -f tailscale   # wait for "Tailscale is up"

# Verify a real kernel interface exists
sudo docker exec tailscale ip addr show tailscale0
sudo docker exec tailscale tailscale status
sudo docker exec tailscale tailscale ip
```

Find the current Oracle/AirVPN exit node Tailscale IP:

```sh
sudo docker exec tailscale tailscale status
# Note the IP of the node that advertises exit-node (e.g. 100.x.x.x)
# Confirm it is approved in the Tailnet admin console.
```

Set the exit node (replace `100.x.x.x` with the discovered IP):

```sh
sudo docker exec tailscale tailscale set \
  --exit-node=100.x.x.x \
  --exit-node-allow-lan-access=true

# Persist via TS_EXTRA_ARGS in .env for restarts:
# TS_EXTRA_ARGS=--exit-node=100.x.x.x --exit-node-allow-lan-access=true
```

#### 5 — Start code-server

```sh
cd /opt/tailscale-stack
sudo docker compose up -d code-server
sudo docker compose logs -f code-server
```

#### 5b — Restrict code-server port to Tailscale interface only

Because both containers use host networking, code-server port 8080 binds on all
host interfaces.  Lock it down immediately after starting the stack:

```sh
# Allow only connections arriving on tailscale0
sudo iptables -C INPUT -p tcp --dport 8080 ! -i tailscale0 -j DROP 2>/dev/null \
  || sudo iptables -I INPUT -p tcp --dport 8080 ! -i tailscale0 -j DROP

# Persist the rule (Ubuntu/ufw example):
# sudo ufw deny 8080   # deny from everywhere
# sudo ufw allow in on tailscale0 to any port 8080
```

#### 6 — Verify end-to-end traffic from inside code-server

```sh
sudo docker exec code-server ip addr          # must show tailscale0
sudo docker exec code-server ip route         # must show Tailscale routes
sudo docker exec code-server curl -4 https://ifconfig.me
sudo docker exec code-server curl -4 https://icanhazip.com
sudo docker exec code-server curl -4 https://api.ipify.org
```

All three `curl` results must return the current **AirVPN public IPv4**.

Also verify Oracle's own AirVPN path is intact:

```sh
curl -4 https://ifconfig.me   # must return AirVPN egress IP
wg show                        # must show active handshake
```

#### 7 — Firewall audit post-Docker

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

#### 8 — Persistence test

```sh
# Restart Tailscale, then restart code-server so it rejoins the recreated
# network namespace.
sudo docker compose restart tailscale
sudo docker compose restart code-server
sudo docker exec code-server curl -4 https://ifconfig.me  # still AirVPN IP

# Full reboot test (confirm SSH safety first)
# Containers auto-restart because restart: unless-stopped
sudo reboot
# After the host comes back up, reconnect over SSH, then run:
cd /opt/tailscale-stack
sudo docker compose ps   # wait until tailscale is healthy and code-server is running
sudo docker exec code-server curl -4 https://ifconfig.me
```

### Acceptance criteria

The deployment is successful **only when**:

```
ACTUAL CODE-SERVER PUBLIC IP == ACTUAL AIRVPN PUBLIC IP
```

with:
- **NO** SOCKS proxy
- **NO** HTTP/HTTPS proxy
- **REAL** `/dev/net/tun` TUN interface
- **REAL** `tailscale0` kernel interface visible inside code-server
- **REAL** Layer-3 routing through AirVPN WireGuard
