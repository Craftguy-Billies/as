"""Background task worker for VibeCode.

Processes queued tasks by running the OpenHands SDK agent in a background thread,
persists events to SQLite in real-time, and sends push notifications on completion.
"""

import asyncio
import json
import logging
import os
import threading
import time
from datetime import datetime, timezone

from database import get_db_ctx
from agent_runner import run_conversation_sync
from fcm_service import send_push_notification

logger = logging.getLogger(__name__)

# Max concurrent tasks
MAX_CONCURRENT = int(os.getenv("VIBECODE_MAX_CONCURRENT", "3"))
_active_tasks: dict[str, threading.Thread] = {}
_worker_running = False
_loop: asyncio.AbstractEventLoop | None = None


async def _save_events(db, task_id: str, events: list[dict]) -> None:
    """Save events to the database."""
    for evt in events:
        await db.execute(
            """INSERT INTO events (task_id, event_index, timestamp, kind, source,
               tool_name, action_json, observation_json, message_json, raw_json)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                task_id,
                evt.get("event_index", 0),
                evt.get("timestamp", ""),
                evt.get("kind", ""),
                evt.get("source"),
                evt.get("tool_name"),
                evt.get("action_json"),
                evt.get("observation_json"),
                evt.get("message_json"),
                evt.get("raw_json", ""),
            ),
        )
    await db.commit()


async def _update_task_status(db, task_id: str, status: str, **kwargs) -> None:
    """Update a task's status and optional fields."""
    sets = ["status = ?"]
    params: list = [status]

    for key, val in kwargs.items():
        if val is not None:
            sets.append(f"{key} = ?")
            params.append(val)

    if status in ("completed", "failed"):
        sets.append("completed_at = ?")
        params.append(datetime.now(timezone.utc).isoformat())

    params.append(task_id)
    await db.execute(f"UPDATE tasks SET {', '.join(sets)} WHERE id = ?", params)
    await db.commit()


async def _process_task(task_id: str) -> None:
    """Process a single task: run agent, save events, update status."""
    async with get_db_ctx() as db:
        # Load task
        cursor = await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
        task = await cursor.fetchone()
        if not task:
            return

        task_dict = dict(task)
        logger.info(f"Processing task {task_id}: mode={task_dict['mode']}, repo={task_dict['repo']}")

        # Mark as starting
        await _update_task_status(db, task_id, "starting")

        # Event queue for thread-safe collection
        event_queue: list[dict] = []
        queue_lock = threading.Lock()
        last_flush = time.time()
        FLUSH_INTERVAL = 10  # seconds

        loop = asyncio.get_running_loop()

        def _flush_events() -> None:
            """Thread-safe: schedule async flush on the event loop."""
            nonlocal last_flush
            with queue_lock:
                if not event_queue:
                    return
                batch = list(event_queue)
                event_queue.clear()
            last_flush = time.time()
            asyncio.run_coroutine_threadsafe(_save_events(db, task_id, batch), loop)

        def on_event(event: dict) -> None:
            with queue_lock:
                event_queue.append(event)
                should_flush = (time.time() - last_flush) >= FLUSH_INTERVAL
            if should_flush:
                _flush_events()

        def on_status(status: str) -> None:
            logger.info(f"Task {task_id} status: {status}")

        # Parse MCP config from task if present
        mcp_servers = None
        mcp_raw = task_dict.get("mcp_config")
        if mcp_raw:
            try:
                mcp_servers = json.loads(mcp_raw)
            except (json.JSONDecodeError, TypeError):
                pass

        def _run() -> dict:
            return run_conversation_sync(
                prompt=task_dict["prompt"],
                repo=task_dict["repo"],
                branch=task_dict.get("branch", "main"),
                mode=task_dict.get("mode", "code"),
                event_callback=on_event,
                status_callback=on_status,
                mcp_servers=mcp_servers,
            )

        try:
            await _update_task_status(db, task_id, "running")

            result = await loop.run_in_executor(None, _run)

            # Flush remaining events
            with queue_lock:
                remaining = list(event_queue)
                event_queue.clear()

            if remaining:
                await _save_events(db, task_id, remaining)

            if result["status"] == "completed":
                await _update_task_status(
                    db, task_id, "completed",
                    conversation_id=result.get("conversation_id"),
                    sandbox_id=result.get("sandbox_id"),
                )
                # Send push notification
                prompt_preview = task_dict["prompt"][:80] + ("..." if len(task_dict["prompt"]) > 80 else "")
                await send_push_notification(
                    db,
                    task_id,
                    "✅ Task Complete",
                    prompt_preview,
                )
            else:
                await _update_task_status(
                    db, task_id, "failed",
                    error_message=result.get("error_message", "Unknown error"),
                    conversation_id=result.get("conversation_id"),
                    sandbox_id=result.get("sandbox_id"),
                )
                await send_push_notification(
                    db,
                    task_id,
                    "❌ Task Failed",
                    result.get("error_message", "Task failed")[:120],
                )

        except Exception as e:
            import traceback
            err_detail = f"{type(e).__name__}: {e}"
            if not str(e):
                err_detail = f"{type(e).__name__} (no detail)"
            logger.error(f"Task {task_id} failed: {err_detail}\n{traceback.format_exc()}")
            await _update_task_status(db, task_id, "failed", error_message=err_detail)

        finally:
            _active_tasks.pop(task_id, None)


async def _worker_loop() -> None:
    """Main worker loop — picks up queued tasks and processes them."""
    global _worker_running
    _worker_running = True
    logger.info("Worker started")

    while _worker_running:
        try:
            # Check for queued tasks if we have capacity
            if len(_active_tasks) < MAX_CONCURRENT:
                async with get_db_ctx() as db:
                    cursor = await db.execute(
                        "SELECT id FROM tasks WHERE status = 'queued' ORDER BY created_at ASC LIMIT 1"
                    )
                    row = await cursor.fetchone()
                    if row:
                        task_id = row["id"]
                        _active_tasks[task_id] = threading.Thread(target=lambda: None)  # placeholder
                        asyncio.create_task(_process_task(task_id))

            await asyncio.sleep(2)  # Poll every 2 seconds

        except Exception as e:
            logger.error(f"Worker loop error: {e}")
            await asyncio.sleep(5)


async def start_worker() -> None:
    """Start the background worker."""
    global _loop
    _loop = asyncio.get_running_loop()
    asyncio.create_task(_worker_loop())


async def stop_worker() -> None:
    """Stop the background worker gracefully."""
    global _worker_running
    _worker_running = False
    logger.info("Worker stopping...")
