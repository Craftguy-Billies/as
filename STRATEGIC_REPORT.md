# VibeCode — Strategic Extension Report

> **Generated**: 2026-06-22 &nbsp;|&nbsp; **Version**: v1.0.0 baseline &nbsp;|&nbsp; **Author**: AI Agent (OpenHands) on behalf of Craftguy-Billies

---

## 1. Executive Summary

VibeCode is a polished, functional v1.0.0 product that delivers on its core promise: type a coding prompt on your Android phone, have an AI agent execute it in an OpenHands Cloud sandbox, and watch the results stream back live with push notifications. The codebase is clean, well-factored, and nearly bug-free.

The architecture — FastAPI backend with SQLite, OpenHands Cloud REST API integration, Firebase Cloud Messaging, and a Flutter Android frontend — is deliberately simple and optimised for a single-user, single-server deployment model. This simplicity is a strength for v1 but will become a constraint as soon as the product grows beyond one user and one concurrent task.

This report identifies **16 concrete extension opportunities** organised into three time horizons, each with rationale, implementation sketch, and estimated effort.

---

## 2. Architecture Assessment

### 2.1 What works well

| Dimension | Assessment |
|-----------|------------|
| **Code quality** | Clean separation of concerns (database, worker, agent runner, models, FCM). No god objects. Functions and classes are small. |
| **LLM agnosticism** | Runtime-swappable LLM via `PUT /api/config/llm`. Supports any OpenAI-compatible provider (DeepSeek, Claude, GPT, Groq, OpenRouter). |
| **Plan + Code mode** | The plan-then-implement two-phase workflow is well-designed and leverages the agent's own file system to persist the plan. |
| **Deploy automation** | `deploy.sh` + systemd unit file is battle-ready. One-command GCP VM deployment works. |
| **Incremental polling** | `since_timestamp` parameter on `/api/tasks/{id}/events` gives the client efficient incremental updates. |
| **Push notifications** | FCM with batch-send (500 per chunk), token refresh handling, and foreground/background/tapped flows all implemented. |
| **App lifecycle** | The Flutter app pauses polling when backgrounded and resumes on foreground — good for battery. |

### 2.2 Structural constraints (v1 limitations)

| Constraint | Impact | Root cause |
|------------|--------|------------|
| **SQLite, single writer** | Cannot run >1 task concurrently without DB contention | WAL mode helps read concurrency but writes are serialised |
| **Polling, not streaming** | 3-second latency floor for events; wastes bandwidth on idle polling | OpenHands Cloud API does not expose WebSocket/SSE natively |
| **No auth** | Anyone who can reach `:8080` controls the server | Single-user assumption |
| **Serial worker** | Tasks queue and process one-at-a-time | `dequeue_task` picks the oldest single task |
| **No task cancellation** | Once a task starts, it cannot be stopped | Agent runs in a thread; no abort signal is propagated |
| **Fire-and-forget** | Cannot send follow-up messages to a running agent | The conversation API is consumed but the reply path is not wired |
| **Android-only** | No iOS build despite Flutter's cross-platform capability | Firebase config is Android-only |
| **No persistent conversation history** | Only the live feed exists; completed task details vanish after app restart unless re-fetched | Caching is client-side only |

---

## 3. Extension Roadmap

### 3.1 Near-Term (v1.x — 1–3 months)

These are high-impact, low-effort improvements that can ship quickly without architectural overhaul.

---

#### 3.1.1 Concurrent Task Processing (⭐ High Priority)

**Problem**: The worker loops over `dequeue_task()` which picks one task at a time. If task A takes 10 minutes, task B sits queued the entire time.

**Solution**: Replace the single async worker with a bounded semaphore pool:

```python
# worker.py — proposed change
_MAX_CONCURRENT = int(os.getenv("VIBECODE_MAX_CONCURRENT", "3"))

async def start_worker():
    sem = asyncio.Semaphore(_MAX_CONCURRENT)
    async def run_one():
        async with sem:
            task = await dequeue_task()
            if task:
                await process_task(task)
    while not _worker_stop.is_set():
        await run_one()
        await asyncio.sleep(2)
```

SQLite write contention is mitigated because each task accumulates events in memory (the existing `event_batch` pattern) and flushes them in a single transaction at completion. For longer-running tasks that need intermediate event persistence, switch to `BEGIN IMMEDIATE` transactions or add a write-ahead queue.

**Effort**: ~2 days dev + 1 day test.

**Risks**: SQLite WAL supports concurrent readers but only one writer. If two tasks finish simultaneously, one will get `SQLITE_BUSY`. Mitigation: retry with exponential backoff in `process_task`, or use `aiosqlite` with a `timeout` parameter.

---

#### 3.1.2 Task Cancellation (⭐ High Priority)

**Problem**: A user submits a prompt, realises it's wrong, but cannot stop the running agent.

**Solution**:

1. Add `cancelled` status to the task state machine.
2. In `worker.py`, before each poll iteration in `run_conversation_sync`, check a threading `Event`:

```python
# agent_runner.py — proposed change
_cancel_events: dict[str, threading.Event] = {}

def cancel_conversation(conversation_id: str):
    if conversation_id in _cancel_events:
        _cancel_events[conversation_id].set()

def run_conversation_sync(..., cancel_event=None):
    while not done:
        if cancel_event and cancel_event.is_set():
            result["status"] = "cancelled"
            result["error_message"] = "Cancelled by user"
            return result
        ...
```

3. Add `DELETE /api/tasks/{task_id}` support for running tasks (currently blocked by the `if row["status"] not in ("queued", "failed")` guard).

**Effort**: ~2 days.

---

#### 3.1.3 WebSocket / SSE Event Streaming (⭐ High Priority)

**Problem**: The Flutter app polls every 3 seconds. This adds latency and wastes bandwidth on idle connections.

**Solution**: Add a WebSocket endpoint alongside the existing polling endpoint. The worker already has events in memory (the `event_batch` list). Propagate them through an `asyncio.Queue` to the WebSocket handler:

```python
# main.py — proposed new endpoint
@app.websocket("/api/tasks/{task_id}/ws")
async def task_events_ws(websocket: WebSocket, task_id: str):
    await websocket.accept()
    queue = asyncio.Queue()
    subscribe_to_task(task_id, queue)
    try:
        while True:
            event = await queue.get()
            await websocket.send_json(event)
    except WebSocketDisconnect:
        unsubscribe_from_task(task_id, queue)
```

The Flutter app should prefer WebSocket with a polling fallback.

**Effort**: ~3 days backend + 2 days Flutter.

---

#### 3.1.4 Interactive Conversations (Reply to Agent)

**Problem**: The current architecture is fire-and-forget. You submit a prompt and watch. You cannot answer the agent's clarifying questions.

**Solution**: OpenHands Cloud supports sending follow-up messages to a running conversation. Add a `POST /api/tasks/{task_id}/reply` endpoint that calls the Cloud API:

```python
# Proposed — agent_runner.py
def send_reply(conversation_id: str, message: str) -> dict:
    resp = httpx.post(
        f"{CLOUD_API_URL}/api/v1/conversation/{conversation_id}/messages",
        headers=_get_headers(),
        json={"content": [{"type": "text", "text": message}]},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()
```

On the Flutter side, add a text input bar at the bottom of `LiveFeedScreen` that appears when the task is running.

**Effort**: ~3 days backend + 2 days Flutter.

---

#### 3.1.5 iOS Support

**Problem**: Flutter compiles to iOS, but VibeCode is Android-only.

**Solution**: The Flutter code uses no Android-specific APIs except Firebase. Firebase works on iOS with minor config changes:

1. Add `GoogleService-Info.plist` to `ios/Runner/`.
2. Update `ios/Podfile` with Firebase pods.
3. Request notification permissions for iOS (already handled generically in `notification_service.dart`).
4. Test on an iOS simulator or device.

The `pubspec.yaml`, `lib/` code, and provider architecture are all platform-agnostic.

**Effort**: ~2 days configuration + Apple Developer account setup.

---

#### 3.1.6 Health Dashboard & Metrics

**Problem**: The server has no observability beyond `journalctl` logs.

**Solution**: Add a lightweight metrics collection system:

```python
# Proposed — monitor.py
from prometheus_client import Counter, Histogram, generate_latest

tasks_created = Counter("vibecode_tasks_created", "Tasks created")
tasks_completed = Counter("vibecode_tasks_completed", "Tasks completed")
task_duration = Histogram("vibecode_task_duration_seconds", "Task duration")

@app.get("/api/metrics")
async def metrics():
    return Response(generate_latest(), media_type="text/plain")
```

Also add a `/api/health` extended view showing: uptime, DB size, queued/running/completed counts, FCM token count, worker pool utilisation.

**Effort**: ~2 days backend.

---

### 3.2 Mid-Term (v2.x — 3–9 months)

These require architectural changes and more testing but unlock significant new value.

---

#### 3.2.1 Multi-User Support with Authentication

**Problem**: Anyone who can reach the server can submit tasks, view all tasks, delete tasks, and reconfigure the LLM.

**Solution**: Add JWT-based authentication with user registration:

1. **Database**: Add `users` table with hashed passwords (bcrypt).
2. **Auth endpoints**: `POST /api/auth/register`, `POST /api/auth/login` (returns JWT).
3. **Middleware**: FastAPI dependency that validates `Authorization: Bearer <token>` on all endpoints.
4. **Data isolation**: Add `user_id` foreign key to `tasks`, `events`, `fcm_tokens` tables. Scope all queries to the authenticated user.
5. **Flutter**: Add login/register screens before the setup screen.

**Effort**: ~5 days backend (auth system, DB migration, scoping queries) + 3 days Flutter.

**Risks**: Backward-incompatible DB schema change. Migration script needed for existing deployments.

---

#### 3.2.2 PostgreSQL Migration

**Problem**: SQLite cannot handle concurrent writes from multi-user workloads.

**Solution**: Replace `aiosqlite` with `asyncpg` (PostgreSQL async driver):

```python
# database.py — proposed change
import asyncpg

_pool: asyncpg.Pool | None = None

async def get_db_ctx():
    conn = await _pool.acquire()
    try:
        yield conn
    finally:
        await _pool.release()
```

The schema is already clean and relational (foreign keys, indexes, WAL). Migration is straightforward:
- Replace `?` placeholders with `$1, $2, ...`.
- Replace `db.execute()` with `conn.execute()` (asyncpg API is similar).
- Add a migration framework (Alembic).

**Effort**: ~4 days backend + 1 day migration script + testing.

**Note**: Should be done concurrently with or immediately after multi-user auth (3.2.1), as they are strongly coupled.

---

#### 3.2.3 Conversation History & Search

**Problem**: After a task completes, users can only see the live feed for that session. There's no persistent, searchable history.

**Solution**: The events are already stored in SQLite/Postgres. Add:

1. **Backend**: `GET /api/conversations/{task_id}/history` — returns all events paginated with optional date range filters. Add full-text search on `prompt` and event `message_json` fields using PostgreSQL `tsvector`.
2. **Flutter**: A "History" tab on the home screen showing completed tasks with preview snippets. Tap to view the full conversation thread. Search bar at top.

**Effort**: ~3 days backend + 3 days Flutter.

---

#### 3.2.4 Scheduled & Recurring Tasks

**Problem**: Tasks can only be triggered manually from the phone.

**Solution**: Add a cron-like scheduling system:

```python
# Proposed — scheduler.py
# Stores cron expressions in the DB. A background coroutine
# evaluates them and creates queued tasks at the right time.

CREATE TABLE scheduled_tasks (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    prompt TEXT NOT NULL,
    repo TEXT NOT NULL,
    branch TEXT NOT NULL DEFAULT 'main',
    mode TEXT NOT NULL DEFAULT 'code',
    cron_expression TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    last_run_at TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

Endpoints: `POST /api/schedules`, `GET /api/schedules`, `DELETE /api/schedules/{id}`.

Flutter: A schedule creation screen with a cron helper UI (preset options: "every morning at 8am", "every Monday", etc.).

**Effort**: ~4 days backend + 3 days Flutter.

---

#### 3.2.5 iOS Release & App Store Readiness

**Problem**: The app is sideloaded via APK. For wider distribution, it needs to be on the App Store and Play Store.

**Solution**:

1. **Play Store**: Already most of the way there — configure app signing, generate an AAB, submit.
2. **App Store**: Requires Apple Developer Program ($99/year). The Flutter app needs iOS-specific:
   - App icons (all required sizes).
   - Launch screen storyboard.
   - Privacy manifest (`PrivacyInfo.xcprivacy`).
   - TestFlight beta distribution setup.
3. **CI/CD**: Add GitHub Actions for building both Android (AAB) and iOS (IPA) on push to `main`.

**Effort**: ~5 days for store readiness + CI/CD setup. Ongoing: App Store review back-and-forth.

---

#### 3.2.6 File & Image Upload Support

**Problem**: Prompts are text-only. Users cannot attach screenshots, error logs, or reference files.

**Solution**:

1. Add `POST /api/upload` endpoint accepting multipart form data. Store files in `data/uploads/` with UUID filenames.
2. Extend `PromptRequest` to accept optional `attachment_ids: list[str]`.
3. In `agent_runner.py`, clone the repo and also write uploaded files into the sandbox workspace before starting the conversation, OR pass them as part of the initial message (OpenHands Cloud supports file content in messages).
4. Flutter: Add an attachment button in the home screen's prompt input area. Use `image_picker` for camera/gallery. Show thumbnails before sending.

**Effort**: ~4 days backend + 3 days Flutter.

---

### 3.3 Long-Term (v3.x — 9–18 months)

These are transformative features that change the product category.

---

#### 3.3.1 Autonomous Agent Mode

**Problem**: The agent only runs when a user explicitly submits a prompt. It's reactive, not proactive.

**Vision**: VibeCode becomes an autonomous coding assistant that watches your repositories and acts on its own:

- **PR Review Bot**: Configured to watch a GitHub repo. When a new PR opens, VibeCode auto-starts an agent to review it and posts feedback.
- **Issue Triage Bot**: Watches GitHub issues. Labels, prioritises, and even creates fix PRs for simple issues.
- **Daily Standup Bot**: Every morning at 9am, pulls the latest code, runs tests, checks CI status, and sends a summary.
- **Dependency Updater**: Weekly scan for outdated dependencies, creates PRs with version bumps.

This requires:
- Webhook ingestion (`POST /api/webhooks/github`).
- Trigger configuration UI (what event → what prompt template → what repo).
- Agent output routing (PR comment, Slack message, email, etc.).
- A credit/usage tracking system for cost control.

**Effort**: ~3–6 months of focused development. This is essentially a new product built on the same core.

---

#### 3.3.2 Collaboration & Shared Workspaces

**Problem**: VibeCode is single-user. Teams cannot share tasks, view each other's agent outputs, or collaborate on prompts.

**Vision**: Team workspaces where multiple users share a server:

- **Roles**: Admin, Member, Viewer.
- **Shared task feed**: Everyone on the team sees all tasks (or filtered by project).
- **Comment on agent outputs**: Inline comments on specific events in the live feed.
- **Prompt templates**: Team-shared prompt snippets ("fix lint errors in repo X", "add unit tests for module Y").
- **Usage dashboard**: Per-user and per-repo usage stats, cost tracking.

**Effort**: ~4–6 months. Requires completed multi-user auth (3.2.1), PostgreSQL (3.2.2), and a new collaboration service layer.

---

#### 3.3.3 On-Premise / Self-Hosted Agent Runtimes

**Problem**: VibeCode depends entirely on OpenHands Cloud. Users with sensitive codebases or air-gapped environments cannot use it.

**Vision**: Allow the backend to run agents locally using the OpenHands SDK in-process instead of routing everything through the Cloud API:

```python
# Proposed — local_agent_runner.py
from openhands.sdk import Agent

async def run_local_conversation(prompt, repo, branch, event_callback):
    agent = Agent(
        llm_config=...,
        workspace_dir=f"/tmp/vibecode-workspaces/{task_id}",
    )
    async for event in agent.run(prompt):
        event_callback(event)
```

This would require:
- Docker-in-Docker or sandbox management for workspace isolation.
- Resource limits (CPU, memory, timeouts).
- Git clone and branch checkout within the workspace.
- A "runtime mode" selector in settings: Cloud vs Local.

**Effort**: ~3–4 months. The OpenHands SDK already supports local execution; the work is in sandbox management, security hardening, and UX.

---

#### 3.3.4 Desktop & Web Client

**Problem**: VibeCode is mobile-only. Power users want a desktop experience with keyboard shortcuts, multi-tab conversations, and larger code views.

**Vision**:

- **Flutter Desktop**: The existing Flutter codebase compiles to macOS, Windows, and Linux with minimal changes (Flutter 3.x has stable desktop support). Add keyboard shortcuts, window management, and a code-diff viewer.
- **Web Dashboard**: A React/Next.js web app (or Flutter Web) that provides the full VibeCode experience in a browser. This becomes the primary interface for the collaboration features (3.3.2).

**Effort**: Flutter desktop — ~2 weeks (mostly testing and platform-specific polish). Web dashboard — ~2–3 months.

---

#### 3.3.5 Agent Skill Marketplace

**Problem**: Every user writes prompts from scratch. There's no way to share, discover, or reuse effective prompts.

**Vision**: A marketplace of "Agent Skills" — curated prompt templates with parameters:

```yaml
# Example: fix-linting.yaml
name: "Fix Linting Errors"
description: "Runs the project linter and fixes all reported issues"
parameters:
  - name: linter
    type: select
    options: ["eslint", "ruff", "clippy", "golangci-lint"]
  - name: auto_fix
    type: boolean
    default: true
prompt_template: |
  Repository: {{repo}} (branch: {{branch}}).
  Run {{linter}} on the entire codebase. For each error found, fix it.
  {% if auto_fix %}Automatically apply fixes.{% endif %}
  Create a PR with the changes.
```

- Skills are stored as YAML/JSON files in a community GitHub repo.
- The Flutter app has a "Browse Skills" screen that fetches from this repo.
- Users can install skills locally or submit their own.
- The backend loads skill templates at runtime.

**Effort**: ~2–3 months. This is both a product and a community-building initiative.

---

## 4. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **OpenHands Cloud API breaking changes** | Medium | High — entire product depends on it | Pin API version. Monitor changelog. Add local runtime (3.3.3) as fallback. |
| **LLM cost overruns** | High | Medium — unattended agents can burn credits | Add per-task token budget. Add cost tracking to metrics. Require confirmation for tasks > estimated cost. |
| **SQLite corruption under concurrency** | Medium | High — data loss | Migrate to PostgreSQL (3.2.2) before enabling concurrent workers. |
| **Security: unauthenticated API** | High | High — anyone can consume LLM credits | Add auth (3.2.1) as the very next major feature after concurrent processing. |
| **FCM token drift** | Low | Medium — push notifications silently fail | Already handled: `onTokenRefresh` listener. Add periodic token validation. |
| **App Store rejection** | Medium | Medium — delays iOS launch | Review App Store guidelines early. Avoid features that require private APIs. |
| **Agent producing harmful code** | Low | High — could damage user's repos | Agents run in sandboxes by default. Add a "dry-run" mode that shows diffs without applying. |
| **Single point of failure (GCP VM)** | Medium | Medium — server downtime = no service | Add health-check monitoring. For v3: multi-region deployment. |

---

## 5. Priority Matrix

```
                    Low Effort               High Effort
                 ┌─────────────────┬─────────────────────┐
  High Impact    │ 3.1.1 Concurrent│ 3.2.1 Multi-User     │
                 │ 3.1.2 Cancel    │ 3.2.2 PostgreSQL     │
                 │ 3.1.3 WebSocket │ 3.3.1 Autonomous     │
                 │ 3.1.4 Reply     │ 3.3.2 Collaboration  │
                 │ 3.1.6 Metrics   │                      │
                 ├─────────────────┼─────────────────────┤
  Low Impact     │ 3.1.5 iOS       │ 3.2.4 Scheduling     │
                 │ 3.2.6 Uploads   │ 3.2.5 App Stores     │
                 │ 3.2.3 History   │ 3.3.4 Desktop/Web     │
                 │                 │ 3.3.5 Marketplace    │
                 │                 │ 3.3.3 Self-Hosted    │
                 └─────────────────┴─────────────────────┘
```

**Recommended ordering**: 3.1.1 → 3.1.2 → 3.1.4 → 3.1.3 → 3.1.6 → 3.2.1 → 3.2.2 → (re-evaluate based on user feedback).

---

## 6. Resource Estimation

| Phase | Features | Dev Effort | Testing | Total |
|-------|----------|-----------|---------|-------|
| v1.1 | Concurrent + Cancel + Reply | 7 days | 3 days | **2 weeks** |
| v1.2 | WebSocket + Metrics + iOS | 7 days | 3 days | **2 weeks** |
| v1.3 | History + Uploads | 7 days | 3 days | **2 weeks** |
| v2.0 | Auth + PostgreSQL | 9 days | 4 days | **3 weeks** |
| v2.1 | Scheduling + App Stores | 8 days | 4 days | **2.5 weeks** |
| v3.0 | Autonomous + Collaboration | 3–6 months | 1–2 months | **4–8 months** |
| v3.1 | Self-Hosted + Desktop + Marketplace | 4–6 months | 1–2 months | **5–8 months** |

All estimates assume a single experienced full-stack developer familiar with Python, Flutter, and the OpenHands SDK.

---

## 7. Immediate Recommended Actions

1. **Add concurrent task processing** (3.1.1) — largest user-facing improvement for minimal effort. Unblock the queue.
2. **Add task cancellation** (3.1.2) — essential UX feature; users expect to be able to stop a running task.
3. **Add interactive replies** (3.1.4) — transforms the product from fire-and-forget to a conversation.
4. **Add `POST /api/tasks/{task_id}/cancel` and `POST /api/tasks/{task_id}/reply` endpoints** — build these three together as the "v1.1 interaction upgrade".
5. **Begin PostgreSQL migration planning** — start an Alembic migration branch early, even if it ships later.

---

*This report was created by an AI agent (OpenHands) on behalf of Craftguy-Billies.*
