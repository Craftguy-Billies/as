# VibeCode — Complete Deployment Guide

AI coding assistant for Android. Type prompts from your phone → AI agent runs on OpenHands Cloud → live event stream + push notifications.

```
Flutter Android App ◄──REST──► GCP VM (FastAPI) ◄──REST──► OpenHands Cloud
```

---

## HONEST STATUS: What's Done vs What You Provide

| Layer | Built? | Tested? | You provide |
|---|---|---|---|
| Backend API (7 routes) | ✅ | 16/16 tests + live curl audit | API keys in .env |
| OpenHands Cloud integration | ✅ | Verified against V1 REST API | OPENHANDS_CLOUD_API_KEY |
| SQLite persistence | ✅ | Tables + indexes + WAL mode | Nothing |
| Background worker | ✅ | Async polling + concurrent tasks | Nothing |
| FCM push notifications | ✅ | Firebase Admin SDK + batched send | firebase-credentials.json |
| systemd service | ✅ | Auto-restart on failure | GCP VM |
| deploy script | ✅ | 6-step with verification | Nothing |
| Flutter app (all screens) | ✅ | 0 errors, 0 warnings | APK build on your machine |
| API keys | ❌ | — | **YOU provide these** |
| Firebase project | ❌ | — | **YOU create this** |
| GCP VM | ❌ | — | **YOU create this** |

**No, you have NOT given me any API keys in this conversation.** There are no DeepSeek keys, no Firebase credentials, and no GCP VM details anywhere in our chat. Everything placeholder — the `.env` file uses `sk-your-key-here` and `your-openhands-key-here`.

---

## STEP 0: Get Your 3 API Keys (~10 min)

### 0a. OpenHands Cloud API Key

1. Open **https://app.all-hands.dev**
2. Click **"Log in with GitHub"** (or GitLab)
3. Once logged in, click your **profile icon** (top-right corner)
4. Click **"Settings"** in the dropdown
5. In the left sidebar, click **"API Keys"**
6. Click the **"Create API Key"** button (purple/violet)
7. Name it "VibeCode", click **"Create"**
8. **Copy the key immediately** — starts with `oak-`. It will NOT be shown again.
9. Save it. This is `OPENHANDS_CLOUD_API_KEY`.

> Verify: The key is 50+ characters. If you can see it in your clipboard, it worked.

### 0b. LLM API Key (DeepSeek — cheapest by far)

1. Open **https://platform.deepseek.com/api_keys**
2. Sign up with email/phone
3. Click **"Create new API key"**
4. **Copy immediately** — starts with `sk-`
5. This is `LLM_API_KEY`
6. Model: `deepseek-chat`, Base URL: `https://api.deepseek.com/v1`

> Verify: Go to https://platform.deepseek.com/usage — you'll see your free credits.

**Alternative providers:**
- Claude: https://console.anthropic.com/settings/keys → "Create Key" → model: `claude-sonnet-4-20250514`
- OpenAI: https://platform.openai.com/api-keys → "+ Create new secret key" → model: `gpt-4o`

### 0c. Firebase Project + Credentials

1. Open **https://console.firebase.google.com**
2. Click **"Create a project"** (or "+" Add project)
3. Name: `VibeCode`, click **"Continue"**
4. Toggle Google Analytics **OFF**, click **"Create project"**
5. Wait ~30s, click **"Continue"**
6. Click **gear icon (⚙️)** next to "Project Overview" → **"Project settings"**
7. Go to **"Service accounts"** tab
8. Click **"Generate new private key"** → **"Generate key"**
9. Rename downloaded file to `firebase-credentials.json` — save it.

> Verify: Open the file. It must have `"type": "service_account"`, `"project_id"`, `"private_key"`.

**For Android push notifications (same Firebase project):**
10. Go to **Project Overview** → click **Android icon** (or "Add app")
11. Package name: `com.vibecode.vibecode`
12. Click **"Register app"**
13. Download `google-services.json` — save it (needed before APK build)
14. Click "Next", "Next", "Continue to console"

---

## STEP 1: Create GCP VM (~5 min)

### 1a. Create the VM

1. Open **https://console.cloud.google.com/compute/instances**
2. Click **"CREATE INSTANCE"** (blue button at top)
3. Configure:
   - **Name**: `vibecode`
   - **Machine type**: `e2-small` (2 vCPU, 2GB RAM, ~$13/month)
   - **Boot disk**: Click **"CHANGE"** → **"Ubuntu 24.04 LTS"** → **"SELECT"**
   - **Firewall**: Check BOTH: "Allow HTTP traffic" + "Allow HTTPS traffic"
4. Click **"CREATE"** (blue button at bottom)
5. Wait for green checkmark (~2 min)

### 1b. Open Port 8080

1. Left sidebar: **"VPC network"** → **"Firewall"**
2. Click **"CREATE FIREWALL RULE"**
3. Set:
   - Name: `allow-vibecode`
   - Targets: **"All instances in the network"**
   - Source IPv4 ranges: `0.0.0.0/0`
   - TCP: `8080`
4. Click **"CREATE"**

### 1c. Get Your VM IP

Go back to VM Instances → copy the **"External IP"** (e.g., `34.123.45.67`). This is `YOUR_VM_IP`.

---

## STEP 2: SSH & Deploy Backend (~10 min)

### 2a. SSH Into the VM

**Easiest (always works):** In VM list, click **▼ dropdown** under "Connect" → **"Open in browser window"**

**Or your terminal:**
```bash
ssh YOUR_USERNAME@YOUR_VM_IP
```

> "Permission denied"? Use browser SSH — it always works.
> "Connection refused"? VM still booting, wait 30s.
> Black screen in browser? Wait 10s — terminal is loading.

### 2b. Install Python and uv

Run these ONE AT A TIME in the SSH session:

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv
python3 --version
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc
uv --version
```

> Verify: `python3 --version` shows 3.12+. `uv --version` shows 0.5+.

### 2c. Upload Backend Code

**From your LOCAL machine (new terminal):**
```bash
cd /path/to/your/project
rsync -avz ./backend/ YOUR_USERNAME@YOUR_VM_IP:/opt/vibecode/
```

**If using browser SSH:** Use `gcloud compute scp` from your local terminal:
```bash
gcloud compute scp --recurse ./backend/* YOUR_VM_NAME:/opt/vibecode/ --zone=YOUR_ZONE
```

### 2d. Create .env on the VM

In the SSH session:
```bash
sudo mkdir -p /opt/vibecode/data
sudo chown -R $USER:$USER /opt/vibecode
nano /opt/vibecode/.env
```

Paste this EXACT content (replace the two placeholder keys):
```ini
LLM_API_KEY=sk-YOUR-ACTUAL-DEEPSEEK-KEY
LLM_MODEL=deepseek-chat
LLM_BASE_URL=https://api.deepseek.com/v1
OPENHANDS_CLOUD_API_KEY=oak-YOUR-ACTUAL-OPENHANDS-KEY
FIREBASE_CREDENTIALS_PATH=/opt/vibecode/firebase-credentials.json
HOST=0.0.0.0
PORT=8080
```

Save: **Ctrl+O** → **Enter** → **Ctrl+X**

> The ONLY things you change are the two placeholder keys. Everything else stays as-is.

### 2e. Upload Firebase Credentials

From your local machine:
```bash
scp ./firebase-credentials.json YOUR_USERNAME@YOUR_VM_IP:/opt/vibecode/
```

### 2f. Deploy

In the SSH session:
```bash
chmod +x /opt/vibecode/deploy/deploy.sh
sudo bash /opt/vibecode/deploy/deploy.sh
```

Expected output:
```
=== VibeCode Deployment ===
[1/6] Checking prerequisites...
  Python 3.12.x detected
[2/6] Setting up vibecode user...
[3/6] Setting up directories...
[4/6] Installing Python dependencies...
[5/6] Installing systemd service...
[6/6] Starting VibeCode backend...
=== Deployment Complete! ===
```

### 2g. Verify

```bash
systemctl status vibecode
curl http://localhost:8080/api/health
```

Expected: `{"status":"ok","model":"deepseek-chat","version":"1.0.0"}`

### 2h. Test from Your Phone Browser

Open in your phone browser:
```
http://YOUR_VM_IP:8080/api/health
```

If you see JSON, the backend is live on the internet!

### 2i. Test a Real Task

```bash
curl -X POST http://localhost:8080/api/prompts \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Create hello.py that prints hello world","repo":"test/demo","mode":"code"}'
```

Then check:
```bash
curl http://localhost:8080/api/tasks
```

Tasks go: `queued` → `starting` → `running` → `completed`. First task takes 30-60 seconds (sandbox cold start).

> **"failed" with "NoCredentialsError"** → OPENHANDS_CLOUD_API_KEY is wrong.
> **"failed" with "401"** → LLM_API_KEY is wrong.
> **Stuck at "queued"** → `journalctl -u vibecode -n 50` for errors.
> **"Connection refused" from phone** → Firewall rule not working. Re-check Step 1b.

---

## STEP 3: Build & Install Android App (~15 min)

**On YOUR LOCAL MACHINE** (needs Flutter SDK + Android Studio):

### 3a. Place google-services.json
```bash
cp ~/Downloads/google-services.json app/android/app/google-services.json
```

### 3b. Build APK
```bash
cd app
flutter pub get
flutter build apk --debug
```
APK at: `build/app/outputs/flutter-apk/app-debug.apk`

> "No Android SDK" → Open Android Studio once (it auto-installs SDK).
> "Firebase app not initialized" → google-services.json is not at the right path.

### 3c. Install on Phone

**USB:** Enable Developer Options → USB Debugging → `cd app && flutter install`

**APK transfer:** Copy apk to phone → open file → allow "unknown sources" → Install

---

## STEP 4: First Run

1. Open VibeCode app → dark screen with URL input
2. Enter: `http://YOUR_VM_IP:8080`
3. Tap **"Connect"** → green checkmark + "Connected · Model: deepseek-chat"
4. App auto-navigates to Home
5. Enter repo: `test/demo`, prompt: `Create hello.py`
6. Toggle **Code** mode (purple), tap **send** (purple arrow)
7. Live Feed opens → status banner → events stream in real-time
8. Terminal cards, file edit cards, agent messages appear
9. App auto-scrolls to newest events
10. Swipe to see earlier events
11. Close app → reopen → all events catch up instantly
12. When done: "Completed" + push notification (if Firebase configured)

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Connection failed" on setup | SSH: `systemctl status vibecode`. Check firewall Step 1b. |
| Tasks fail with NoCredentialsError | OPENHANDS_CLOUD_API_KEY in .env is wrong |
| Tasks fail with 401/403 | LLM_API_KEY or model name is wrong |
| Stuck at "queued" | `journalctl -u vibecode -n 50` |
| "Permission denied: /opt/vibecode" | `sudo chown -R vibecode:vibecode /opt/vibecode` |
| Service exits immediately | .env has placeholder values (sk-your-key-here) |
| No push notifications | firebase-credentials.json missing from /opt/vibecode/ |
| APK won't build | Open Android Studio once; run flutter doctor |
| App blank screen | Go to Settings → enter server URL → Test Connection |

## Service Commands (on VM)

```bash
systemctl status vibecode       # Check status
systemctl restart vibecode      # Restart
journalctl -u vibecode -f       # Live logs
journalctl -u vibecode -n 100   # Last 100 lines
curl http://localhost:8080/docs # Swagger API docs
```
