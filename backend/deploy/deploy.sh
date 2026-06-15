#!/usr/bin/env bash
# =============================================================================
# VibeCode Backend — Deployment Script
# Run this ON the GCP VM (not locally).
#
# Usage:
#   1. Copy the entire backend/ directory to /opt/vibecode/ on the VM
#   2. Create /opt/vibecode/.env with your credentials
#   3. Run: sudo bash /opt/vibecode/deploy/deploy.sh
# =============================================================================

set -euo pipefail

APP_DIR="/opt/vibecode"
VENV_DIR="$APP_DIR/.venv"
ENV_FILE="$APP_DIR/.env"
SERVICE_FILE="/etc/systemd/system/vibecode.service"

echo "=== VibeCode Deployment ==="

# --- Prerequisites check ---
echo "[1/6] Checking prerequisites..."
if ! command -v uv &>/dev/null; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found. Install Python 3.11+ first."
    exit 1
fi

PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "  Python $PY_VERSION detected"

# --- User setup ---
echo "[2/6] Setting up vibecode user..."
if ! id vibecode &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin vibecode
    echo "  Created vibecode system user"
fi

# --- Directory setup ---
echo "[3/6] Setting up directories..."
mkdir -p "$APP_DIR/data"
chown -R vibecode:vibecode "$APP_DIR"
chmod 755 "$APP_DIR"
chmod 755 "$APP_DIR/data"

# --- Check .env ---
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found!"
    echo "  Copy .env.example to .env and fill in your credentials:"
    echo "  cp $APP_DIR/.env.example $ENV_FILE"
    exit 1
fi
echo "  .env file found"

# --- Install dependencies ---
echo "[4/6] Installing Python dependencies..."
cd "$APP_DIR"
uv sync --frozen 2>/dev/null || uv sync
chown -R vibecode:vibecode "$VENV_DIR"

# --- Install systemd service ---
echo "[5/6] Installing systemd service..."
cp "$APP_DIR/deploy/vibecode.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable vibecode.service
echo "  Service installed and enabled"

# --- Start service ---
echo "[6/6] Starting VibeCode backend..."
systemctl restart vibecode.service
sleep 3

# --- Verify ---
if systemctl is-active --quiet vibecode.service; then
    echo ""
    echo "=== Deployment Complete! ==="
    echo ""
    echo "Service status: $(systemctl is-active vibecode.service)"
    echo ""
    echo "Verify it's working:"
    echo "  curl http://localhost:8080/api/health"
    echo ""
    echo "View logs:"
    echo "  journalctl -u vibecode -f"
else
    echo "ERROR: Service failed to start!"
    echo "Check logs: journalctl -u vibecode -n 50"
    exit 1
fi
