"""VibeCode Backend — FastAPI server with OpenHands SDK integration.

Entry point: uv run uvicorn main:app --host 0.0.0.0 --port 8080
"""

import asyncio
import logging
import os
import uuid
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from database import get_db_ctx, init_db
from models import (
    BaseModel,
    PromptRequest,
    LLMConfigRequest,
    GitConfigRequest,
    FCMTokenRequest,
    TaskResponse,
    EventResponse,
    HealthResponse,
    TasksListResponse,
    EventsListResponse,
)
from agent_runner import get_llm_config, set_llm_config, AgentConfig, get_git_config, set_git_config
from worker import start_worker, stop_worker
from fcm_service import init_firebase

load_dotenv()

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

# In-memory rotating log buffer for /api/logs endpoint
import threading as _threading
_log_buffer: deque[str] = deque(maxlen=500)
_log_buffer_lock = _threading.Lock()


class _BufferHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        with _log_buffer_lock:
            _log_buffer.append(self.format(record))


_buffer_handler = _BufferHandler()
_buffer_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s %(message)s"))
logging.getLogger().addHandler(_buffer_handler)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: init DB, Firebase, Worker on startup; cleanup on shutdown."""
    await init_db()
    init_firebase()
    await start_worker()
    logger.info("VibeCode backend started")
    yield
    await stop_worker()
    logger.info("VibeCode backend stopped")


app = FastAPI(
    title="VibeCode Backend",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/api/health", response_model=HealthResponse)
async def health():
    cfg = get_llm_config()
    return HealthResponse(
        status="ok",
        model=cfg.model,
        version="1.0.0",
    )


@app.get("/api/logs")
async def view_logs(lines: int = Query(200, ge=1, le=500)):
    """Return the last N lines of server logs."""
    with _log_buffer_lock:
        return {"lines": list(_log_buffer)[-lines:]}


@app.get("/api/logs/stream")
async def stream_logs():
    """Return all buffered logs (up to 500 lines)."""
    with _log_buffer_lock:
        return {"lines": list(_log_buffer)}


# ---------------------------------------------------------------------------
# Chat (token-efficient conversation reuse)
# ---------------------------------------------------------------------------

from chat_service import send as chat_send, reset as chat_reset, get_state as chat_state, get_repos as chat_repos, get_task_log as chat_task_log, enqueue_batch as chat_enqueue_batch, cancel_batch as chat_cancel_batch, cancel_batch_prompt as chat_cancel_batch_prompt, get_branches as chat_branches


class ChatRequest(BaseModel):
    prompt: str
    repo: str = ""
    branch: str = ""
    mode: str = "code"  # "code" or "plan", validated in endpoint


@app.post("/api/chat")
async def chat_send_message(req: ChatRequest):
    """Send a chat message. Reuses conversation across requests for token savings."""
    if req.mode not in ("code", "plan"):
        raise HTTPException(status_code=400, detail="mode must be 'code' or 'plan'")
    if not req.repo.strip():
        raise HTTPException(status_code=400, detail="repo is required")
    import re as _re
    if not _re.match(r'^[\w.-]+/[\w.-]+$', req.repo.strip()):
        raise HTTPException(status_code=400, detail=f"Invalid repo format: '{req.repo}'. Use owner/repo")
    loop = asyncio.get_running_loop()
    try:
        result = await loop.run_in_executor(None, chat_send, req.prompt, req.repo.strip(), req.branch.strip(), req.mode)
    except Exception as e:
        logger.error("chat_send_message UNEXPECTED EXCEPTION: %s", e, exc_info=True)
        raise HTTPException(status_code=500, detail="Something went wrong. Please try again.")
    if "error" in result:
        logger.warning("chat_send_message error: %s", result["error"])
        raise HTTPException(status_code=502, detail=result["error"])
    return result


@app.get("/api/chat")
async def chat_get(repo: str = Query(""), mode: str = Query("")):
    """Return current chat session state (messages + conversation_id).
    Pass ?repo=owner/repo&mode=code to switch active repo.
    """
    try:
        result = chat_state(repo=repo.strip(), mode=mode)
        logger.debug("chat_get: repo=%s mode=%s msgs=%d", repo or '(none)', mode or '(none)', len(result.get("messages", [])))
        return result
    except Exception as e:
        logger.error("chat_get EXCEPTION: repo=%s mode=%s error=%s", repo, mode, e, exc_info=True)
        return {"messages": [], "conversation_id": None, "sandbox_id": None, "repo": "", "branch": "", "mode": "code", "current_repo_key": "", "conversation_status": "idle", "batch": {"running": False, "cancelled": False, "position": 0, "total": 0, "done": 0, "prompts": [], "modes": []}}


@app.get("/api/chat/repos")
async def chat_list_repos():
    """Return list of all repos that have chat history."""
    try:
        repos = chat_repos()
        logger.debug("chat_list_repos: %d repos", len(repos))
        return {"repos": repos}
    except Exception as e:
        logger.error("chat_list_repos EXCEPTION: %s", e, exc_info=True)
        return {"repos": []}


@app.get("/api/chat/log")
async def chat_task_log_entries(repo: str = Query("")):
    """Return parsed VIBECODER_LOG.md entries for a repo."""
    if not repo:
        return []
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, chat_task_log, repo.strip())
        return result
    except Exception as e:
        logger.error("chat_task_log_entries EXCEPTION: repo=%s error=%s", repo, e, exc_info=True)
        return []


@app.get("/api/chat/branches")
async def chat_branches_list(repo: str = Query("")):
    """Return branch list for a GitHub repo."""
    if not repo:
        return []
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, chat_branches, repo.strip())
        logger.debug("chat_branches_list: repo=%s branches=%d", repo, len(result))
        return result
    except Exception as e:
        logger.error("chat_branches_list EXCEPTION: repo=%s error=%s", repo, e, exc_info=True)
        return []


@app.delete("/api/chat")
async def chat_clear():
    """Reset the chat session (start fresh conversation next time)."""
    try:
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, chat_reset)
        logger.info("chat_clear: session reset by user")
        return {"ok": True}
    except Exception as e:
        logger.error("chat_clear EXCEPTION: %s", e, exc_info=True)
        return {"ok": False, "error": "Failed to clear chat. Try again."}


class BatchRequest(BaseModel):
    prompts: list[str]
    repo: str = ""
    branch: str = ""
    mode: str = "code"


@app.post("/api/chat/batch")
async def chat_batch(req: BatchRequest):
    """Enqueue a batch of prompts — processed sequentially in one conversation.
    
    Returns immediately. Processing happens in background.
    Poll /api/chat to see progress and new messages.
    """
    if req.mode not in ('code', 'plan'):
        raise HTTPException(status_code=400, detail="mode must be 'code' or 'plan'")
    if not req.prompts:
        raise HTTPException(status_code=400, detail="prompts list is empty")
    if not req.repo.strip():
        raise HTTPException(status_code=400, detail="repo is required")
    import re as _re
    if not _re.match(r'^[\w.-]+/[\w.-]+$', req.repo.strip()):
        raise HTTPException(status_code=400, detail=f"Invalid repo format: '{req.repo}'. Use owner/repo")
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(
            None, chat_enqueue_batch, req.prompts, req.repo.strip(), req.branch.strip(), req.mode
        )
        if "error" in result:
            logger.warning("chat_batch error: %s", result["error"])
            raise HTTPException(status_code=400, detail=result["error"])
        logger.info("chat_batch: %d prompts enqueued for repo=%s branch=%s mode=%s",
                    len(req.prompts), req.repo, req.branch, req.mode)
        return result
    except HTTPException:
        raise
    except Exception as e:
        logger.error("chat_batch UNEXPECTED EXCEPTION: %s", e, exc_info=True)
        raise HTTPException(status_code=500, detail="Something went wrong. Please try again.")


@app.post("/api/chat/batch/cancel")
async def chat_batch_cancel():
    """Cancel the running batch queue."""
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, chat_cancel_batch)
        logger.info("chat_batch_cancel: batch cancelled")
        return result
    except Exception as e:
        logger.error("chat_batch_cancel EXCEPTION: %s", e, exc_info=True)
        return {"status": "error", "error": "Failed to cancel. Try again."}


@app.post("/api/chat/batch/cancel/{index}")
async def chat_batch_cancel_prompt(index: int):
    """Cancel a single prompt by index in the batch queue."""
    try:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(None, chat_cancel_batch_prompt, index)
        logger.info("chat_batch_cancel_prompt: index=%d result=%s", index, result)
        return result
    except Exception as e:
        logger.error("chat_batch_cancel_prompt EXCEPTION: index=%d error=%s", index, e, exc_info=True)
        return {"status": "error", "error": "Failed to cancel. Try again."}


# ---------------------------------------------------------------------------
# Prompts (Tasks)
# ---------------------------------------------------------------------------

@app.post("/api/prompts", response_model=TaskResponse, status_code=201)
async def create_prompt(req: PromptRequest):
    """Submit a new coding prompt. Creates a task and queues it for processing."""
    import json as _json
    task_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    try:
        mcp_json = _json.dumps([m.model_dump() for m in req.mcp_servers]) if req.mcp_servers else None
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid MCP server config: {e}")

    try:
        async with get_db_ctx() as db:
            await db.execute(
                """INSERT INTO tasks (id, prompt, repo, branch, mode, status, created_at, mcp_config)
                   VALUES (?, ?, ?, ?, ?, 'queued', ?, ?)""",
                (task_id, req.prompt, req.repo, req.branch, req.mode, now, mcp_json),
            )
            await db.commit()
    except Exception as e:
        logger.error("Failed to create prompt: %s", e, exc_info=True)
        raise HTTPException(status_code=500, detail="Failed to create prompt. Try again.")

    logger.info(f"Task {task_id} created: repo={req.repo}, mode={req.mode}")
    return TaskResponse(
        id=task_id,
        prompt=req.prompt,
        repo=req.repo,
        branch=req.branch,
        mode=req.mode,
        status="queued",
        created_at=now,
    )


# ---------------------------------------------------------------------------
# Tasks list
# ---------------------------------------------------------------------------

@app.get("/api/tasks", response_model=TasksListResponse)
async def list_tasks(
    status: str | None = Query(None, description="Filter by status"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
):
    """List all tasks, newest first. Optional status filter."""
    async with get_db_ctx() as db:
        if status:
            cursor = await db.execute(
                "SELECT * FROM tasks WHERE status = ? ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (status, limit, offset),
            )
        else:
            cursor = await db.execute(
                "SELECT * FROM tasks ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (limit, offset),
            )
        rows = await cursor.fetchall()

    tasks = [
        TaskResponse(
            id=row["id"],
            prompt=row["prompt"],
            repo=row["repo"],
            branch=row["branch"],
            mode=row["mode"],
            status=row["status"],
            conversation_id=row["conversation_id"],
            sandbox_id=row["sandbox_id"],
            created_at=row["created_at"],
            completed_at=row["completed_at"],
            error_message=row["error_message"],
        )
        for row in rows
    ]

    return TasksListResponse(tasks=tasks)


# ---------------------------------------------------------------------------
# Single task
# ---------------------------------------------------------------------------

@app.get("/api/tasks/{task_id}", response_model=TaskResponse)
async def get_task(task_id: str):
    """Get a single task by ID."""
    async with get_db_ctx() as db:
        cursor = await db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Task not found")

    return TaskResponse(
        id=row["id"],
        prompt=row["prompt"],
        repo=row["repo"],
        branch=row["branch"],
        mode=row["mode"],
        status=row["status"],
        conversation_id=row["conversation_id"],
        sandbox_id=row["sandbox_id"],
        created_at=row["created_at"],
        completed_at=row["completed_at"],
        error_message=row["error_message"],
    )


@app.delete("/api/tasks/{task_id}")
async def delete_task(task_id: str):
    """Delete a queued task (cannot delete running/completed tasks)."""
    async with get_db_ctx() as db:
        cursor = await db.execute("SELECT status FROM tasks WHERE id = ?", (task_id,))
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Task not found")
        if row["status"] not in ("queued", "failed"):
            raise HTTPException(status_code=400, detail="Can only delete queued or failed tasks")

        await db.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
        await db.commit()

    return {"status": "deleted", "task_id": task_id}


@app.post("/api/tasks/{task_id}/retry")
async def retry_task(task_id: str):
    """Retry a failed task — resets status to 'queued' so worker picks it up."""
    async with get_db_ctx() as db:
        cursor = await db.execute("SELECT id, status FROM tasks WHERE id = ?", (task_id,))
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Task not found")
        if row["status"] != "failed":
            raise HTTPException(status_code=400, detail=f"Cannot retry task with status '{row['status']}'")
        await db.execute(
            "UPDATE tasks SET status = 'queued', error_message = NULL, completed_at = NULL WHERE id = ?",
            (task_id,),
        )
        await db.commit()
    return {"status": "queued", "task_id": task_id}


@app.delete("/api/tasks")
async def delete_all_tasks(status: str = "all"):
    """Delete all tasks, optionally filtered by status. Never deletes running/starting tasks."""
    async with get_db_ctx() as db:
        if status == "all":
            await db.execute("DELETE FROM tasks WHERE status NOT IN ('running', 'starting')")
        elif status in ("completed", "failed", "queued"):
            await db.execute("DELETE FROM tasks WHERE status = ?", (status,))
        else:
            raise HTTPException(status_code=400, detail=f"Invalid status filter: {status}")
        await db.commit()
    return {"ok": True, "deleted": status}


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

@app.get("/api/tasks/{task_id}/events", response_model=EventsListResponse)
async def get_events(
    task_id: str,
    since_timestamp: str | None = Query(None, description="ISO timestamp — return only events after this"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
):
    """Get events for a task. Use since_timestamp for incremental polling."""
    async with get_db_ctx() as db:
        # Verify task exists
        cursor = await db.execute("SELECT status FROM tasks WHERE id = ?", (task_id,))
        task = await cursor.fetchone()
        if not task:
            raise HTTPException(status_code=404, detail="Task not found")

        if since_timestamp:
            cursor = await db.execute(
                """SELECT * FROM events
                   WHERE task_id = ? AND timestamp > ?
                   ORDER BY event_index ASC LIMIT ? OFFSET ?""",
                (task_id, since_timestamp, limit, offset),
            )
        else:
            cursor = await db.execute(
                "SELECT * FROM events WHERE task_id = ? ORDER BY event_index ASC LIMIT ? OFFSET ?",
                (task_id, limit, offset),
            )
        rows = await cursor.fetchall()

        # Check if there are more events
        if rows:
            last_index = rows[-1]["event_index"]
            count_cursor = await db.execute(
                "SELECT COUNT(*) as cnt FROM events WHERE task_id = ? AND event_index > ?",
                (task_id, last_index),
            )
            count_row = await count_cursor.fetchone()
            has_more = count_row["cnt"] > 0 if count_row else False
        else:
            has_more = False

    events = [
        EventResponse(
            id=row["id"],
            task_id=row["task_id"],
            event_index=row["event_index"],
            timestamp=row["timestamp"],
            kind=row["kind"],
            source=row["source"],
            tool_name=row["tool_name"],
            action_json=row["action_json"],
            observation_json=row["observation_json"],
            message_json=row["message_json"],
        )
        for row in rows
    ]

    return EventsListResponse(
        events=events,
        has_more=has_more,
        task_status=task["status"],
    )


# ---------------------------------------------------------------------------
# FCM Token
# ---------------------------------------------------------------------------

@app.post("/api/fcm-token")
async def register_fcm_token(req: FCMTokenRequest):
    """Register a device FCM token for push notifications."""
    now = datetime.now(timezone.utc).isoformat()
    async with get_db_ctx() as db:
        await db.execute(
            "INSERT OR REPLACE INTO fcm_tokens (token, created_at) VALUES (?, ?)",
            (req.token, now),
        )
        await db.commit()
    return {"status": "registered"}


# ---------------------------------------------------------------------------
# LLM Configuration
# ---------------------------------------------------------------------------

@app.put("/api/config/llm")
async def update_llm_config(req: LLMConfigRequest):
    """Update the LLM model at runtime.
    
    Only two models are allowed:
      - deepseek/deepseek-v4-flash
      - deepseek/deepseek-v4-pro
    
    The API key is read from the LLM_API_KEY env var (set on the server).
    The next send() call detects the model change and creates a new
    Cloud conversation with the new model (preserving message history).
    """
    allowed = {"deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-pro"}
    if req.model not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"Model '{req.model}' not allowed. Choose from: {', '.join(sorted(allowed))}"
        )
    
    # Read API key from env var (already set on the server, not sent from client)
    api_key = os.environ.get("LLM_API_KEY", "") or os.environ.get("OPENHANDS_CLOUD_API_KEY", "")
    if not api_key:
        raise HTTPException(
            status_code=400,
            detail="LLM_API_KEY not configured on server. Set the LLM_API_KEY or OPENHANDS_CLOUD_API_KEY env var."
        )
    
    logger.info("LLM model update: %s (using server-side API key)", req.model)
    set_llm_config(AgentConfig(
        model=req.model,
        api_key=api_key,
        base_url=None,
    ))
    cfg = get_llm_config()
    return {
        "status": "updated",
        "model": cfg.model,
    }


@app.get("/api/config/llm")
async def get_current_llm_config():
    """Get current LLM configuration (model only — key is never returned)."""
    cfg = get_llm_config()
    return {
        "model": cfg.model,
        "base_url": cfg.base_url,
        "has_api_key": bool(cfg.api_key),
    }


@app.put("/api/config/git")
async def update_git_config(req: GitConfigRequest):
    """Update git name/email for AI agent commits."""
    set_git_config(name=req.name, email=req.email)
    cfg = get_git_config()
    return {"status": "updated", "name": cfg["name"], "email": cfg["email"]}


@app.get("/api/config/git")
async def get_current_git_config():
    """Get current git configuration."""
    cfg = get_git_config()
    return {"name": cfg["name"], "email": cfg["email"]}


# ---------------------------------------------------------------------------
# Clear queue (backend-side cleanup for testing)
# ---------------------------------------------------------------------------

@app.post("/api/chat/clear-queue")
async def chat_clear_queue():
    """Clear ALL chat state: messages, batch queue, conversation.
    
    Use this to fully reset the backend for fresh testing.
    Safe to call anytime — never raises.
    """
    try:
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, lambda: chat_reset())
        logger.warning("chat_clear_queue: FULL RESET executed")
        return {"ok": True, "message": "All chat state cleared. Start fresh."}
    except Exception as e:
        logger.error("chat_clear_queue EXCEPTION: %s", e, exc_info=True)
        return {"ok": False, "error": "Failed to clear queue. Try again."}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8080"))
    uvicorn.run("main:app", host=host, port=port, reload=False)
