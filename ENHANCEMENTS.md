# 🔍 Enhancement Opportunities for VibeCode

Based on research across the OpenHands Cloud API, SDK, and analysis of the current codebase.

---

## 1. ⚡ Fix The Broken Live Feed (Critical Bug First)

**Problem**: Events are collected in `event_queue` inside `_process_task()` but only flushed to SQLite *after* `run_in_executor` returns (line 112-120 in `worker.py`). That means the Flutter app sees **zero events** until the entire task completes — the `GET /api/tasks/{id}/events` endpoint returns empty during the task. The live feed is completely broken.

**Fix**: Periodically flush events to DB during the task. Use an `asyncio.Task` that drains the queue and calls `_save_events()` every 2-3 seconds while the agent runs.

---

## 2. 🔗 Migrate V0 → V1 API (V0 Deprecated April 2026)

The `agent_runner.py` already uses V1 endpoints (`/api/v1/app-conversations`), which is good. But there are additional V1 capabilities not yet leveraged:

- **Streaming start** (`POST /api/v1/app-conversations/stream-start`) — get real-time status updates as the conversation starts (WORKING → WAITING_FOR_SANDBOX → PREPARING_REPOSITORY → SETTING_UP_SKILLS → READY). Currently the code polls with 5s intervals in a for-loop; streaming would be faster and show meaningful progress in the UI.
- **`waiting_for_confirmation` execution status** — the agent can pause waiting for user input. Currently not handled, so the task would hang forever. Add this as a terminal state.
- **Sandbox control** — `POST /api/v1/sandboxes/{id}/pause` and `/resume` — allow users to pause/resume long-running tasks from the app.

---

## 3. 📹 Screenshot/PR Review Embedding in Event Feed

OpenHands Cloud conversations generate artifacts (PRs, comments, code diffs). The API returns events with action/observation data already being captured. Enhance the Flutter `EventCard` to render:

- **Inline code diffs** — prettified diff view for file edit events
- **PR link previews** — when the agent opens a PR, show the PR title/status with a deep link
- **Screenshots** — when available, show thumbnail previews in the feed

---

## 4. 🔐 API Key Authentication (Security)

Currently the backend is wide open — CORS `*`, no auth. Anyone can submit prompts. Add:

- **Simple shared API key auth** — a `X-API-Key` header checked via middleware. Add an endpoint `POST /api/connect` that returns a JWT or session token after validating a pre-shared secret.
- **Task ownership** — associate tasks with a device/client ID so different devices don't see each other's tasks.

---

## 5. 🔄 WebSocket Real-Time Streaming

Replace the dual-polling (Flutter→backend every 3s, backend→Cloud API every 3s) with:

- **Backend WebSocket** — `fastapi.WebSocket` endpoint at `/api/ws/tasks/{id}/events` that pushes events as they arrive from the Cloud API.
- **Flutter** — `web_socket_channel` package for real-time event rendering without polling.
- This reduces latency from ~6s (two poll cycles) to sub-second.

---

## 6. 🧵 Periodic Event Flush via Background asyncio.Task

Instead of collecting all events in memory and flushing only at the end:

```python
async def _flush_loop(event_queue, queue_lock, db, task_id, stop_event):
    while not stop_event.is_set():
        await asyncio.sleep(2)
        with queue_lock:
            batch = list(event_queue)
            event_queue.clear()
        if batch:
            await _save_events(db, task_id, batch)
```

This fixes the live feed without changing the agent_runner threading model.

---

## 7. ⏱️ Task Timeout & Cancellation

No timeout exists — a hung conversation runs forever. Add:

- Configurable timeout per task (env: `VIBECODE_TASK_TIMEOUT_SECONDS`, default 1800 = 30 min)
- `DELETE /api/tasks/{id}` extended to cancel running tasks (currently only queued/failed). Use the sandbox pause API, or `asyncio.wait_for()` with timeout.
- `PATCH /api/tasks/{id}/cancel` endpoint that sets a cancellation flag checked in the polling loop.

---

## 8. 🧹 Event Retention & Cleanup

The `events` table grows unbounded. Add:

- **Retention policy**: configurable max events per task or max age
- **Cron cleanup**: delete events older than N days
- **Task archival**: mark old tasks as `archived` rather than deleting

---

## 9. 📊 Task History & Conversation Search

The OpenHands API supports `/api/v1/app-conversations/search`. Use this to:

- Sync conversation IDs from the Cloud to the local DB
- Allow users to browse their full OpenHands conversation history from the app
- Add a `GET /api/conversations` that proxies to the Cloud search endpoint
- Show conversation status (sandbox_status, execution_status) in the task list

---

## 10. 🤖 Automations / Scheduled Tasks

OpenHands Cloud supports event-based automations (cron triggers). Enhance VibeCode to:

- Allow scheduling recurring tasks (e.g., "run tests every morning")
- First-class support for the OpenHands automation hooks
- A `cron_expression` field on the prompt request to schedule future runs

---

## 11. 🎨 Multi-Agent / Sub-Agent Delegation

OpenHands SDK supports sub-agent delegation for complex tasks. Enhance the prompt builder to:

- Support a "team" mode that spawns planning agent + implementation agent
- Add mode options: `code`, `plan`, `review` (code review only), `refactor`
- Pass `agent_config` with specialized agent instructions per mode

---

## 12. 🔔 Richer Push Notifications

Current push only fires on complete/fail. Add:

- **Progress notifications**: "Agent is working on your task..." when status changes to running
- **Blocked notification**: when `execution_status == "waiting_for_confirmation"`, notify user to check the UI
- **Notification channels**: separate channels for task updates vs errors
- **Actionable notifications**: "Retry" and "View" buttons in the Android notification itself

---

## 13. 🧪 Observability & Health

- Add `/api/health` checks for: OpenHands Cloud API connectivity, FCM service status, DB health
- Structured logging (replace `print()` with `logging` everywhere)
- A `/api/stats` endpoint showing: active tasks, total completed, error rate, average task duration
- Prometheus metrics endpoint for monitoring (task count, latency, error rate)

---

## 14. 📱 Flutter Enhancements

- **Offline queue**: queue prompts locally when backend is unreachable, sync when back online
- **Background fetch**: `workmanager` package to check task status even when app is backgrounded
- **Rich notifications**: tap notification → navigate directly to the task's live feed
- **Dark/light theme toggle**: currently hardcoded dark theme
- **Widget homescreen**: show latest task status on home screen widget

---

## 15. 🛡️ Input Validation & Rate Limiting

- **Rate limit** `POST /api/prompts` per client (e.g., 10/minute)
- **Max prompt length** enforced server-side
- **Repo format validation** (must match `owner/repo` pattern)
- **Branch validation** — reject empty/invalid branch names

---

## Summary: Priority Order

| # | Enhancement | Impact | Effort |
|---|---|---|---|
| 1 | Fix live feed event flushing | 🔴 Critical bug | Small |
| 2 | Periodic event flush in worker | 🔴 Critical bug | Small |
| 3 | Handle `waiting_for_confirmation` status | 🔴 Hang risk | Tiny |
| 4 | API key authentication | 🔴 Security | Medium |
| 5 | WebSocket real-time streaming | 🟡 UX | Medium |
| 6 | Streaming conversation start | 🟡 UX | Small |
| 7 | Task timeout & cancellation | 🟡 Reliability | Medium |
| 8 | Richer push notifications | 🟡 Engagement | Small |
| 9 | Input validation & rate limiting | 🟡 Security | Small |
| 10 | Event retention cleanup | 🟢 Maintenance | Small |
| 11 | Multi-agent modes (plan → implement) | 🟢 Feature | Medium |
| 12 | Task history / conversation sync | 🟢 Feature | Medium |
