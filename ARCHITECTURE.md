# VibeCode Architecture

## System Overview

VibeCode is a mobile-first AI coding assistant that lets you ship code from your Android phone using OpenHands Cloud.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Flutter App     │────▶│  FastAPI Server  │────▶│  OpenHands Cloud │
│  (Android)       │◀────│  (GCP VM)        │◀────│  (Sandbox Agent)  │
└────────┬────────┘     └────────┬────────┘     └─────────────────┘
         │                       │
         │  FCM Push             │  SQLite (WAL)
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│  Firebase Cloud  │     │  Async Queue     │
│  Messaging       │     │  (Max 3 Workers) │
└─────────────────┘     └─────────────────┘
```

## Data Flow

### Prompt → Execution → Notification

1. **App sends prompt** — `POST /api/prompts` with `{prompt, repo, branch, mode}`
2. **Backend queues task** — Inserts into SQLite with `status=queued`, returns `{task_id}`
3. **Worker picks up** — Background loop polls for queued tasks, max 3 concurrent
4. **Agent runs** — Worker calls `agent_runner.run_conversation_sync()` in a thread pool
5. **Events stream** — Agent polls OpenHands Cloud every 3s, saves events to SQLite
6. **App polls** — `GET /api/tasks/{id}/events?since_timestamp=...` every 3s
7. **Push notification** — On completion/failure, FCM message sent to all registered devices

### Event Types

| Type | Source | Card Widget |
|---|---|---|
| `user_message` | App prompt | Blue right-aligned bubble |
| `agent_message` | Agent response | Dark left-aligned card |
| `terminal_action` | Command execution | Monospace `$ ` block with copy |
| `file_edit_action` | File modification | Path + "editing" badge |
| `search_action` | Web/file search | Globe icon + query |
| `observation` | Agent observation | Generic card |
| `error` | Failure | Red error card |

## Backend Design

### Concurrency Model

- **asyncio** for the HTTP server and worker loop
- **Thread pool** for blocking OpenHands API calls (httpx in sync mode)
- **SQLite WAL mode** enables concurrent reads during writes
- **Semaphore(3)** limits concurrent agent executions to prevent resource exhaustion

### Database Schema

```sql
tasks (
    id TEXT PRIMARY KEY,
    prompt TEXT NOT NULL,
    repo TEXT DEFAULT 'test/demo',
    branch TEXT DEFAULT 'main',
    mode TEXT DEFAULT 'code',
    status TEXT DEFAULT 'queued',     -- queued|starting|running|completed|failed
    conversation_id TEXT,
    sandbox_id TEXT,
    created_at TEXT,
    started_at TEXT,
    completed_at TEXT,
    error_message TEXT
)

events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    event_index INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    content TEXT,
    payload TEXT,                     -- JSON blob
    timestamp TEXT,
    INDEX idx_events_task_ts (task_id, timestamp),
    INDEX idx_events_task_idx (task_id, event_index)
)

app_state (key TEXT PRIMARY KEY, value TEXT)
fcm_tokens (token TEXT PRIMARY KEY, created_at TEXT)
```

### API Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/health` | Health check, returns model name and version |
| `POST` | `/api/prompts` | Submit a coding task, returns task ID |
| `GET` | `/api/tasks` | List all tasks, optional `?status=` filter |
| `GET` | `/api/tasks/{id}` | Get single task details |
| `DELETE` | `/api/tasks/{id}` | Delete queued or failed task |
| `GET` | `/api/tasks/{id}/events` | Get events, incremental via `?since_timestamp=` |
| `POST` | `/api/fcm-token` | Register device for push notifications |
| `PUT` | `/api/config/llm` | Update LLM config (provider, model, key) at runtime |
| `GET` | `/api/config/llm` | View current LLM config (API key redacted) |

### Mode: Code vs Plan

The `mode` field in `POST /api/prompts` determines agent behavior:

- **`code`** — Agent implements the prompt directly. Prompt starts with "You are a coding assistant. Implement the following..."
- **`plan`** — Agent first researches, writes a plan to `.agents_tmp/PLAN.md`, then implements. Prompt includes detailed multi-step instructions.

Both modes use the same OpenHands Cloud conversation API — the difference is purely in prompt construction.

## OpenHands Cloud Integration

The `agent_runner.py` module uses the **OpenHands Cloud REST API V1**:

1. `POST /api/v1/app-conversations` — Creates a conversation with custom LLM config
2. Polls `GET /api/v1/app-conversations/{id}` until status is no longer `starting`
3. Polls `GET /api/v1/app-conversations/{id}/events` every 3s for new events
4. Event types are normalized: `actions` → type-specific events, `observations` → observation events

## Flutter App Architecture

### State Management

- **Provider** pattern with `ChangeNotifier`
- `TaskProvider` — Task list, live feed polling, event accumulation
- `SettingsProvider` — Server URL persistence, connection testing, LLM config

### Navigation

```
SetupScreen (first launch, no server configured)
    │
    ▼
HomeScreen (prompt input + task list)
    │
    ├──▶ LiveFeedScreen (event stream for a task)
    │
    └──▶ SettingsScreen (server URL, LLM config, presets)
```

### Polling Strategy

- **Live feed**: 3-second `Timer` while screen is active
- **Lifecycle aware**: Pauses polling when app backgrounds, resumes on foreground
- **Incremental**: Uses `since_timestamp` to only fetch new events
- **Auto-scroll**: Maintains scroll position unless user manually scrolls up
- **Collapse**: Only shows last 30 events in memory, with "Show earlier" for history

### Notification Flow

1. `NotificationService` initializes Firebase Messaging
2. Gets FCM token → sends to backend via `POST /api/fcm-token`
3. Listens for token refresh → re-sends to backend
4. Foreground messages: shown as local notification
5. Background/terminated: handled by Firebase SDK, opens app on tap

## Deployment

### Infrastructure

- **GCP Compute Engine** VM (e2-micro or larger)
- **Ubuntu** with Python 3.12+
- **systemd** for process management (auto-start, auto-restart)
- **SQLite** for zero-config persistence (no separate database server)

### deploy.sh Steps

1. Check prerequisites (Python, uv)
2. Create `vibecode` system user
3. Set up `/opt/vibecode/` directory structure
4. Create `.env` file from user-provided values
5. Install Python dependencies via `uv sync`
6. Install and enable systemd service
7. Start service and verify health endpoint

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `LLM_API_KEY` | Yes | API key for the LLM provider |
| `LLM_MODEL` | Yes | Model name (e.g., `deepseek-chat`) |
| `LLM_BASE_URL` | No | Custom base URL for OpenAI-compatible APIs |
| `OPENHANDS_CLOUD_API_KEY` | Yes | API key for OpenHands Cloud |
| `FIREBASE_CREDENTIALS_PATH` | Yes | Path to Firebase service account JSON |
| `HOST` | No | Bind host (default: `0.0.0.0`) |
| `PORT` | No | Bind port (default: `8080`) |

## Tech Stack

| Component | Technology | Purpose |
|---|---|---|
| Mobile UI | Flutter 3.38+ (Dart) | Android app |
| State | Provider + ChangeNotifier | Reactive state management |
| HTTP | `http` package | REST API client |
| Storage | SharedPreferences | Server URL, last seen timestamp |
| Push | Firebase Cloud Messaging | Push notifications |
| Server | FastAPI (Python 3.12+) | REST API |
| Async | asyncio + aiosqlite | Non-blocking I/O |
| HTTP Client | httpx | OpenHands Cloud API calls |
| Database | SQLite (WAL mode) | Task and event persistence |
| Deployment | systemd + bash | GCP VM management |
| AI Runtime | OpenHands Cloud REST API V1 | Sandboxed agent execution |
