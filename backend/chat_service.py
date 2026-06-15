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

# -- Restore state from DB on module load --
def _restore_from_db() -> None:
    global _conversation_id, _conversation_repo, _conversation_mode, _last_event_index, _messages
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
            logger.info("Restored chat session: conv=%s repo=%s mode=%s msgs=%d",
                         _conversation_id, _conversation_repo, _conversation_mode, len(_messages))
    except Exception:
        pass

def _persist_to_db() -> None:
    if _DB is None:
        return
    try:
        data = json.dumps({
            "conversation_id": _conversation_id,
            "repo": _conversation_repo,
            "mode": _conversation_mode,
            "last_event_index": _last_event_index,
            "messages": _messages[-200:],  # keep last 200 messages max
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
        except Exception:
            pass

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
        }


def send(prompt: str, repo: str = "", branch: str = "main", mode: str = "code") -> dict:
    """Send a chat message and wait for the agent response (synchronous).

    Creates a new conversation when repo or mode changes — different context
    needs a different conversation. Same repo+mode reuses conversation (token-efficient).
    """
    global _conversation_id, _conversation_repo, _conversation_mode, _last_event_index

    if not CLOUD_API_KEY:
        return {"error": "OPENHANDS_CLOUD_API_KEY not configured on server"}

    logger.info("Chat send: prompt=%.80s... repo=%s mode=%s", prompt, repo, mode)

    with _lock:
        try:
            # Detect context change — different repo or mode needs new conversation
            ctx_changed = (
                _conversation_id is not None
                and (repo != _conversation_repo or mode != _conversation_mode)
            )
            if ctx_changed:
                logger.info("Context changed: repo %s→%s mode %s→%s — starting new conversation",
                            _conversation_repo, repo, _conversation_mode, mode)
                _conversation_id = None
                _last_event_index = 0
                # Keep old messages in history; they're still visible to user
                # New conversation starts fresh on the Cloud API side

            if _conversation_id is None:
                # -- First message: create a conversation ---
                _conversation_id = _create_conversation(prompt, repo, branch, mode)
                _conversation_repo = repo
                _conversation_mode = mode
                _last_event_index = 0
                logger.info("Created conversation %s (repo=%s mode=%s)",
                            _conversation_id, repo, mode)
            else:
                # -- Subsequent message: send to existing conversation ---
                resp = httpx.post(
                    f"{CLOUD_API_URL}/api/v1/conversation/{_conversation_id}/events/send",
                    headers=_headers(),
                    json={"message": prompt},
                    timeout=30,
                )
                resp.raise_for_status()
                logger.info("Sent to conversation %s", _conversation_id)

            # Save user message
            _messages.append({
                "role": "user",
                "content": prompt,
                "timestamp": int(time.time() * 1000),
            })
            _persist_to_db()

            # Wait for agent response
            response = _wait_for_response()
            if response:
                _messages.append({
                    "role": "assistant",
                    "content": response,
                    "timestamp": int(time.time() * 1000),
                })
                _persist_to_db()

            return {
                "response": response or "(agent produced no text response)",
                "conversation_id": _conversation_id,
            }

        except httpx.HTTPStatusError as e:
            logger.error("HTTP error: %s %s", e.response.status_code, e.response.text[:200])
            if e.response.status_code in (404, 410):
                _conversation_id = None  # conversation dead — start fresh next time
                _last_event_index = 0
                _persist_to_db()
            return {"error": f"Cloud API error: {e.response.status_code}"}
        except Exception as e:
            # Transient failures do NOT kill the conversation
            logger.error("Chat error (keeping conversation): %s", e)
            return {"error": str(e)}


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

        # Collect assistant messages from events we haven't seen yet
        for evt in all_events[_last_event_index:]:
            kind = evt.get("kind", "")
            source = evt.get("source", "")
            if kind == "MessageEvent" and source in ("agent", "assistant"):
                msg = evt.get("message", "")
                if isinstance(msg, str) and msg.strip():
                    all_new_msgs.append(msg.strip())
                elif isinstance(msg, dict) and msg.get("content"):
                    all_new_msgs.append(str(msg["content"]).strip())

        # Advance the seen index
        _last_event_index = len(all_events)

        if status in ("completed", "finished"):
            break
        elif status in ("failed", "error", "stopped"):
            err_detail = items[0].get("error_message", "unknown error")
            logger.warning("Conversation %s: %s", status, err_detail)
            return None

    if not all_new_msgs:
        logger.warning("No assistant messages found after %.0fs", time.time() - start)

    return "\n\n".join(all_new_msgs) if all_new_msgs else None
