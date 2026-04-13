#!/usr/bin/env bash
#
# Post-installimage bootstrap for Hetzner AX102-U.
# Sets up Docker, Caddy, firewall, Storage Box mount, and WatchAI server.
#
# Usage (as root on the freshly installed server):
#   curl -sL https://raw.githubusercontent.com/<repo>/main/Server/deploy/setup.sh | bash
#   — or —
#   scp setup.sh root@<ip>:/tmp/ && ssh root@<ip> bash /tmp/setup.sh
#
set -euo pipefail

# ---------- 0. Config — edit these before running ----------

STORAGEBOX_USER="${STORAGEBOX_USER:-}"     # e.g. u123456
STORAGEBOX_HOST="${STORAGEBOX_HOST:-}"     # e.g. u123456.your-storagebox.de
DOMAIN="${DOMAIN:-}"                       # e.g. watchai.yourdomain.com (leave blank to skip TLS)

# ---------- 1. System basics ----------

echo "==> Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -y -q
apt-get install -y -q \
  curl wget git unzip jq htop tmux \
  cifs-utils nfs-common \
  ufw fail2ban \
  python3-venv python3-pip ffmpeg espeak-ng

# ---------- 2. Docker ----------

echo "==> Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# ---------- 3. Caddy ----------

echo "==> Installing Caddy..."
if ! command -v caddy &>/dev/null; then
  apt-get install -y -q debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt-get install -y -q caddy
fi
systemctl enable caddy

# ---------- 4. Directory structure ----------

echo "==> Creating directories..."
mkdir -p /data/{watchai,ot-bridge,zim-workspace,zim-archive,backups,models}
chmod 700 /data

# ---------- 5. Firewall ----------

echo "==> Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp    # HTTP (Caddy redirect)
ufw allow 443/tcp   # HTTPS (Caddy)
ufw --force enable

# ---------- 6. Storage Box mount (optional) ----------

if [[ -n "$STORAGEBOX_USER" && -n "$STORAGEBOX_HOST" ]]; then
  echo "==> Mounting Storage Box..."
  CREDS_FILE="/etc/storagebox-creds"
  if [[ ! -f "$CREDS_FILE" ]]; then
    read -rsp "Storage Box password: " SB_PASS; echo
    cat > "$CREDS_FILE" <<CREDS
username=$STORAGEBOX_USER
password=$SB_PASS
CREDS
    chmod 600 "$CREDS_FILE"
  fi

  MOUNT_POINT="/mnt/storagebox"
  mkdir -p "$MOUNT_POINT"
  if ! grep -q "$STORAGEBOX_HOST" /etc/fstab; then
    echo "//$STORAGEBOX_HOST/backup $MOUNT_POINT cifs credentials=$CREDS_FILE,iocharset=utf8,uid=0,gid=0,_netdev 0 0" >> /etc/fstab
  fi
  mount -a || echo "WARNING: Storage Box mount failed — check credentials and network."
  echo "   Mounted at $MOUNT_POINT"
else
  echo "==> Skipping Storage Box (STORAGEBOX_USER not set)."
fi

# ---------- 7. WatchAI server ----------

echo "==> Setting up WatchAI..."
WATCHAI_DIR="/data/watchai"

# Clone or copy — adjust URL to your repo
if [[ ! -d "$WATCHAI_DIR/Server" ]]; then
  echo "   Place your Server/ directory at $WATCHAI_DIR/Server"
  echo "   e.g.: scp -r Server/ root@<ip>:$WATCHAI_DIR/"
fi

# Create .env template if missing
if [[ ! -f "$WATCHAI_DIR/.env" ]]; then
  cat > "$WATCHAI_DIR/.env" <<'ENV'
GOOGLE_API_KEY=your-gemini-key-here
ACCESS_KEY=your-shared-access-key-here
PORT=8333
HOST=0.0.0.0
DEVICE=cpu
ENV
  echo "   Created $WATCHAI_DIR/.env — edit with real keys before starting."
fi

# ---------- 8. CPU Dockerfile ----------

# Build from the CPU Dockerfile (no CUDA)
if [[ -f "$WATCHAI_DIR/Server/deploy/Dockerfile.cpu" ]]; then
  echo "   Building WatchAI Docker image..."
  docker build -t watchai-server -f "$WATCHAI_DIR/Server/deploy/Dockerfile.cpu" "$WATCHAI_DIR/Server/"
fi

# ---------- 9. Docker Compose for WatchAI ----------

if [[ ! -f "$WATCHAI_DIR/docker-compose.yml" ]]; then
  cat > "$WATCHAI_DIR/docker-compose.yml" <<'COMPOSE'
services:
  watchai-server:
    image: watchai-server
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:8333:8333"
    volumes:
      - /data/models:/root/.cache/huggingface
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8333/health')"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
COMPOSE
  echo "   Created $WATCHAI_DIR/docker-compose.yml"
fi

# ---------- 10. Caddy reverse proxy ----------

echo "==> Configuring Caddy..."

if [[ -n "$DOMAIN" ]]; then
  CADDY_SITE="$DOMAIN"
else
  CADDY_SITE=":443"
  echo "   No DOMAIN set — Caddy will use self-signed TLS on :443."
fi

cat > /etc/caddy/Caddyfile <<CADDY
# WatchAI — reverse proxy to Docker container
$CADDY_SITE {
    reverse_proxy /health localhost:8333
    reverse_proxy /v1/* localhost:8333 {
        flush_interval -1
        transport http {
            read_timeout 120s
        }
    }

    # Block everything else
    respond "Not found" 404
}
CADDY

systemctl reload caddy
echo "   Caddy configured for $CADDY_SITE -> localhost:8333"

# ---------- 11. Backup cron ----------

echo "==> Setting up backup cron..."
cat > /etc/cron.daily/watchai-backup <<'CRON'
#!/bin/bash
# Daily backup of WatchAI .env and server config
BACKUP_DIR="/data/backups/watchai"
mkdir -p "$BACKUP_DIR"
DATE=$(date +%Y-%m-%d)
tar czf "$BACKUP_DIR/watchai-config-$DATE.tar.gz" \
  /data/watchai/.env \
  /data/watchai/docker-compose.yml \
  /etc/caddy/Caddyfile \
  2>/dev/null

# Prune backups older than 30 days
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +30 -delete

# Copy to Storage Box if mounted
if mountpoint -q /mnt/storagebox; then
  rsync -a "$BACKUP_DIR/" /mnt/storagebox/watchai-backups/
fi
CRON
chmod +x /etc/cron.daily/watchai-backup

# ---------- 12. Pre-download models ----------

echo "==> Pre-downloading ML models (this takes a few minutes)..."
docker run --rm \
  -v /data/models:/root/.cache/huggingface \
  -e DEVICE=cpu \
  watchai-server \
  python3 -c "
from faster_whisper import WhisperModel
from kokoro import KPipeline
print('Loading Whisper distil-small.en...')
WhisperModel('distil-small.en', device='cpu', compute_type='int8')
print('Loading Kokoro...')
KPipeline(lang_code='a')
print('Models cached.')
" 2>&1 || echo "   Model pre-download will happen on first request."

# ---------- Done ----------

echo ""
echo "============================================"
echo "  Setup complete."
echo ""
echo "  Next steps:"
echo "    1. Copy Server/ to $WATCHAI_DIR/Server/"
echo "    2. Edit $WATCHAI_DIR/.env with real API keys"
echo "    3. Build image:  docker build -t watchai-server -f $WATCHAI_DIR/Server/deploy/Dockerfile.cpu $WATCHAI_DIR/Server/"
echo "    4. Start:        cd $WATCHAI_DIR && docker compose up -d"
echo "    5. Verify:       curl -s https://localhost/health -k | jq"
echo ""
echo "  For Open Testimony:"
echo "    Clone to /data/ot-bridge/ and follow its deploy/vm/install.sh"
echo "    Add reverse_proxy block to /etc/caddy/Caddyfile for OT's domain"
echo ""
echo "  For ZIM builds:"
echo "    Use /data/zim-workspace/ for builds"
echo "    Archive finished ZIMs to /mnt/storagebox/ or /data/zim-archive/"
echo "============================================"
