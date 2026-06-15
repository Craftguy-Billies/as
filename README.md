# VibeCode

AI coding assistant for Android — type prompts from your phone, get AI-powered code changes via OpenHands Cloud, with live event streaming and push notifications.

```
┌──────────────────┐      ┌─────────────────────────┐      ┌──────────────────┐
│  Flutter Android │◄────►│  GCP VM (FastAPI)       │◄────►│  OpenHands Cloud │
│  App             │ REST │                         │ REST │  (Sandbox + LLM) │
│                  │      │  • Task queue            │      │                  │
│  • Dark theme    │      │  • Event cache (SQLite)  │      │  • AI agent       │
│  • Live feed     │      │  • Push notifications    │      │  • Code execution │
│  • Plan/Code mode│      │  • LLM config proxy      │      │  • Git operations │
└──────────────────┘      └─────────────────────────┘      └──────────────────┘
```

---

## What You Still Need to Provide (3 things)

The entire codebase is built and tested. You need these 3 items to run it:

1. **API Keys** (2 keys, ~5 min)
2. **GCP VM setup** (SSH + deploy, ~10 min)
3. **Firebase project** (for push notifications, ~5 min)

---

## Step 1: Get Your API Keys

### 1a. OpenHands Cloud API Key

1. Go to **https://app.all-hands.dev**
2. **Sign in** with your GitHub or GitLab account
3. Click your **profile icon** (top-right corner) → **Settings**
4. Click **API Keys** in the left sidebar
5. Click the **"Create API Key"** button (purple/violet button)
6. **Copy the key immediately** — it won't be shown again
7. Save it: this is your `OPENHANDS_CLOUD_API_KEY`

### 1b. LLM API Key (pick one)

**DeepSeek** (cheapest, recommended):
1. Go to **https://platform.deepseek.com/api_keys**
2. Sign up/log in
3. Click **"Create new API key"**
4. Copy the key — this is your `LLM_API_KEY`
5. Model: `deepseek-chat` | Base URL: `https://api.deepseek.com/v1`

**Claude (Anthropic):**
1. Go to **https://console.anthropic.com/settings/keys**
2. Sign up/log in
3. Click **"Create Key"**
4. Copy the key — this is your `LLM_API_KEY`
5. Model: `claude-sonnet-4-20250514` | Base URL: leave empty

**OpenAI:**
1. Go to **https://platform.openai.com/api-keys**
2. Sign up/log in
3. Click **"+ Create new secret key"**
4. Copy the key — this is your `LLM_API_KEY`
5. Model: `gpt-4o` | Base URL: leave empty

---

## Step 2: Set Up Firebase (Push Notifications)

1. Go to **https://console.firebase.google.com**
2. Click **"Create a project"** (or use an existing one)
3. Enter a project name (e.g., "VibeCode"), click **Continue**
4. Disable Google Analytics (optional), click **Create project**
5. Once created, click the **gear icon** (⚙️) next to "Project Overview" → **Project settings**
6. Go to the **Service accounts** tab
7. Click **"Generate new private key"** → **"Generate key"**
8. Save the downloaded JSON file as `firebase-credentials.json`
9. In the same Project settings, go to **Cloud Messaging** tab
10. Note the **Server key** — you'll need it for the Android app setup later

**For the Android app (build step only):**
1. In Firebase Console, click **"Add app"** → **Android**
2. Package name: `com.vibecode.vibecode`
3. Click **"Register app"**
4. Download `google-services.json`
5. Place it at: `app/android/app/google-services.json` before building the APK

---

## Step 3: Deploy the Backend to Your GCP VM

### 3a. SSH into your VM

```bash
ssh YOUR_USERNAME@YOUR_VM_IP
```

> **If you're using a password:** you'll be prompted to enter it.
>
> **If you're using an SSH key:** make sure your key is loaded:
> ```bash
> ssh-add ~/.ssh/your_key   # if you have a key with a passphrase
> # or
> ssh -i ~/.ssh/your_key YOUR_USERNAME@YOUR_VM_IP
> ```
>
> **If you get "Permission denied":** check your username and that your SSH key is added to the VM's metadata in GCP Console → VM Instances → click your VM → Edit → SSH Keys.

### 3b. Install prerequisites on the VM

```bash
# Install Python 3.12+ (if not already installed)
sudo apt update && sudo apt install -y python3 python3-pip python3-venv

# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc

# Verify
python3 --version  # Should be 3.12+
uv --version
```

### 3c. Open firewall port 8080

In GCP Console:
1. Go to **VPC network** → **Firewall**
2. Click **"Create Firewall Rule"**
3. Name: `allow-vibecode`
4. Targets: **"All instances in the network"**
5. Source IP ranges: `0.0.0.0/0`
6. Protocols and ports: **TCP**, Port: **8080**
7. Click **"Create"**

> **CLI alternative:**
> ```bash
> gcloud compute firewall-rules create allow-vibecode \
>   --allow tcp:8080 \
>   --source-ranges 0.0.0.0/0 \
>   --description "VibeCode backend"
> ```

### 3d. Upload the backend code

On your **local machine** (not the VM):

```bash
# From the project root
rsync -avz ./backend/ YOUR_USERNAME@YOUR_VM_IP:/opt/vibecode/
```

Or using SCP:
```bash
scp -r ./backend/* YOUR_USERNAME@YOUR_VM_IP:/opt/vibecode/
```

### 3e. Create the .env file on the VM

SSH into the VM and create the environment file:

```bash
ssh YOUR_USERNAME@YOUR_VM_IP
sudo mkdir -p /opt/vibecode/data
sudo chown -R $USER:$USER /opt/vibecode

cat > /opt/vibecode/.env << 'EOF'
LLM_API_KEY=sk-your-llm-key-here
LLM_MODEL=deepseek-chat
LLM_BASE_URL=https://api.deepseek.com/v1
OPENHANDS_CLOUD_API_KEY=your-openhands-key-here
FIREBASE_CREDENTIALS_PATH=/opt/vibecode/firebase-credentials.json
HOST=0.0.0.0
PORT=8080
EOF
```

**Edit the file** and replace the placeholder values with your actual keys:
```bash
nano /opt/vibecode/.env
```

### 3f. Upload Firebase credentials

From your **local machine**:
```bash
scp ./firebase-credentials.json YOUR_USERNAME@YOUR_VM_IP:/opt/vibecode/firebase-credentials.json
```

### 3g. Run the deploy script

On the VM:
```bash
sudo bash /opt/vibecode/deploy/deploy.sh
```

This will:
- Create the `vibecode` system user
- Install Python dependencies with uv
- Install and start the systemd service

### 3h. Verify the backend is running

```bash
curl http://localhost:8080/api/health
```

Expected response:
```json
{"status":"ok","model":"deepseek-chat","version":"1.0.0"}
```

View logs:
```bash
journalctl -u vibecode -f
```

---

## Step 4: Build and Install the Android App

### Prerequisites (on your local machine):
- **Flutter SDK 3.38+** → https://docs.flutter.dev/get-started/install
- **Android Studio** (for Android SDK) → https://developer.android.com/studio
- **Java 17+** (bundled with Android Studio)

### 4a. Place google-services.json

Get the `google-services.json` you downloaded from Firebase (Step 2) and place it at:
```
app/android/app/google-services.json
```

### 4b. Build the APK

```bash
cd app
flutter pub get
flutter build apk --debug
```

The APK will be at:
```
build/app/outputs/flutter-apk/app-debug.apk
```

### 4c. Install on your Android phone

**Option A — USB:**
```bash
flutter install
```

**Option B — Transfer the APK:**
1. Copy `app-debug.apk` to your phone (USB, AirDroid, Google Drive, etc.)
2. On your phone: Settings → Security → Enable "Install from unknown sources"
3. Open the APK file → Install

---

## Step 5: First Run

1. **Open the VibeCode app** on your phone
2. Enter your VM's URL: `http://YOUR_VM_IP:8080`
3. Tap **"Connect"** — you should see a green checkmark with your model name
4. On the home screen, enter a repo: `owner/repo`
5. Type a prompt: `Create a hello.py file that prints "hello world"`
6. Toggle **Code** or **Plan** mode
7. Tap **Send** (purple send button)
8. The live feed screen opens — you'll see events appear in real-time
9. Close the app — the backend continues working
10. Reopen — all events catch up instantly
11. When done, you'll get a push notification

---

## File Structure

```
/workspace/project/
├── backend/                     # Python FastAPI backend
│   ├── main.py                  # FastAPI server + all routes
│   ├── database.py              # Async SQLite layer
│   ├── models.py                # Pydantic request/response models
│   ├── agent_runner.py          # OpenHands Cloud API integration
│   ├── worker.py                # Background task processor
│   ├── fcm_service.py           # Firebase Cloud Messaging
│   ├── tests.py                 # 16 backend tests (all passing)
│   ├── pyproject.toml           # Python deps (uv)
│   ├── .env.example             # Template for credentials
│   └── deploy/
│       ├── deploy.sh            # One-command VM deployment
│       └── vibecode.service     # systemd unit file
├── app/                         # Flutter Android app
│   └── lib/
│       ├── main.dart            # App entry + route config
│       ├── models/
│       │   ├── task.dart        # Task data model
│       │   └── event.dart       # Event data model
│       ├── services/
│       │   ├── api_service.dart # Backend REST client
│       │   ├── preferences_service.dart
│       │   └── notification_service.dart
│       ├── providers/
│       │   ├── task_provider.dart    # Task state + live polling
│       │   └── settings_provider.dart
│       ├── screens/
│       │   ├── home_screen.dart      # Prompt input + task list
│       │   ├── live_feed_screen.dart # Event feed with auto-scroll
│       │   ├── settings_screen.dart  # Server URL + LLM config
│       │   └── setup_screen.dart     # First-time connection
│       └── widgets/
│           ├── event_card.dart       # Event type dispatcher
│           ├── task_tile.dart        # Task list item
│           └── status_banner.dart    # Live status header
├── .gitignore
└── README.md
```

---

## API Reference

All endpoints are documented in the FastAPI interactive docs. After deploying, visit:
```
http://YOUR_VM_IP:8080/docs
```

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/prompts` | Create a new coding task |
| GET | `/api/tasks` | List all tasks |
| GET | `/api/tasks/{id}` | Get task details |
| DELETE | `/api/tasks/{id}` | Delete a queued/failed task |
| GET | `/api/tasks/{id}/events` | Get events (with `?since_timestamp=`) |
| POST | `/api/fcm-token` | Register device for push |
| PUT | `/api/config/llm` | Update LLM configuration |
| GET | `/api/config/llm` | View current LLM config |
| GET | `/api/health` | Health check + model info |

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Connection failed" in app | Check VM firewall allows port 8080; verify backend is running (`systemctl status vibecode`) |
| Backend won't start | Check logs: `journalctl -u vibecode -n 50` |
| Tasks stuck at "queued" | Check `OPENHANDS_CLOUD_API_KEY` and `LLM_API_KEY` in `/opt/vibecode/.env` |
| No push notifications | Verify `firebase-credentials.json` exists on VM; check `google-services.json` in app |
| "OPENHANDS_CLOUD_API_KEY not set" | The `.env` file isn't being read; verify it's at `/opt/vibecode/.env` and the systemd service points to it |
| DeepSeek API errors | Verify base URL is `https://api.deepseek.com/v1` (must end with `/v1`) |

---

## Quick Commands Reference

```bash
# Backend
ssh YOUR_USERNAME@YOUR_VM_IP                           # SSH into VM
systemctl status vibecode                                # Check service
systemctl restart vibecode                               # Restart service
journalctl -u vibecode -f                                # Watch logs
curl http://localhost:8080/api/health                    # Health check

# Backend tests
cd backend && uv run python -m pytest tests.py -v -p no:libtmux

# Flutter
cd app && flutter analyze                                 # Check for errors
cd app && flutter build apk --debug                       # Build APK
cd app && flutter install                                 # Install to phone via USB
```
