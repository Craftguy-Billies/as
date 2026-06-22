"""Background task worker for VibeCode.

Processes queued tasks ONE AT A TIME (sequential) by running the OpenHands
Cloud API agent in a background thread. Persists events to SQLite in real-time,
and sends push notifications on completion.

The worker runs on the SERVER — closing the phone does NOT stop processing.
Tasks stay queued in SQLite until the worker picks them up. Unlimited queue
depth — you can submit as many tasks as you want; they process one by one.
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

# Sequential processing — one task at a time to avoid git conflicts
MAX_CONCURRENT = 1
_active_tasks: set[str] = set()
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
    logger.info("Saved %d events for task %s", len(events), task_id[-8:])


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
    try:
        async with get_db_ctx() as db:
            cursor = await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
            task = await cursor.fetchone()
            if not task:
                return

            task_dict = dict(task)
            task_repo = task_dict.get("repo", "") or ""
            task_branch = task_dict.get("branch", "") or ""
            task_mode = task_dict.get("mode", "code") or "code"
            logger.info("[worker] task %s START: repo=%s branch=%s mode=%s prompt=%.80s",
                       task_id, task_repo, task_branch, task_mode, task_dict.get("prompt", ""))

            if not task_repo:
                logger.error("[worker] task %s: no repo — cannot run", task_id)
                await _update_task_status(db, task_id, "failed", error_message="No repository specified")
                return

            await _update_task_status(db, task_id, "starting")

            event_queue: list[dict] = []
            queue_lock = threading.Lock()
            last_flush = time.time()
            FLUSH_INTERVAL = 10

            loop = asyncio.get_running_loop()

            def _flush_events() -> None:
                nonlocal last_flush
                with queue_lock:
                    if not event_queue:
                        return
                    batch = list(event_queue)
                    event_queue.clear()
                last_flush = time.time()
                future = asyncio.run_coroutine_threadsafe(_save_events(db, task_id, batch), loop)
                future.add_done_callback(lambda f: (
                    logger.error("Event save failed: %s", f.exception())
                ) if f.exception() else None)

            def on_event(event: dict) -> None:
                with queue_lock:
                    event_queue.append(event)
                    should_flush = (time.time() - last_flush) >= FLUSH_INTERVAL
                if should_flush:
                    _flush_events()

            def on_status(status: str) -> None:
                logger.info(f"Task {task_id} status: {status}")

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
                    repo=task_repo,
                    branch=task_branch,
                    mode=task_mode,
                    event_callback=on_event,
                    status_callback=on_status,
                    mcp_servers=mcp_servers,
                )

            await _update_task_status(db, task_id, "running")

            result = await loop.run_in_executor(None, _run)

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
                prompt_preview = task_dict["prompt"][:80] + ("..." if len(task_dict["prompt"]) > 80 else "")
                await send_push_notification(db, task_id, "Task Complete", prompt_preview)
                # Append to VIBECODER_LOG.md
                try:
                    from chat_service import _auto_append_log
                    _auto_append_log(task_dict.get("repo", ""), task_dict["prompt"], result.get("response", ""), ok=True)
                except Exception:
                    pass
            else:
                await _update_task_status(
                    db, task_id, "failed",
                    error_message=result.get("error_message", "Unknown error"),
                    conversation_id=result.get("conversation_id"),
                    sandbox_id=result.get("sandbox_id"),
                )
                await send_push_notification(
                    db, task_id, "Task Failed",
                    result.get("error_message", "Task failed")[:120],
                )
                # Append failure to VIBECODER_LOG.md
                try:
                    from chat_service import _auto_append_log
                    _auto_append_log(task_dict.get("repo", ""), task_dict["prompt"], result.get("error_message", ""), ok=False)
                except Exception:
                    pass

    except Exception as e:
        import traceback
        err_detail = f"{type(e).__name__}: {e}"
        if not str(e):
            err_detail = f"{type(e).__name__} (no detail)"
        logger.error(f"Task {task_id} failed: {err_detail}\n{traceback.format_exc()}")
        try:
            async with get_db_ctx() as db2:
                await _update_task_status(db2, task_id, "failed", error_message=err_detail)
        except Exception:
            logger.error(f"Failed to update task {task_id} status after exception")

    finally:
        _active_tasks.discard(task_id)


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
                        _active_tasks.add(task_id)
                        asyncio.create_task(_process_task(task_id))

            await asyncio.sleep(2)  # Poll every 2 seconds

        except Exception as e:
            logger.error(f"Worker loop error: {e}")
            await asyncio.sleep(5)


async def start_worker() -> None:
    """Start the background worker. Recovers orphaned tasks from previous crashes."""
    global _loop
    _loop = asyncio.get_running_loop()

    # Recover orphaned tasks from unclean shutdown
    try:
        async with get_db_ctx() as db:
            await db.execute(
                "UPDATE tasks SET status = 'failed', error_message = 'Server restarted — task was in progress' "
                "WHERE status IN ('starting', 'running')"
            )
            await db.commit()
    except Exception as e:
        logger.error("Orphan recovery failed: %s", e)

    asyncio.create_task(_worker_loop())


async def stop_worker() -> None:
    """Stop the background worker gracefully."""
    global _worker_running, _loop
    _worker_running = False
    _loop = None
    logger.info("Worker stopping...")
