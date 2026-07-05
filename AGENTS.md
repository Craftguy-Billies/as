# AGENTS.md — VibeCode

## Overview
AI coding assistant for Android. User types prompts from phone → FastAPI backend runs an agent on OpenHands Cloud → live stream of events + push notifications via FCM.

## Stack
- **Frontend**: Flutter 3.38+ (Dart SDK ≥3.10.7) — Provider, Firebase Cloud Messaging, SharedPreferences
- **Backend**: FastAPI (Python ≥3.12) — httpx, aiosqlite, firebase-admin, OpenHands Cloud REST API V1
- **Database**: SQLite with WAL mode
- **Deploy**: systemd on GCP VM (`/opt/vibecode/`)

## Architecture

### Backend data flow
```
POST /api/prompts → INSERT task (status=queued)
  → Worker loop (2s poll) picks up queued tasks
    → run_conversation_sync() in background thread
      → POST to OpenHands Cloud API V1 (/api/v1/app-conversations)
      → Poll /api/v1/conversation/{id}/events/search every 3s
      → Callback persists each event to SQLite
      → On completion: update task status, send FCM push
  → Flutter app polls GET /api/tasks/{id}/events?since_timestamp=...
```

### Key backend files
| File | Role |
|------|------|
| `main.py` | FastAPI app — 8 endpoints, lifespan manages DB/Firebase/Worker |
| `agent_runner.py` | OpenHands Cloud API integration — starts conversations, polls events |
| `worker.py` | Background task processor — picks queued tasks, runs agent in thread |
| `database.py` | SQLite schema (tasks, events, fcm_tokens, app_state) + connection pool |
| `models.py` | Pydantic request/response models |
| `fcm_service.py` | Firebase push — batches to all registered devices |
| `tests.py` | 16 tests using FastAPI TestClient + temp DB |

### Flutter app structure
```
lib/
  main.dart           → Entry point, routing
  models/             → Task, AgentEvent (fromJson)
  services/           → ApiService, PreferencesService, NotificationService
  providers/          → TaskProvider, SettingsProvider (ChangeNotifier)
  screens/            → Setup, Home, LiveFeed, Settings
  widgets/            → EventCard (7 types), TaskTile, StatusBanner
```

### Flutter dependencies
- `provider` — state management
- `http` — REST client
- `firebase_core` + `firebase_messaging` — push notifications
- `shared_preferences` — server URL persistence
- `intl` — date formatting

## Build & Run Commands

### Backend
```bash
cd backend
# Install deps
uv sync
# Run tests (16 tests)
uv run pytest tests.py -v -p no:libtmux
# Run server
uv run uvicorn main:app --host 0.0.0.0 --port 8080
# Run on custom port
HOST=0.0.0.0 PORT=8080 uv run uvicorn main:app --host 0.0.0.0 --port 8080
```

### Flutter app
```bash
cd app
flutter pub get
flutter build apk --debug    # Debug APK (~142MB)
flutter build apk --release  # Release APK
```

## Environment Variables
| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `LLM_API_KEY` | Yes | — | DeepSeek (or custom) API key |
| `LLM_MODEL` | No | `deepseek-chat` | Model name |
| `LLM_BASE_URL` | No | — | Custom LLM endpoint |
| `OPENHANDS_CLOUD_API_KEY` | Yes | — | OpenHands Cloud API key |
| `FIREBASE_CREDENTIALS_PATH` | No | — | Path to firebase-credentials.json |
| `VIBECODE_DB_PATH` | No | `/opt/vibecode/data/vibecode.db` | SQLite database path |
| `VIBECODE_MAX_CONCURRENT` | No | `3` | Max concurrent agent tasks |
| `HOST` | No | `0.0.0.0` | Server bind address |
| `PORT` | No | `8080` | Server port |

## Database Schema
- **tasks**: id, prompt, repo, branch, mode, status (queued/starting/running/completed/failed), conversation_id, sandbox_id, created_at, completed_at, error_message
- **events**: id (autoincrement), task_id (FK CASCADE), event_index, timestamp, kind, source, tool_name, action_json, observation_json, message_json, raw_json
- **fcm_tokens**: id (autoincrement), token (UNIQUE), created_at
- **app_state**: key, value (key-value store)

## API Endpoints
| Method | Endpoint | Purpose |
|--------|----------|---------|
| `GET` | `/api/health` | Health check + current model |
| `POST` | `/api/prompts` | Submit coding task |
| `GET` | `/api/tasks` | List tasks (filter: status, pagination: limit/offset) |
| `GET` | `/api/tasks/{id}` | Single task detail |
| `DELETE` | `/api/tasks/{id}` | Delete queued/failed task |
| `GET` | `/api/tasks/{id}/events` | Events with incremental polling (since_timestamp) |
| `POST` | `/api/fcm-token` | Register device for push |
| `PUT` | `/api/config/llm` | Update LLM config at runtime |
| `GET` | `/api/config/llm` | View LLM config (key hidden) |

## Task Modes
- **code**: Run the task directly (default)
- **plan**: Agent writes a plan to `.agents_tmp/PLAN.md` first, then reads and implements it

## Code Conventions
- **Backend**: Minimal, single-file architecture — no unnecessary abstractions
- **Imports**: All at top of file
- **Async DB**: `get_db_ctx()` context manager always; close after use
- **LLM Config**: Thread-safe with `threading.Lock()`; can be updated at runtime
- **Events**: Stored as JSON strings in action_json/observation_json/message_json/raw_json columns
- **Push**: FCM sends batched (500 per batch) to all registered tokens

## Deployment
One-shot from GCP VM:
```bash
sudo apt update && sudo apt install -y python3 python3-pip python3-venv && \
curl -LsSf https://astral.sh/uv/install.sh | sh && \
sudo rm -rf /opt/vibecode && \
sudo git clone https://github.com/Craftguy-Billies/as.git /opt/vibecode && \
# Create .env, upload firebase-credentials.json, then:
sudo bash /opt/vibecode/backend/deploy/deploy.sh
```

## Testing
- 16 tests in `backend/tests.py` — covers all endpoints, validation, pagination
- Uses `TestClient` from FastAPI + temp SQLite database
- No mocks — tests real code paths
- Run: `uv run pytest tests.py -v -p no:libtmux`

## Git
- Main branch: `main`
- Remote: `origin` → `https://github.com/Craftguy-Billies/as.git`
- Author for commits: OpenHands <openhands@all-hands.dev>
