# VibeCode — Architectural Plan & File Breakdown

## Overview

VibeCode is a mobile AI coding assistant. It connects to OpenHands Cloud to run token-efficient agent conversations, with a Flutter frontend and Python/FastAPI backend.

```
┌─────────────────┐     REST API      ┌──────────────────┐     Cloud API      ┌──────────────────┐
│  Flutter App    │ ◄──────────────► │  FastAPI Backend  │ ◄───────────────► │  OpenHands Cloud  │
│  (Dart/Flutter) │                   │  (Python/uvicorn) │                    │  (agent sandbox)  │
└─────────────────┘                   └──────────────────┘                    └──────────────────┘
                                              │
                                              ▼
                                       ┌──────────────┐
                                       │   SQLite DB   │
                                       │ (vibecode.db) │
                                       └──────────────┘
```

---

## Backend Files (13 source files)

### 1. `backend/main.py` — FastAPI Entry Point (504 lines)

**Purpose:** HTTP server entry point. Defines all REST endpoints and middleware.

**Routes:**

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/health` | Health check |
| GET | `/api/logs` | Recent server logs |
| GET | `/api/logs/stream` | SSE log stream |
| POST | `/api/chat` | Send chat message (single) |
| GET | `/api/chat` | Get chat state (messages + batch status) |
| GET | `/api/chat/repos` | List repos with chat history |
| DELETE | `/api/chat` | Clear current chat |
| POST | `/api/chat/batch` | Enqueue batch prompts |
| POST | `/api/chat/batch/cancel` | Cancel entire batch |
| POST | `/api/chat/batch/cancel/{index}` | Cancel one prompt in batch |
| POST | `/api/prompts` | Create async task (legacy task queue) |
| GET | `/api/tasks` | List tasks with filtering |
| GET | `/api/tasks/{id}` | Get single task |
| DELETE | `/api/tasks/{id}` | Delete task + events |
| POST | `/api/tasks/{id}/retry` | Retry failed task |
| DELETE | `/api/tasks` | Bulk delete tasks |
| GET | `/api/tasks/{id}/events` | Get task events (paginated) |
| POST | `/api/fcm-token` | Register push notification token |
| PUT | `/api/config/llm` | Set LLM configuration |
| GET | `/api/config/llm` | Get LLM configuration |
| PUT | `/api/config/git` | Set git name/email |
| GET | `/api/config/git` | Get git name/email |

**Key classes:** `ChatRequest`, `BatchRequest`, `_BufferHandler` (in-memory log buffer)

---

### 2. `backend/chat_service.py` — Chat Service (1321 lines)

**Purpose:** Core chat logic — conversation lifecycle, batch queue, event polling, response extraction, state persistence. Thread-safe with `_lock`.

**Key Functions:**

| Function | Lines | Purpose |
|----------|-------|---------|
| `_next_msg_id()` | 40-43 | Monotonically increasing message ID counter |
| `_msgs()` | 45-49 | Get/create per-repo message list |
| `_repo_key(repo)` | 51-53 | Stable key: `repo` or `"(no-repo)"` |
| `_migrate_keys(msgs_by_repo)` | 55-90 | Migrate old `"repo\|mode"` keys to flat `"repo"` keys |
| `_restore_from_db()` | 92-124 | Restore all state from SQLite on module load |
| `_persist_to_db()` | 126-166 | Persist all state including `_msg_counter` |
| `reset()` | 176-203 | Full conversation reset (cancel batch, clear state) |
| `get_state(repo, mode)` | 205-232 | Return messages, batch status, conversation info |
| `get_repos()` | 234-255 | List all saved repos with message counts |
| `send(prompt, repo, branch, mode)` | 257-435 | **Main entry**: send message, get agent response |
| `enqueue_batch(prompts, ...)` | 437-486 | Queue batch prompts, reject cross-repo appends |
| `_process_batch_worker()` | 488-605 | Background thread: process batch sequentially, 30-min timeout |
| `cancel_batch()` | 607-623 | Cancel entire running batch |
| `cancel_batch_prompt(index)` | 625-672 | Cancel single prompt by index |
| `_send_message(conv_id, prompt)` | 674-726 | POST send-message to OpenHands, handle sandbox resume |
| `_resume_sandbox(sandbox_id)` | 728-742 | Resume paused sandbox |
| `_create_conversation(prompt, ...)` | 744-870 | POST create conversation with repo/branch/mode/MCP/LLM |
| `_wait_for_response(timeout)` | 872-1168 | **Core polling loop**: poll events/search, extract response |
| `_scrape_events_for_text(events)` | 1170-1214 | Fallback: extract text from last events |
| `_format_event_preview(evt)` | 1216-1321 | Format event for live chat display |

**Response Extraction Pipeline (in `_wait_for_response`):**
1. Poll events/search (limit=100) every ~3s
2. Stream events as live `[MSG]` updates
3. On finish: download trajectory zip (has ALL events)
4. Extract last agent MessageEvent from zip (not limited to first 100)
5. Prefix strip: remove already-seen assistant text from cumulative response
6. Fallback chain: zip → events/search → scrape last 20 events → error message

**Edge cases handled:**
- events/search only returns first 100 events → trajectory zip workaround
- Prefix stripping kills response → fallback to original content
- Agent gives same response twice → preserve duplicate over silence
- Batch append with different repo → rejected
- Server restart mid-batch → auto-resumes from DB
- Conversation timeout (600s) → returns error
- `_last_event_index` reset per send() → fresh event scanning
- `_seen_event_ids` persists across sends → no duplicate events
- `_seen_event_ids` cleared on new conversation → bounded growth

---

### 3. `backend/agent_runner.py` — OpenHands Cloud Integration (486 lines)

**Purpose:** Legacy task-based agent runner. Uses OpenHands Cloud REST API V1 to run full conversations with polling, event storage, and MCP configuration.

**Key Functions:**

| Function | Purpose |
|----------|---------|
| `_restore_llm_config()` | Restore LLM config from DB |
| `_restore_git_config()` | Restore git config from DB |
| `get_llm_config()` / `set_llm_config()` | LLM config CRUD with env fallback |
| `get_git_config()` / `set_git_config()` | Git config CRUD with env fallback |
| `_build_default_mcp_config(mcp_servers)` | Build MCP config dict (fetch + Tavily + custom) |
| `_build_prompt_text(prompt, repo, branch, mode)` | Build full prompt with repo/branch/mode context |
| `run_conversation_sync(...)` | Full agent loop: create → poll → collect events → return result |
| `_serialize_cloud_event(event, index)` | Serialize cloud event for DB storage |

**MCP Servers configured:**
- `fetch` (mcp-server-fetch): web page fetching (default on, `VIBECODE_ENABLE_FETCH!=0`)
- `tavily` (@tavily/mcp-server-tavily): web search (requires `TAVILY_API_KEY` env)

---

### 4. `backend/database.py` — Database Layer (127 lines)

**Purpose:** Async SQLite database for tasks, events, FCM tokens, and key-value store.

**Tables:**
- `tasks` — task queue with status, conversation tracking, MCP config
- `events` — agent events with FK to tasks (CASCADE DELETE)
- `app_state` — key/value app state
- `fcm_tokens` — push notification tokens
- `kv_store` — generic key/value store (used by chat_service for session persistence)

**Key Functions:** `get_sync_db()`, `init_db()`, `get_db()`, `get_db_ctx()`

---

### 5. `backend/models.py` — Pydantic Models (77 lines)

**Purpose:** Request/response validation models.

**Models:** `MCPServerConfig`, `PromptRequest`, `LLMConfigRequest`, `GitConfigRequest`, `FCMTokenRequest`, `TaskResponse`, `EventResponse`, `HealthResponse`, `TasksListResponse`, `EventsListResponse`

---

### 6. `backend/worker.py` — Background Task Worker (237 lines)

**Purpose:** Processes queued tasks sequentially from the database. Handles orphan recovery on server restart. Sends push notifications on task completion.

**Key Functions:**
- `_process_task(task_id)` — run agent, save events, update status, push notify
- `_worker_loop()` — poll every 2s for queued tasks
- `start_worker()` — recover orphaned tasks, start polling
- `stop_worker()` — graceful shutdown

---

### 7. `backend/fcm_service.py` — Push Notifications (102 lines)

**Purpose:** Firebase Cloud Messaging for mobile push notifications on task completion.

**Key Functions:** `init_firebase()`, `send_push_notification(task_id, title, body)`

---

### 8. `backend/tests.py` — API Tests (234 lines)

**Purpose:** Pytest test suite for backend endpoints.

**16 test functions** covering: health, create/list/get/delete tasks, events, FCM, LLM config, plan mode.

---

### 9. Config files
- `backend/pyproject.toml` — Project dependencies (FastAPI, uvicorn, httpx, etc.)
- `backend/.env.example` — Environment variable template
- `backend/deploy/deploy.sh` — Deployment script
- `backend/deploy/vibecode.service` — Systemd service definition

---

## Frontend Files (19 source files in `app/lib/`)

### Architecture Pattern
```
lib/
├── main.dart                    # App entry + route table
├── models/
│   ├── event.dart               # AgentEvent model
│   └── task.dart                # Task model
├── providers/
│   ├── chat_provider.dart       # Chat state (ChangeNotifier)
│   ├── settings_provider.dart   # App settings (ChangeNotifier)
│   └── task_provider.dart       # Task state (ChangeNotifier)
├── screens/
│   ├── app_shell.dart           # Tab shell (Chat + Tasks)
│   ├── chat_screen.dart         # Main chat UI (1080 lines)
│   ├── home_screen.dart         # Task list + prompt input
│   ├── live_feed_screen.dart    # Live agent event feed
│   ├── settings_screen.dart     # LLM/git/server config
│   ├── setup_screen.dart        # First-run server URL setup
│   └── log_viewer_screen.dart   # Server log viewer
├── services/
│   ├── api_service.dart         # REST API client (365 lines)
│   ├── notification_service.dart # FCM push handling
│   └── preferences_service.dart  # SharedPreferences wrapper
└── widgets/
    ├── event_card.dart          # Agent event renderer
    ├── status_banner.dart       # Task status banner
    └── task_tile.dart           # Task list tile
```

### Key Files

### 10. `app/lib/main.dart` (116 lines)
**Purpose:** App entry point. Creates providers, wires notification callbacks, defines routes.

**Routes:** `/` → AppShell, `/tasks/{id}` → LiveFeedScreen, `/settings` → SettingsScreen, `/logs` → LogViewerScreen

---

### 11. `app/lib/providers/chat_provider.dart` (543 lines)
**Purpose:** Core chat state management. Handles message caching, server merge, batch polling, message dedup.

**Key mechanics:**
- **Message caching:** `_saveToCache()` / `loadFromCache()` using SharedPreferences
- **Server merge:** Two-phase: server messages (by ID) first, client fills gaps (by role:content)
- **Batch polling:** 2s Timer.periodic, stops on batch complete
- **Dedup:** `ChatMessage.dedupKey` — ID-based for server msgs, role:content for client
- **Lazy loading:** `_showFromIndex` / `loadMoreMessages()` — shows last 200, "Load earlier" button
- **App lifecycle:** `loadFromCache()` restores + merges + `_notify()` on restart

**Model:** `ChatMessage(id?, role, content, timestamp)` — `dedupKey` getter

---

### 12. `app/lib/screens/chat_screen.dart` (1080 lines)
**Purpose:** Main chat UI — message bubbles, repo/branch/mode inputs, task queue sheet, typing indicator.

**Key components:**
- `ChatScreen` → `_ChatScreenState` — full chat with markdown rendering
- `_ChatBubble` — renders user/assistant/event messages with markdown
- `_TaskQueueSheet` — bottom sheet showing batch tasks with cancel buttons
- `_TypingIndicator` — animated "Agent is working..." dots

---

### 13. `app/lib/services/api_service.dart` (365 lines)
**Purpose:** REST API client. All HTTP calls to the backend.

**25 methods** covering: health, chat (send/batch/cancel/get), tasks (CRUD), events (paginated fetch), config (LLM/git), FCM.

---

### 14. `app/lib/providers/task_provider.dart` (231 lines)
**Purpose:** Task queue state for the legacy task-based mode.

**Key mechanics:** Task polling (2s), event pagination, auto-scroll toggle, lifecycle resume/pause.

---

### 15. `app/lib/providers/settings_provider.dart` (106 lines)
**Purpose:** App settings — server URL, LLM config (model/api key/base URL), git config.

---

### 16. `app/lib/screens/home_screen.dart` (426 lines)
**Purpose:** Task list + prompt input (legacy task mode). Connection states, mode toggle, task list with status.

---

### 17. `app/lib/screens/live_feed_screen.dart` (276 lines)
**Purpose:** Live agent event feed — renders agent actions in real-time.

---

### 18. `app/lib/screens/settings_screen.dart` (392 lines)
**Purpose:** Settings UI — server URL, LLM config with model presets (DeepSeek/Claude/OpenAI/Groq/OpenRouter), git config, diagnostics.

---

### 19. `app/lib/screens/setup_screen.dart` (138 lines)
**Purpose:** First-run setup — server URL input, connection test, navigate to app on success.

---

### 20. `app/lib/screens/log_viewer_screen.dart` (148 lines)
**Purpose:** Server log viewer — color-coded log lines, auto-scroll, 3s polling.

---

### 21-24. Widgets
- `event_card.dart` (346 lines) — Agent event renderer with type-specific cards (terminal, file edit, search, observation, error)
- `status_banner.dart` (95 lines) — Task status with spinner/icon/elapsed time
- `task_tile.dart` (140 lines) — Task list tile with swipe-to-delete

---

### 25-27. Services
- `notification_service.dart` (77 lines) — FCM push notification handling
- `preferences_service.dart` (46 lines) — SharedPreferences wrapper

---

## Conversation Lifecycle (Token-Efficient Mode)

```
User sends message
    │
    ▼
enqueue_batch() ──► Checks: repo changed? ── YES ──► New conversation (POST /app-conversations)
    │                                               with repo/branch/mode/MCP/LLM config
    NO (reuse)
    │
    ▼
send() ──► POST /send-message ──► Agent starts working
    │
    ▼
_wait_for_response() ──► Polls GET /events/search?limit=100 every ~3s
    │                    Streams events as live [MSG] updates
    │
    ├── Conversation finished?
    │       │
    │       ▼
    │   Download trajectory zip (has ALL events)
    │       │
    │       ▼
    │   Extract last agent MessageEvent
    │       │
    │       ▼
    │   Prefix strip (remove already-seen text)
    │       │
    │       ├── Result empty? ──► Try strip latest only
    │       │       │
    │       │       └── Still empty? ──► Use original (duplicate > silence)
    │       │
    │       ▼
    │   Return response to frontend
    │
    └── Timeout (600s)? ──► Return error
```

## Robustness Guarantees

| Scenario | Guarantee |
|----------|-----------|
| events/search limited to 100 events | Trajectory zip has ALL events |
| Prefix strip kills response | Fallback to original content |
| Identical agent responses | Both preserved (duplicate > silence) |
| Zip download fails | Fallback to events/search + event scraping |
| All extraction fails | Visible `[WARN]` message in chat |
| send-message 409/404/410 | New conversation created, retried |
| Batch prompt fails | Error shown, batch continues to next |
| Cross-repo batch append | Rejected with clear error message |
| Server restart mid-batch | Auto-resumes from SQLite |
| App killed mid-processing | Cache restored + server merge + `_notify()` |
| Duplicate event messages | `_seen_event_ids` prevents re-adding |
| Two identical "ok" messages | Different IDs → both survive |
| Message list >500 | Trimmed to 400 in DB |
| Corrupted cache | Cleared silently |

