# Docker + Tailscale Hosting Setup

Run OpenClaw gateway in Docker on an ARM64 VPS, accessible only via Tailscale.

## Architecture

```
Mac (100.88.34.56)  ──Tailscale──▶  VPS (100.103.2.5:18789)
                                        │
                                    Docker port map
                                        │
                                    Container (0.0.0.0:18789)
                                    └── OpenClaw Gateway
```

- Tailscale runs on the **host**, not inside the container.
- Docker binds ports to the host's Tailscale IP only — no firewall rules needed.
- The gateway's built-in Tailscale mode (`tailscale.mode`) stays `"off"`.

## Prerequisites

- ARM64 or x86_64 Linux VPS (tested on Hetzner ARM64)
- Docker Engine + Docker Compose v2
- Tailscale installed and authenticated on the VPS
- Tailscale installed on your Mac/client devices

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/miaekim/openclaw.git
cd openclaw
```

Create `.env` from the template:

```bash
cp .env.example .env
```

Edit `.env`:

```env
OPENCLAW_IMAGE=openclaw:latest
OPENCLAW_GATEWAY_TOKEN=<generate-a-strong-token>
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=18789
TAILSCALE_IP=<your-vps-tailscale-ip>

OPENCLAW_CONFIG_DIR=/root/.openclaw
OPENCLAW_WORKSPACE_DIR=/root/.openclaw/workspace

GOG_KEYRING_PASSWORD=<your-password>
XDG_CONFIG_HOME=/home/node/.openclaw

CLAUDE_AI_SESSION_KEY=
CLAUDE_WEB_SESSION_KEY=
CLAUDE_WEB_COOKIE=
```

Find your Tailscale IP:

```bash
tailscale ip -4
```

### 2. Build the image

```bash
docker compose build
```

This installs bundled skill binaries (gogcli, goplaces, summarize, oracle, mcporter, vox) at build time.

### 3. Run the onboarding wizard

```bash
docker compose run --rm openclaw-cli onboard
```

### 4. Fix gateway bind

The onboard wizard sets `gateway.bind` to `loopback` in the config file. Change it to `lan` so the container accepts connections from Docker's port mapping:

```bash
docker compose run --rm openclaw-cli config set gateway.bind lan
```

### 5. Start the gateway

```bash
docker compose up -d openclaw-gateway
```

### 6. Verify

From the VPS:

```bash
curl -s http://<TAILSCALE_IP>:18789
```

From your Mac:

```bash
curl -s http://<TAILSCALE_IP>:18789
```

Both should return the OpenClaw Control UI HTML.

Open in browser: `http://<TAILSCALE_IP>:18789`

## File layout

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `~/.openclaw/` | `/home/node/.openclaw/` | Config, sessions, credentials (persisted via volume) |
| `~/.openclaw/workspace/` | `/home/node/.openclaw/workspace/` | Agent workspace (persisted via volume) |
| `~/.openclaw/openclaw.json` | `/home/node/.openclaw/openclaw.json` | Gateway config file |

All data persists across container restarts and rebuilds since it lives on the host via bind mounts.

## Common commands

```bash
# Rebuild after Dockerfile changes
docker compose build

# Restart gateway
docker compose restart openclaw-gateway

# View logs
docker compose logs -f openclaw-gateway

# Run CLI commands
docker compose run --rm openclaw-cli <command>

# Health check
docker compose exec openclaw-gateway node dist/index.js health --token "$OPENCLAW_GATEWAY_TOKEN"

# Set config values
docker compose run --rm openclaw-cli config set <key> <value>

# Add Telegram channel
docker compose run --rm openclaw-cli channels add --channel telegram --token "<bot-token>"

# Install a skill (uses npm inside container)
docker compose run --rm openclaw-cli skills install <skill-name>
```

## Bundled skill binaries

Installed at build time in the Docker image:

| Binary | Description |
|--------|-------------|
| `gog` | Google Suite CLI (Gmail, GCal, GDrive, GContacts) |
| `goplaces` | Google Places CLI |
| `summarize` | Summarize URLs, YouTube, podcasts, files |
| `oracle` | Query LLMs with custom context and files |
| `mcporter` | MCP server runtime and CLI |
| `vox` | Agent phone call tool |

## Security

This setup has three layers of network isolation:

1. **Tailscale IP binding** — Docker binds the gateway port to the Tailscale interface only (`100.x.x.x`), not `0.0.0.0`. The port is invisible on the VPS's public IP. No firewall rules required.

2. **Tailscale authentication** — Only devices on your tailnet can reach the Tailscale IP. Access requires a device authenticated with your Tailscale account.

3. **Gateway token** — The gateway requires `OPENCLAW_GATEWAY_TOKEN` for WebSocket and API access. Even within your tailnet, unauthenticated requests are rejected.

### Verify port is not public

```bash
# Should show your Tailscale IP, NOT 0.0.0.0
docker ps --format '{{.Ports}}'
# Expected: 100.103.2.5:18789->18789/tcp
```

```bash
# Should fail/timeout from outside your tailnet
curl --connect-timeout 3 http://<PUBLIC_VPS_IP>:18789
```

### What to avoid

- Do not remove the `TAILSCALE_IP` variable from `docker-compose.yml` ports — this falls back to `0.0.0.0` (public).
- Do not set `TAILSCALE_IP=0.0.0.0` — this exposes the port on all interfaces.
- Do not set `gateway.tailscale.mode` to anything other than `"off"` — the host handles Tailscale, not the container.
- Keep `.env` out of version control (it's gitignored by default) — it contains tokens and credentials.

### Container hardening

- The container runs as non-root user `node` (uid 1000).
- `init: true` ensures proper signal handling and zombie process reaping.
- `NODE_ENV=production` disables development-mode debugging.

### Tailscale HTTPS (Control UI access)

The gateway requires HTTPS or localhost for browser WebSocket connections. Tailscale provides free HTTPS certs for your tailnet hostname.

**One-time setup:**

1. Enable HTTPS in Tailscale admin: https://login.tailscale.com/admin/dns → HTTPS Certificates → Enable
   (Note: your machine name will be published in a public Certificate Transparency log)
2. Generate certs on the VPS:
   ```bash
   tailscale cert <hostname>.<tailnet>.ts.net
   ```
3. Copy certs into the OpenClaw config dir:
   ```bash
   mkdir -p ~/.openclaw/gateway/tls
   cp <hostname>.<tailnet>.ts.net.crt ~/.openclaw/gateway/tls/cert.pem
   cp <hostname>.<tailnet>.ts.net.key ~/.openclaw/gateway/tls/key.pem
   chown -R 1000:1000 ~/.openclaw/gateway/tls
   chmod 600 ~/.openclaw/gateway/tls/key.pem
   ```
4. Add TLS config to `~/.openclaw/openclaw.json` under `gateway`:
   ```json
   "tls": {
     "enabled": true,
     "certPath": "/home/node/.openclaw/gateway/tls/cert.pem",
     "keyPath": "/home/node/.openclaw/gateway/tls/key.pem",
     "autoGenerate": false
   }
   ```
5. Restart: `docker compose up -d openclaw-gateway --force-recreate`
6. Verify logs show `wss://` (not `ws://`):
   ```bash
   docker logs openclaw-openclaw-gateway-1 | grep listening
   ```

**Access the Control UI:**

```
https://<hostname>.<tailnet>.ts.net:18789/#token=<your-gateway-token>
```

No SSH tunnel needed.

**Device pairing note:** The gateway's device pairing doesn't work well in a headless Docker setup (chicken-and-egg: no device is paired to approve new devices). Add this to `~/.openclaw/openclaw.json` under `gateway`:

```json
"controlUi": {
  "dangerouslyDisableDeviceAuth": true
}
```

This is safe because the port is only reachable via Tailscale (authenticated + encrypted) and the gateway token is still required.

## Setting up gog (Google Suite CLI)

`gog` is baked into the Docker image but needs Google OAuth credentials and authentication.

### 1. Create Google Cloud OAuth credentials

1. Go to https://console.cloud.google.com/ and create a project (free)
2. Go to **APIs & Services > OAuth consent screen** — choose "External", fill in app name and your email
3. Under **Test users**, add your Gmail address
4. Go to **APIs & Services > Library** — enable: Gmail API, Google Calendar API, Google Drive API, Google Contacts API
5. Go to **APIs & Services > Credentials** > **Create Credentials > OAuth client ID** — type: **Desktop app**
6. Download the credentials JSON

### 2. Load credentials into gog

```bash
# Copy the JSON to a persistent path on the host
cp ~/Downloads/client_secret_*.json ~/.openclaw/credentials/google-oauth.json

# Load into gog inside the container
docker cp ~/.openclaw/credentials/google-oauth.json openclaw-openclaw-gateway-1:/tmp/google-oauth.json
docker exec openclaw-openclaw-gateway-1 gog auth credentials /tmp/google-oauth.json
```

### 3. Authenticate with Google

The `gog auth login` flow starts an HTTP server inside the container on a random port. Since you're remote, you need to proxy that port to your Tailscale IP.

```bash
# Start auth (note the port it prints)
docker exec openclaw-openclaw-gateway-1 gog auth login
# Output: If the browser doesn't open, visit: http://127.0.0.1:<PORT>
```

In a second VPS terminal, proxy the port (replace `<PORT>` with the actual port):

```bash
# Bridge inside container: loopback -> external
docker exec -d openclaw-openclaw-gateway-1 socat TCP-LISTEN:39999,fork,reuseaddr TCP:127.0.0.1:<PORT>

# Proxy to Tailscale IP on host
CONTAINER_IP=$(docker inspect openclaw-openclaw-gateway-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
socat TCP-LISTEN:<PORT>,fork,reuseaddr,bind=<TAILSCALE_IP> TCP:$CONTAINER_IP:39999
```

Open `http://<TAILSCALE_IP>:<PORT>` on your Mac and complete Google login.

**Important:** After Google authorization, the browser redirects to `http://127.0.0.1:<PORT>/oauth2/callback?code=...`. This will fail because your Mac isn't the VPS. Copy the full URL from the browser address bar, replace `127.0.0.1` with your Tailscale IP, and hit enter.

### 4. Verify

```bash
docker exec openclaw-openclaw-gateway-1 gog gmail list --max 3
```

### 5. Cleanup

Kill the socat proxies after auth is complete:

```bash
pkill -f "socat TCP-LISTEN" 2>/dev/null
docker exec openclaw-openclaw-gateway-1 pkill -f "socat" 2>/dev/null
```

## Troubleshooting

### "gateway closed (1006 abnormal closure)"

The gateway is binding to `loopback` inside the container. Fix:

```bash
docker compose run --rm openclaw-cli config set gateway.bind lan
docker compose restart openclaw-gateway
```

### Dashboard link shows 127.0.0.1

The gateway generates URLs using its bind address. Replace `127.0.0.1` with your Tailscale IP in the browser URL bar.

### Container can't reach Tailscale IP

Tailscale runs on the host, not in the container. The container doesn't need Tailscale — Docker's port mapping handles it. Verify with:

```bash
docker ps  # should show <TAILSCALE_IP>:18789->18789/tcp
```

### Permission errors (EACCES)

The container runs as `node` (uid 1000). Fix host directory ownership:

```bash
sudo chown -R 1000:1000 ~/.openclaw
```

### Config not taking effect

The config file (`~/.openclaw/openclaw.json`) can override CLI flags. Check current values:

```bash
cat ~/.openclaw/openclaw.json | grep -A2 bind
```
