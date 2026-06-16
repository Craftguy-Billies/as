"""Chat service — reusable conversation with token-efficient message continuation.

Uses OpenHands Cloud REST API (SAME endpoints as agent_runner.py for consistency):
- First message: POST /api/v1/app-conversations (creates conversation)
- Subsequent:   POST /api/v1/conversation/{id}/events/send (reuses conversation)
- Status poll:  GET  /api/v1/app-conversations?ids={id}
- Events poll:  GET  /api/v1/conversation/{id}/events/search

Thread-safe: _lock serializes access to module-level session state.
State persisted to SQLite — survives server restart.
"""
import httpx
import json
import logging
import os
import threading
import time
from datetime import datetime, timezone

try:
    from database import get_sync_db
    _DB = get_sync_db()
except Exception:
    _DB = None

logger = logging.getLogger(__name__)

CLOUD_API_URL = os.getenv("OPENHANDS_CLOUD_API_URL", "https://app.all-hands.dev")
CLOUD_API_KEY = os.getenv("OPENHANDS_CLOUD_API_KEY", "")

# -- Session state (persisted to DB, survives restart) --
_conversation_id: str | None = None
_conversation_repo: str = ""
_conversation_mode: str = "code"
_last_event_index: int = 0
_messages: list[dict] = []
_lock = threading.Lock()

# Batch queue — server-side, survives client disconnect
_batch_prompts: list[str] = []
_batch_position: int = 0
_batch_total: int = 0
_batch_repo: str = ""
_batch_branch: str = "main"
_batch_mode: str = "code"
_batch_running: bool = False
_batch_cancelled: bool = False

# -- Restore state from DB on module load --
def _restore_from_db() -> None:
    global _conversation_id, _conversation_repo, _conversation_mode, _last_event_index, _messages
    global _batch_prompts, _batch_position, _batch_total, _batch_running
    if _DB is None:
        return
    try:
        row = _DB.execute("SELECT value FROM kv_store WHERE key = 'chat_session'").fetchone()
        if row:
            data = json.loads(row[0])
            _conversation_id = data.get("conversation_id")
            _conversation_repo = data.get("repo", "")
            _conversation_mode = data.get("mode", "code")
            _last_event_index = data.get("last_event_index", 0)
            _messages = data.get("messages", [])
            # Restore batch queue if server restarted mid-batch
            _batch_prompts = data.get("batch_prompts", [])
            _batch_position = data.get("batch_position", 0)
            _batch_total = data.get("batch_total", 0)
            _batch_running = False  # never auto-resume — user must re-trigger
            logger.info("Restored chat session: conv=%s repo=%s mode=%s msgs=%d batch=%d/%d",
                         _conversation_id, _conversation_repo, _conversation_mode, len(_messages),
                         _batch_position, _batch_total)
    except Exception as e:
        logger.warning("Failed to restore chat session from DB: %s", e)

def _persist_to_db() -> None:
    if _DB is None:
        return
    try:
        # Trim in-memory to prevent unbounded growth
        if len(_messages) > 500:
            _messages[:] = _messages[-400:]
        data = json.dumps({
            "conversation_id": _conversation_id,
            "repo": _conversation_repo,
            "mode": _conversation_mode,
            "last_event_index": _last_event_index,
            "messages": _messages[-200:],  # keep last 200 messages max
            # Batch state for survival across restarts
            "batch_prompts": _batch_prompts,
            "batch_position": _batch_position,
            "batch_total": _batch_total,
            "batch_running": _batch_running,
        })
        _DB.execute(
            "INSERT OR REPLACE INTO kv_store (key, value) VALUES ('chat_session', ?)",
            (data,),
        )
        _DB.commit()
    except Exception:
        try:
            _DB.execute(
                "CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)"
            )
            _DB.commit()
        except Exception as e:
            logger.warning("Failed to persist chat session (kv_store missing): %s", e)

_restore_from_db()


def _headers() -> dict:
    return {
        "Authorization": f"Bearer {CLOUD_API_KEY}",
        "Content-Type": "application/json",
    }


def reset() -> None:
    """Clear the current chat session."""
    global _conversation_id, _conversation_repo, _conversation_mode, _last_event_index, _messages
    with _lock:
        _conversation_id = None
        _conversation_repo = ""
        _conversation_mode = "code"
        _last_event_index = 0
        _messages = []
        _persist_to_db()
    logger.info("Chat session reset")


def get_state() -> dict:
    """Return current chat state for API consumers."""
    with _lock:
        return {
            "messages": list(_messages),
            "conversation_id": _conversation_id,
            "repo": _conversation_repo,
            "mode": _conversation_mode,
            "batch": {
                "running": _batch_running,
                "position": _batch_position + (1 if _batch_running else 0),
                "total": _batch_total,
                "prompts": list(_batch_prompts),
            },
        }


def send(prompt: str, repo: str = "", branch: str = "main", mode: str = "code") -> dict:
    """Send a chat message and wait for the agent response (synchronous).

    Creates a new conversation when repo or mode changes.
    HTTP calls (create/send) happen OUTSIDE _lock so get_state() polling is never blocked.
    """
    global _conversation_id, _conversation_repo, _conversation_mode, _last_event_index

    if not CLOUD_API_KEY:
        return {"error": "OPENHANDS_CLOUD_API_KEY not configured on server"}

    logger.info("Chat send: prompt=%.80s... repo=%s mode=%s", prompt, repo, mode)

    # Phase 1a: Quick check under lock — do we need a new conversation?
    with _lock:
        ctx_changed = (
            _conversation_id is not None
            and (repo != _conversation_repo or mode != _conversation_mode)
        )
        if ctx_changed:
            logger.info("Context changed: repo %s→%s mode %s→%s — starting new conversation",
                        _conversation_repo, repo, _conversation_mode, mode)
            _conversation_id = None
            _last_event_index = 0
        need_new_conv = _conversation_id is None
        if not need_new_conv:
            current_conv_id = _conversation_id  # snapshot to use outside lock

    # Phase 1b: HTTP calls OUTSIDE lock (create may poll start-tasks for up to 150s)
    try:
        if need_new_conv:
            new_conv_id = _create_conversation(prompt, repo, branch, mode)
            logger.info("Created conversation %s (repo=%s mode=%s)",
                        new_conv_id, repo, mode)
        else:
            resp = httpx.post(
                f"{CLOUD_API_URL}/api/v1/conversation/{current_conv_id}/events/send",
                headers=_headers(),
                json={"message": prompt},
                timeout=30,
            )
            resp.raise_for_status()
            logger.info("Sent to conversation %s", current_conv_id)
    except httpx.HTTPStatusError as e:
        logger.error("HTTP error: %s %s", e.response.status_code, e.response.text[:200])
        if e.response.status_code in (404, 410):
            with _lock:
                _conversation_id = None
                _last_event_index = 0
                _persist_to_db()
        return {"error": f"Cloud API error: {e.response.status_code}"}
    except Exception as e:
        logger.error("Chat error (keeping conversation): %s", e, exc_info=True)
        return {"error": str(e)}

    # Phase 1c: Update state + save user message under lock
    with _lock:
        if need_new_conv:
            _conversation_id = new_conv_id
            _conversation_repo = repo
            _conversation_mode = mode
            _last_event_index = 0
        _messages.append({
            "role": "user",
            "content": prompt,
            "timestamp": int(time.time() * 1000),
        })
        _persist_to_db()

    # Phase 2: Long wait — NO LOCK, get_state() can read events live
    try:
        response = _wait_for_response()
    except Exception as e:
        logger.error("Wait for response crashed: %s", e, exc_info=True)
        response = None

    # Phase 3: Save result under lock
    with _lock:
        if response:
            _messages.append({
                "role": "assistant",
                "content": response,
                "timestamp": int(time.time() * 1000),
            })
            _persist_to_db()
            return {
                "response": response,
                "conversation_id": _conversation_id,
            }
        else:
            return {
                "error": "Agent did not produce a response (timeout or conversation error)",
                "conversation_id": _conversation_id,
            }


# ---------------------------------------------------------------------------
# Batch queue — server-side, survives client disconnect
# ---------------------------------------------------------------------------


def enqueue_batch(prompts: list[str], repo: str = "", branch: str = "main", mode: str = "code") -> dict:
    """Queue multiple prompts for sequential processing in the same conversation.

    Returns immediately. Processing happens in a background thread.
    Call get_state() to track progress.
    If a batch is already running, appends to it.
    """
    global _batch_prompts, _batch_position, _batch_total, _batch_repo, _batch_branch, _batch_mode, _batch_running

    cleaned = [p.strip() for p in prompts if p.strip()]
    if not cleaned:
        return {"error": "No valid prompts"}

    with _lock:
        if _batch_running:
            # Append to running batch
            _batch_prompts.extend(cleaned)
            _batch_total = len(_batch_prompts)
            logger.info("Batch appended: +%d prompts (now %d total)", len(cleaned), _batch_total)
            return {"status": "appended", "added": len(cleaned), "total": _batch_total}

        _batch_prompts = cleaned
        _batch_position = 0
        _batch_total = len(cleaned)
        _batch_repo = repo
        _batch_branch = branch
        _batch_mode = mode
        _batch_running = True

    logger.info("Batch enqueued: %d prompts, repo=%s mode=%s", _batch_total, repo, mode)

    # Start background processing
    t = threading.Thread(target=_process_batch_worker, daemon=True)
    t.start()

    return {"status": "queued", "total": _batch_total}


def _process_batch_worker() -> None:
    """Process batch prompts one by one in a background thread.
    
    CRITICAL: Wrap in BaseException handler so a crash NEVER leaves
    _batch_running=True (which would freeze the client forever).
    Also enforce a 30-minute global timeout per batch.
    """
    global _batch_position, _batch_running
    _batch_started_at = time.time()

    try:
        while True:
            with _lock:
                if _batch_cancelled or not _batch_running or _batch_position >= _batch_total:
                    _batch_running = False
                    _batch_prompts = []
                    _batch_position = 0
                    _batch_total = 0
                    _persist_to_db()
                    logger.info("Batch complete")
                    return
                # 30-minute global batch timeout
                if time.time() - _batch_started_at > 1800:
                    _messages.append({
                        "role": "error",
                        "content": "Batch timed out after 30 minutes. Remaining prompts skipped.",
                        "timestamp": int(time.time() * 1000),
                    })
                    _batch_running = False
                    _batch_prompts = []
                    _batch_position = 0
                    _batch_total = 0
                    _persist_to_db()
                    logger.warning("Batch timed out")
                    return
                prompt = _batch_prompts[_batch_position]
                pos = _batch_position + 1
                total = _batch_total
                repo = _batch_repo
                branch = _batch_branch
                mode = _batch_mode

            # Send the prompt (this blocks — uses the same send() function)
            logger.info("Batch [%d/%d]: %.80s...", pos, total, prompt)
            try:
                result = send(prompt, repo=repo, branch=branch, mode=mode)
            except Exception as e:
                logger.error("Batch send crashed [%d/%d]: %s", pos, total, e)
                result = {"error": str(e)}

            if result and "error" in result:
                with _lock:
                    _messages.append({
                        "role": "assistant",
                        "content": f"❌ [{pos}/{total}] Failed: {result['error']}",
                        "timestamp": int(time.time() * 1000),
                    })

            with _lock:
                _batch_position += 1
                _persist_to_db()

            time.sleep(1)  # brief pause between prompts
    except BaseException as e:
        logger.error("Batch worker FATAL crash: %s", e, exc_info=True)
        with _lock:
            _messages.append({
                "role": "event",
                "content": f"❌ Worker crashed\nType: {type(e).__name__}\nMessage: {e}",
                "kind": "ErrorEvent",
                "timestamp": int(time.time() * 1000),
            })
    finally:
        with _lock:
            _batch_running = False
            _batch_position = 0
            _batch_total = 0
        _persist_to_db()


def cancel_batch() -> dict:
    """Cancel the running batch queue. Non-blocking — sets flag for worker."""
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_position, _batch_total
    _batch_cancelled = True  # non-blocking flag, worker checks each iteration
    with _lock:
        was_running = _batch_running
        _batch_running = False
        remaining = _batch_total - _batch_position
        _batch_prompts = []
        _batch_position = 0
        _batch_total = 0
    if was_running:
        logger.info("Batch cancelled (%d prompts remaining)", remaining)
    return {"status": "cancelled", "remaining": remaining}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _create_conversation(prompt: str, repo: str, branch: str, mode: str) -> str:
    """Create a conversation via POST /api/v1/app-conversations (SAME as agent_runner).

    Returns the conversation_id. Raises on failure.
    """
    # Mode-specific prompt prefix
    if mode == "plan":
        if repo:
            full_prompt = (
                f"Plan mode for {repo} on branch {branch}. "
                f"First, explore the codebase, analyze the situation, "
                f"and create a detailed plan. Do NOT implement yet. "
                f"After the plan is complete, ask me whether to proceed.\n\n"
                f"{prompt}"
            )
        else:
            full_prompt = (
                "PLAN MODE: First, analyze this request and create a detailed plan. "
                "Do NOT implement yet. After the plan is complete, ask me whether to proceed.\n\n"
                f"{prompt}"
            )
    elif repo:
        full_prompt = (
            f"Repository: {repo} (branch: {branch}). {prompt}"
        )
    else:
        full_prompt = prompt

    body: dict = {
        "initial_message": {
            "content": [{"type": "text", "text": full_prompt}],
        },
        "title": prompt[:80],
    }
    # Include repo if provided (general chat omits it)
    if repo:
        body["selected_repository"] = repo
        body["selected_branch"] = branch

    # Apply custom LLM config if set (same as agent_runner)
    try:
        from agent_runner import get_llm_config
        cfg = get_llm_config()
        if cfg.api_key:
            body["llm_config"] = {
                "model": cfg.model,
                "api_key": cfg.api_key,
            }
            if cfg.base_url:
                body["llm_config"]["base_url"] = cfg.base_url
    except Exception:
        pass

    # Add MCP servers (Tavily web search etc.)
    try:
        from agent_runner import _build_default_mcp_config
        mcp = _build_default_mcp_config()
        if mcp:
            body["mcp_servers"] = mcp
    except Exception:
        pass

    # Add git config if set
    try:
        from agent_runner import get_git_config
        git = get_git_config()
        if git["name"] and git["email"]:
            body["git_config"] = {"name": git["name"], "email": git["email"]}
    except Exception as e:
        logger.warning("Failed to load git config: %s", e)

    resp = httpx.post(
        f"{CLOUD_API_URL}/api/v1/app-conversations",
        headers=_headers(),
        json=body,
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()

    conversation_id = data.get("app_conversation_id")
    start_task_id = data.get("id")

    # If async, poll start-tasks for the conversation_id
    if not conversation_id and start_task_id:
        for _ in range(30):  # up to 150 seconds
            time.sleep(5)
            r = httpx.get(
                f"{CLOUD_API_URL}/api/v1/app-conversations/start-tasks",
                headers=_headers(),
                params={"ids": start_task_id},
                timeout=15,
            )
            r.raise_for_status()
            d = r.json()
            items = d if isinstance(d, list) else d.get("items", [])
            if items and items[0].get("app_conversation_id"):
                return items[0]["app_conversation_id"]

    if not conversation_id:
        raise RuntimeError(f"Could not get conversation_id (start_task={start_task_id})")

    return conversation_id


def _wait_for_response(timeout: int = 300) -> str | None:
    """Poll conversation status + events until the agent finishes (SAME logic as agent_runner).
    
    Timeout: 300s (5 min). Complex tasks may need this — the agent may be thinking/typing.
    
    Also appends live events (tool calls, observations) to _messages so the client
    can see what the agent is doing via polling get_state().
    """
    global _last_event_index

    start = time.time()
    all_new_msgs: list[str] = []

    while time.time() - start < timeout:
        time.sleep(3)

        # -- Check conversation status (SAME endpoint as agent_runner) --
        try:
            r = httpx.get(
                f"{CLOUD_API_URL}/api/v1/app-conversations",
                headers=_headers(),
                params={"ids": _conversation_id},
                timeout=10,
            )
            r.raise_for_status()
            data = r.json()
        except Exception as e:
            logger.warning("Status poll error: %s", e)
            continue

        items = data if isinstance(data, list) else data.get("items", [])
        if not items:
            continue

        status = items[0].get("execution_status", "")

        # -- Get events (SAME endpoint as agent_runner) --
        try:
            r2 = httpx.get(
                f"{CLOUD_API_URL}/api/v1/conversation/{_conversation_id}/events/search",
                headers=_headers(),
                params={"limit": 500},
                timeout=10,
            )
            r2.raise_for_status()
            events_data = r2.json()
        except Exception as e:
            logger.warning("Events poll error: %s", e)
            continue

        all_events = events_data if isinstance(events_data, list) else events_data.get("items", [])

        # Stream EVERYTHING the agent does as live events (text, tools, observations)
        for evt in all_events[_last_event_index:]:
            kind = evt.get("kind", "")
            source = evt.get("source", "")
            tool = evt.get("tool_name", "")

            if kind == "MessageEvent" and source in ("agent", "assistant"):
                msg = evt.get("message", "")
                text = ""
                if isinstance(msg, str) and msg.strip():
                    text = msg.strip()
                elif isinstance(msg, dict) and msg.get("content"):
                    text = str(msg["content"]).strip()
                if text:
                    all_new_msgs.append(text)
                    # Stream agent text as live event so Flutter sees it in real-time
                    with _lock:
                        _messages.append({
                            "role": "event",
                            "content": f"💬 {text}",
                            "kind": kind,
                            "timestamp": int(time.time() * 1000),
                        })

            # Stream tool calls, observations, errors as live events
            event_preview = _format_event_preview(evt)
            if event_preview:
                with _lock:
                    _messages.append({
                        "role": "event",
                        "content": event_preview,
                        "kind": kind,
                        "tool_name": tool,
                        "timestamp": int(time.time() * 1000),
                    })

        # Advance the seen index
        _last_event_index = len(all_events)

        if status in ("completed", "finished"):
            break
        elif status in ("failed", "error", "stopped"):
            err_detail = items[0].get("error_message", "unknown error")
            err_type = items[0].get("error_type", "")
            logger.warning("Conversation %s: type=%s detail=%s", status, err_type, err_detail)
            # Stream the failure as a visible event
            parts = [f"❌ Conversation {status}"]
            if err_type:
                parts.append(f"Type: {err_type}")
            parts.append(f"Message: {err_detail}")
            with _lock:
                _messages.append({
                    "role": "event",
                    "content": "\n".join(parts),
                    "kind": "ErrorEvent",
                    "timestamp": int(time.time() * 1000),
                })
            return None

    if not all_new_msgs:
        logger.warning("No assistant messages found after %.0fs", time.time() - start)
        with _lock:
            _messages.append({
                "role": "event",
                "content": "⚠️ No response from agent (timeout or empty result)",
                "kind": "SystemEvent",
                "timestamp": int(time.time() * 1000),
            })

    return "\n\n".join(all_new_msgs) if all_new_msgs else None


def _format_event_preview(evt: dict) -> str | None:
    """Format a Cloud API event for chat display — NO TRUNCATION, pass raw details."""
    kind = evt.get("kind", "")
    tool = evt.get("tool_name", "")
    source = evt.get("source", "")

    # Skip user messages and agent text messages (handled separately in _wait_for_response)
    if kind == "MessageEvent":
        return None

    if kind == "ActionEvent":
        action = evt.get("action") or {}
        if isinstance(action, str):
            try:
                action = json.loads(action)
            except Exception:
                action = {}

        if tool in ("bash", "terminal", "execute_bash_command"):
            cmd = action.get("command", "") or action.get("content", "")
            if cmd:
                return f"💻 $ {cmd}"
        elif tool in ("file_editor", "str_replace_editor"):
            path = action.get("path", "") or action.get("file", "")
            if path:
                return f"📝 Editing: {path}"
        elif tool in ("tavily_search", "tavily_tavily_search"):
            q = action.get("query", "") or action.get("content", "")
            if q:
                return f"🔍 Searching: {q}"
        elif tool == "browser_navigate":
            url = action.get("url", "")
            if url:
                return f"🌐 Navigate: {url}"
        else:
            # Unknown tool — show tool name + first action key for visibility
            return f"🔧 {tool}: {str(action)[:120]}"

    elif kind == "ObservationEvent":
        obs = evt.get("observation") or {}
        if isinstance(obs, str):
            try:
                obs = json.loads(obs)
            except Exception:
                obs = {"output": str(obs)}

        if tool in ("bash", "terminal", "execute_bash_command"):
            stdout = obs.get("stdout", "") or obs.get("output", "") or obs.get("content", "")
            stderr = obs.get("stderr", "")
            exit_code = obs.get("exit_code")
            parts = []
            if stdout:
                parts.append(f"📤 stdout:\n{stdout}")
            if stderr:
                parts.append(f"📤 stderr:\n{stderr}")
            if exit_code is not None and exit_code != 0:
                parts.append(f"📤 exit_code={exit_code}")
            if parts:
                return "\n".join(parts)
        elif tool in ("file_editor", "str_replace_editor"):
            diff = obs.get("diff", "")
            if diff:
                return f"📄 Diff:\n{diff}"
            content = obs.get("content", "")
            if content:
                return f"📄 {content}"
            path = obs.get("path", "")
            if path:
                return f"📄 Saved: {path}"
        elif tool in ("tavily_search", "tavily_tavily_search"):
            results = obs.get("results", [])
            if isinstance(results, list) and results:
                lines = [f"📊 {len(results)} search results:"]
                for r in results[:5]:
                    title = r.get("title", "")
                    url = r.get("url", "")
                    if title:
                        lines.append(f"  • {title}")
                    if url:
                        lines.append(f"    {url}")
                return "\n".join(lines)
        elif tool == "browser_get_content":
            text = obs.get("text", "") or obs.get("content", "")
            if text:
                return f"🌐 Page content ({len(str(text))} chars)"
        else:
            # Unknown observation — dump raw keys
            return f"→ {tool}: {str(obs)}"

    elif kind == "ErrorEvent":
        msg = evt.get("message", "")
        obs = evt.get("observation", "")
        error_type = evt.get("error_type", "") or evt.get("type", "")
        parts = [f"❌ ERROR"]
        if error_type:
            parts.append(f"Type: {error_type}")
        if msg:
            parts.append(f"Message: {msg}")
        if obs:
            obs_str = str(obs)
            if obs_str.strip():
                parts.append(f"Details: {obs_str}")
        # Also dump any other useful fields
        for key in ("traceback", "stack_trace", "cause"):
            val = evt.get(key, "")
            if val:
                parts.append(f"{key}: {val}")
        return "\n".join(parts)

    # Catch-all: dump raw event (with emoji prefix for visibility)
    return f"📋 [{kind}] {json.dumps(evt, default=str)}"
