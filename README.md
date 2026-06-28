# VibeCode — AI Coding Assistant for Android

Hello! 👋 Welcome to the VibeCode project.

Type prompts from your phone → OpenHands Cloud runs the AI agent → live stream + push notifications.

## Download

📱 **[app-debug.apk](https://github.com/Craftguy-Billies/as/releases/download/v1.0.0/app-debug.apk)** (142MB)

---

## VM Deploy — One Paste

Open browser SSH: https://ssh.cloud.google.com/v2/ssh/projects/project-4b96dcac-4086-496a-9ab/zones/us-central1-a/instances/coder-ai

Paste this entire block:

```bash
sudo apt update && sudo apt install -y python3 python3-pip python3-venv git && \
curl -LsSf https://astral.sh/uv/install.sh | sh && \
export PATH="$HOME/.local/bin:$PATH" && \
sudo rm -rf /opt/vibecode && \
sudo git clone https://github.com/Craftguy-Billies/as.git /opt/vibecode && \
sudo tee /opt/vibecode/.env << 'ENVEOF'
LLM_API_KEY=YOUR_DEEPSEEK_KEY
LLM_MODEL=deepseek-chat
LLM_BASE_URL=https://api.deepseek.com/v1
OPENHANDS_CLOUD_API_KEY=YOUR_OPENHANDS_KEY
FIREBASE_CREDENTIALS_PATH=/opt/vibecode/firebase-credentials.json
HOST=0.0.0.0
PORT=8080
ENVEOF
sudo bash /opt/vibecode/backend/deploy/deploy.sh
```

Replace `YOUR_DEEPSEEK_KEY` and `YOUR_OPENHANDS_KEY` with your actual keys.

Then upload `firebase-credentials.json` (gear ⚙️ → Upload file):
```bash
sudo mv ~/firebase-credentials.json /opt/vibecode/ && sudo systemctl restart vibecode
```

Verify:
```bash
curl http://localhost:8080/api/health
# → {"status":"ok","model":"deepseek-chat","version":"1.0.0"}
curl http://34.44.82.227:8080/api/health  # test from internet
```

**Firewall** (if port 8080 blocked): GCP Console → VPC network → Firewall → CREATE FIREWALL RULE:
Name: `allow-vibecode` | Targets: All instances | Source: `0.0.0.0/0` | TCP: `8080`

---

## App — Zero Typing

Server URL is hardcoded to `http://34.44.82.227:8080`. Open app → auto-connects → Home screen.
If server unreachable → shows Retry + link to Settings where URL can be changed.

---

## API

| Method | Endpoint |
|--------|----------|
| `GET` | `/api/health` |
| `POST` | `/api/prompts` |
| `GET` | `/api/tasks` |
| `GET` | `/api/tasks/{id}` |
| `DELETE` | `/api/tasks/{id}` |
| `GET` | `/api/tasks/{id}/events` |
| `POST` | `/api/fcm-token` |
| `PUT` | `/api/config/llm` |
| `GET` | `/api/config/llm` |

## Service

```bash
systemctl status vibecode
systemctl restart vibecode
journalctl -u vibecode -f
```
