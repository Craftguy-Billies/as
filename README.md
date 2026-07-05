# VibeCode — AI Coding Assistant for Android

Type prompts from your phone → AI agent runs on OpenHands Cloud → live stream + push notifications.

## Downloads

📱 **[Download APK](https://github.com/Craftguy-Billies/as/releases/download/v1.0.0/app-debug.apk)** (142MB)

---

## VM Deploy — One Command

1. Open your browser SSH: https://ssh.cloud.google.com/v2/ssh/projects/project-4b96dcac-4086-496a-9ab/zones/us-central1-a/instances/coder-ai
2. **Paste this entire block into the terminal:**

```bash
# Clone repo && deploy
sudo apt update && sudo apt install -y python3 python3-pip python3-venv && \
curl -LsSf https://astral.sh/uv/install.sh | sh && source ~/.bashrc && \
sudo rm -rf /opt/vibecode && \
sudo git clone https://github.com/Craftguy-Billies/as.git /opt/vibecode && \

# Create .env with YOUR keys
sudo tee /opt/vibecode/.env << 'ENVEOF'
LLM_API_KEY=YOUR_DEEPSEEK_KEY
LLM_MODEL=deepseek-chat
LLM_BASE_URL=https://api.deepseek.com/v1
OPENHANDS_CLOUD_API_KEY=YOUR_OPENHANDS_KEY
FIREBASE_CREDENTIALS_PATH=/opt/vibecode/firebase-credentials.json
HOST=0.0.0.0
PORT=8080
ENVEOF

# Upload firebase-credentials.json (click gear icon in SSH window → Upload file)
# Then deploy
sudo bash /opt/vibecode/backend/deploy/deploy.sh
```

3. **Upload firebase-credentials.json**: Click the gear icon (⚙️) in the SSH window → "Upload file" → select `firebase-credentials.json` → uploads to `/home/YOUR_USER/`
4. **Move it**: `sudo mv ~/firebase-credentials.json /opt/vibecode/firebase-credentials.json`
5. **Run deploy**: `sudo bash /opt/vibecode/backend/deploy/deploy.sh`
6. **Verify**: `curl http://localhost:8080/api/health` → should return `{"status":"ok","model":"deepseek-chat","version":"1.0.0"}`
7. **Test from internet**: Open `http://34.44.82.227:8080/api/health` in your browser

> **Firewall note**: Make sure port 8080 is open. GCP Console → VPC network → Firewall → "CREATE FIREWALL RULE":
> - Name: `allow-vibecode`
> - Targets: All instances in the network
> - Source IP: `0.0.0.0/0`
> - TCP: `8080`
> - Create

---

## App Setup

1. Download APK from the link above (or `https://github.com/Craftguy-Billies/as/releases/latest`)
2. Install on your Android phone (allow "Unknown sources" if prompted)
3. Open VibeCode → the Setup screen appears
4. Enter server URL: `http://34.44.82.227:8080`
5. Tap **"Connect"** → green checkmark ✅ appears
6. App auto-navigates to Home screen
7. Enter a repo (e.g., `test/demo`) and prompt → tap send → watch live events!

---

## API Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/health` | Health check + current model |
| `POST` | `/api/prompts` | Submit a coding task |
| `GET` | `/api/tasks` | List all tasks (filterable by status) |
| `GET` | `/api/tasks/{id}` | Get single task details |
| `DELETE` | `/api/tasks/{id}` | Delete a queued/failed task |
| `GET` | `/api/tasks/{id}/events` | Get events with incremental polling |
| `POST` | `/api/fcm-token` | Register device for push notifications |
| `PUT` | `/api/config/llm` | Update LLM config at runtime |
| `GET` | `/api/config/llm` | View current LLM config (key hidden) |

---

## Service Management (on VM)

```bash
systemctl status vibecode          # Check if running
systemctl restart vibecode         # Restart
journalctl -u vibecode -f          # Live logs
curl http://localhost:8080/docs    # Swagger API docs
```

---

## Tech Stack

- **Frontend**: Flutter 3.38+ (Dart) — Provider, Firebase Cloud Messaging, SharedPreferences
- **Backend**: FastAPI (Python 3.12+) — httpx, aiosqlite, firebase-admin, systemd
- **AI**: OpenHands Cloud REST API V1 with custom LLM (DeepSeek)
- **Database**: SQLite with WAL mode
- **Push**: Firebase Cloud Messaging (batched send to all registered devices)

## Project Structure

```
backend/           → FastAPI server + worker + deploy scripts
  main.py          → 7 API endpoints
  agent_runner.py  → OpenHands Cloud REST API V1 integration
  worker.py        → Background task processor (async polling)
  database.py      → SQLite schema + connection pool
  models.py        → Pydantic request/response models
  fcm_service.py   → Firebase push notifications
  deploy/          → deploy.sh + vibecode.service (systemd)
  tests.py         → 16 tests (all passing)
app/               → Flutter Android app
  lib/
    models/        → Task, AgentEvent
    services/      → ApiService, PreferencesService, NotificationService
    providers/     → TaskProvider, SettingsProvider
    screens/       → Setup, Home, LiveFeed, Settings
    widgets/       → EventCard (7 types), TaskTile, StatusBanner
```

This project is awesome!

<!-- TURN2 COMPLETE -->
