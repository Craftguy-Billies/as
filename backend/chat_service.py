"""Chat service — reusable conversation with token-efficient message continuation.

Uses OpenHands Cloud REST API (verified against OpenAPI spec):
- First message: POST /api/v1/app-conversations (creates conversation)
- Subsequent:   POST /api/v1/app-conversations/{id}/send-message (reuses conversation)
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

from database import get_sync_db

logger = logging.getLogger(__name__)

CLOUD_API_URL = os.getenv("OPENHANDS_CLOUD_API_URL", "https://app.all-hands.dev")
CLOUD_API_KEY = os.getenv("OPENHANDS_CLOUD_API_KEY", "")

# -- Session state (persisted to DB, survives restart) --
_conversation_id: str | None = None
_conversation_repo: str = ""
_conversation_branch: str = "main"
_conversation_mode: str = "code"
_last_event_index: int = 0
_sandbox_id: str | None = None
_event_kinds: set[str] = set()  # diagnostic: all event kinds seen in current conversation
_seen_event_ids: set[str] = set()  # ID-based event dedup (immune to API limit=N truncation)
_agent_server_url: str | None = None  # direct agent server URL (session-key auth)
_session_api_key: str | None = None   # session key for agent server
_current_repo_key: str = ""  # current repo — determines which chat history to show
_messages_by_repo: dict[str, list[dict]] = {}  # per-repo chat history
_lock = threading.Lock()

def _msgs() -> list[dict]:
    """Get or create the message list for the current repo/mode."""
    if _current_repo_key not in _messages_by_repo:
        _messages_by_repo[_current_repo_key] = []
    return _messages_by_repo[_current_repo_key]

def _repo_key(repo: str) -> str:
    """Build a stable key for a repo (plan and code share the same chat)."""
    return repo or '(none)'

def _migrate_keys(msgs_by_repo: dict) -> dict:
    """Migrate old 'repo|mode' keys to flat 'repo' keys, merging messages."""
    migrated: dict[str, list[dict]] = {}
    for key, msgs in msgs_by_repo.items():
        if '|' in key:
            repo, _, _mode = key.rpartition('|')
            base = repo or '(none)'
        else:
            base = key
        if base not in migrated:
            migrated[base] = list(msgs)
        else:
            # Merge: dedup by (role, content, timestamp)
            existing = {(m.get('role', ''), m.get('content', ''), m.get('timestamp', 0)) for m in migrated[base]}
            for m in msgs:
                if (m.get('role', ''), m.get('content', ''), m.get('timestamp', 0)) not in existing:
                    migrated[base].append(m)
            migrated[base].sort(key=lambda m: m.get('timestamp', 0))
    return migrated

# Batch queue — server-side, survives client disconnect
_batch_prompts: list[str] = []
_batch_prompt_modes: list[str] = []  # per-prompt mode (plan/code)
_batch_prompt_branches: list[str] = []  # per-prompt branch (for cross-branch appends)
_batch_position: int = 0
_batch_total: int = 0
_batch_repo: str = ""
_batch_branch: str = "main"
_batch_mode: str = "code"
_batch_running: bool = False
_batch_cancelled: bool = False
_batch_skip_prompt: bool = False  # set by per-prompt cancel, tells worker to skip current

# Current conversation status (for UI visibility)
_conversation_status: str = "idle"
_CHAT_TIMEOUT = int(os.getenv("VIBECODE_CHAT_TIMEOUT", "600"))  # 10 min default

# -- Restore state from DB on module load --
def _restore_from_db() -> None:
    global _conversation_id, _conversation_repo, _conversation_branch, _conversation_mode, _last_event_index, _messages_by_repo, _current_repo_key
    global _batch_prompts, _batch_prompt_modes, _batch_prompt_branches, _batch_position, _batch_total, _batch_running
    try:
        db = get_sync_db()
    except Exception:
        return
    try:
        row = db.execute("SELECT value FROM kv_store WHERE key = 'chat_session'").fetchone()
        if row:
            data = json.loads(row[0])
            _conversation_id = data.get("conversation_id")
            _conversation_repo = data.get("repo", "")
            _conversation_branch = data.get("branch", "main")
            _conversation_mode = data.get("mode", "code")
            _last_event_index = data.get("last_event_index", 0)
            _messages_by_repo = data.get("messages_by_repo", {})
            # Migrate old "repo|mode" keys to flat "repo" keys
            _messages_by_repo = _migrate_keys(_messages_by_repo)
            _current_repo_key = data.get("current_repo_key", _repo_key(_conversation_repo))
            # Restore batch queue if server restarted mid-batch
            _batch_prompts = data.get("batch_prompts", [])
            _batch_prompt_modes = data.get("batch_prompt_modes", [])
            _batch_prompt_branches = data.get("batch_prompt_branches", [])
            _batch_position = data.get("batch_position", 0)
            _batch_total = data.get("batch_total", 0)
            # Auto-resume if server restarted mid-batch (remaining prompts in queue)
            _batch_running = _batch_position < _batch_total and len(_batch_prompts) > _batch_position
            if _batch_running:
                threading.Thread(target=_process_batch_worker, daemon=True).start()
                logger.info("Auto-resuming batch: %d/%d remaining", _batch_total - _batch_position, _batch_total)
    except Exception as e:
        logger.warning("Failed to restore chat session from DB: %s", e)

def _persist_to_db() -> None:
    try:
        db = get_sync_db()
    except Exception:
        return
    try:
        # Trim each repo's messages to prevent unbounded growth
        for key in list(_messages_by_repo.keys()):
            if len(_messages_by_repo[key]) > 500:
                _messages_by_repo[key] = _messages_by_repo[key][-400:]
        data = json.dumps({
            "conversation_id": _conversation_id,
            "repo": _conversation_repo,
            "branch": _conversation_branch,
            "mode": _conversation_mode,
            "last_event_index": _last_event_index,
            "messages_by_repo": _messages_by_repo,
            "current_repo_key": _current_repo_key,
            # Batch state for survival across restarts
            "batch_prompts": _batch_prompts,
            "batch_prompt_modes": _batch_prompt_modes,
            "batch_prompt_branches": _batch_prompt_branches,
            "batch_position": _batch_position,
            "batch_total": _batch_total,
            "batch_running": _batch_running,
        })
        db.execute(
            "INSERT OR REPLACE INTO kv_store (key, value) VALUES ('chat_session', ?)",
            (data,),
        )
        db.commit()
    except Exception:
        try:
            db.execute(
                "CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)"
            )
            db.commit()
        except Exception as e:
            logger.warning("Failed to persist chat session (kv_store missing): %s", e)

_restore_from_db()


def _headers() -> dict:
    return {
        "Authorization": f"Bearer {CLOUD_API_KEY}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


def reset() -> None:
    """Clear the current chat session AND cancel any running batch."""
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_prompt_branches, _batch_position, _batch_total, _batch_skip_prompt
    global _conversation_id, _conversation_repo, _conversation_branch, _conversation_mode, _last_event_index, _messages_by_repo, _event_kinds, _conversation_status, _sandbox_id, _current_repo_key, _seen_event_ids
    with _lock:
        # Cancel running batch
        if _batch_running:
            _batch_cancelled = True
            _batch_skip_prompt = False
            _batch_running = False
            _batch_prompts = []
            _batch_prompt_modes = []
            _batch_prompt_branches = []
            _batch_position = 0
            _batch_total = 0
            logger.info("Batch cancelled by chat reset")
        # Reset conversation
        _conversation_id = None
        _conversation_repo = ""
        _conversation_branch = "main"
        _conversation_mode = "code"
        _last_event_index = 0
        _seen_event_ids.clear()
        _event_kinds.clear()
        _sandbox_id = None
        _messages_by_repo.pop(_current_repo_key, None)  # clear current repo's history
        _conversation_status = "idle"
        _persist_to_db()
    logger.info("Chat session reset")


def get_state(repo: str = "", mode: str = "") -> dict:
    """Return current chat state for API consumers.
    
    If repo/mode are provided, switch the active repo key first.
    This lets the Flutter client request messages for a specific repo.
    """
    global _current_repo_key
    with _lock:
        if repo or mode:
            _current_repo_key = _repo_key(repo)
        return {
            "messages": list(_msgs()),
            "conversation_id": _conversation_id,
            "sandbox_id": _sandbox_id,
            "repo": _conversation_repo,
            "branch": _conversation_branch,
            "mode": _conversation_mode,
            "current_repo_key": _current_repo_key,
            "conversation_status": _conversation_status,
            "batch": {
                "running": _batch_running,
                "cancelled": _batch_cancelled,
                "position": _batch_position + (1 if _batch_running else 0),
                "total": _batch_total,
                "prompts": list(_batch_prompts),
                "modes": list(_batch_prompt_modes),
                "branches": list(_batch_prompt_branches),
            },
        }


def get_repos() -> list[dict]:
    """Return list of all saved repo keys with message counts."""
    result = []
    for key, msgs in _messages_by_repo.items():
        if not msgs:
            continue
        # Normalize: strip old mode suffix if present
        repo = key.rpartition("|")[0] if "|" in key else key
        if not repo:
            repo = "(none)"
        # Determine mode: check messages for mode hints, default to code
        mode = "code"
        result.append({
            "key": repo,
            "repo": repo,
            "mode": mode,
            "message_count": len(msgs),
            "last_timestamp": msgs[-1].get("timestamp", 0) if msgs else 0,
        })
    result.sort(key=lambda r: r["last_timestamp"], reverse=True)
    return result


def send(prompt: str, repo: str = "", branch: str = "main", mode: str = "code") -> dict:
    """Send a chat message and wait for the agent response (synchronous).

    Creates a new conversation when repo or mode changes.
    HTTP calls (create/send) happen OUTSIDE _lock so get_state() polling is never blocked.
    """

    if not CLOUD_API_KEY:
        return {"error": "OPENHANDS_CLOUD_API_KEY not configured on server"}

    global _conversation_id, _conversation_repo, _conversation_branch, _conversation_mode, _last_event_index, _sandbox_id, _seen_event_ids

    logger.info("Chat send: prompt=%.80s... repo=%s branch=%s mode=%s", prompt, repo, branch, mode)

    # Phase 1a: Quick check under lock — do we need a new conversation?
    with _lock:
        ctx_changed = (
            _conversation_id is not None
            and (repo != _conversation_repo or branch != _conversation_branch or mode != _conversation_mode)
        )
        if ctx_changed:
            logger.info("Context changed: repo %s→%s branch %s→%s mode %s→%s — starting new conversation",
                        _conversation_repo, repo, _conversation_branch, branch, _conversation_mode, mode)
            _conversation_id = None
            _last_event_index = 0
            _seen_event_ids.clear()
            _sandbox_id = None
            _event_kinds.clear()
            _conversation_repo = repo
            _conversation_branch = branch
            _conversation_mode = mode
            _persist_to_db()
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
            logger.info("Reusing conversation %s (repo=%s branch=%s mode=%s)",
                        current_conv_id, repo, branch, mode)
            success, send_err = _send_message(current_conv_id, prompt)
            if not success:
                # If sandbox is paused/gone, auto-recover: reset + create new
                # conversation with same prompt. The caller never sees a 409.
                if send_err and "409" in str(send_err):
                    logger.warning("Sandbox paused/gone for conversation %s — recovering", current_conv_id)
                    recent_msgs: list = []
                    with _lock:
                        # Capture recent context before resetting so the new
                        # conversation knows what was discussed (not just UI history).
                        for m in _msgs()[-6:]:
                            role = m.get("role", "")
                            if role in ("user", "assistant") and m.get("content"):
                                recent_msgs.append(m)
                        _conversation_id = None
                        _last_event_index = 0
                        _seen_event_ids.clear()
                        _sandbox_id = None
                        _persist_to_db()
                    if recent_msgs:
                        context = "\n".join(
                            f"{m['role'].capitalize()}: {m['content']}" for m in recent_msgs
                        )
                        enhanced = (
                            f"[RECOVERY CONTEXT — sandbox restarted, conversation recreated]\n"
                            f"Below is a summary of recent messages from BEFORE the restart.\n"
                            f"IMPORTANT: These exchanges already happened. Do NOT repeat actions\n"
                            f"that were already completed (e.g., creating files, git operations).\n"
                            f"Continue naturally from where the conversation left off.\n\n"
                            f"{context}\n"
                            f"---\n"
                            f"Current task: {prompt}"
                        )
                    else:
                        enhanced = prompt
                    new_conv_id = _create_conversation(enhanced, repo, branch, mode)
                    logger.info("Recovered: created new conversation %s (%d context msgs)",
                                new_conv_id, len(recent_msgs))
                    need_new_conv = True  # Phase 1c will store it
                else:
                    with _lock:
                        _conversation_id = None
                        _last_event_index = 0
                        _seen_event_ids.clear()
                        _sandbox_id = None
                        _persist_to_db()
                    return {"error": send_err or "Failed to send message to conversation"}
            logger.info("Sent to conversation %s", current_conv_id)
    except httpx.HTTPStatusError as e:
        logger.error("HTTP error: %s %s", e.response.status_code, e.response.text[:200])
        if e.response.status_code in (404, 409, 410):
            with _lock:
                _conversation_id = None
                _last_event_index = 0
                _seen_event_ids.clear()
                _sandbox_id = None
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
            _conversation_branch = branch
            _conversation_mode = mode
            _current_repo_key = _repo_key(repo)
            _last_event_index = 0
            _seen_event_ids.clear()
        _msgs().append({
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

    # Phase 3: Save result under lock — replace live [MSG] event placeholders
    # with a single clean assistant message (avoids duplicated/concatenated display).
    with _lock:
        if response:
            msgs = _msgs()
            msgs[:] = [
                m for m in msgs
                if not (
                    m.get("role") == "event"
                    and isinstance(m.get("content"), str)
                    and m["content"].startswith("[MSG] ")
                )
            ]
            _msgs().append({
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
    global _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _batch_repo, _batch_branch, _batch_mode, _batch_prompt_branches, _batch_running, _batch_cancelled, _batch_skip_prompt

    cleaned = [p.strip() for p in prompts if p.strip()]
    if not cleaned:
        return {"error": "No valid prompts"}

    with _lock:
        if _batch_running:
            # Reject append if repo changed — prevents cross-repo contamination
            if repo != _batch_repo:
                return {
                    "error": (
                        f"Batch already running with repo={_batch_repo or '(none)'}. "
                        "Wait for it to finish or tap 'New conversation' to start fresh."
                    )
                }
            # Append to running batch (cross-mode allowed: plan+code share same chat)
            _batch_prompts.extend(cleaned)
            _batch_prompt_modes.extend([mode] * len(cleaned))
            _batch_prompt_branches.extend([branch] * len(cleaned))
            _batch_total = len(_batch_prompts)
            _batch_mode = mode  # update default mode
            logger.info("Batch appended: +%d prompts (now %d total, mode=%s)", len(cleaned), _batch_total, mode)
            return {"status": "appended", "added": len(cleaned), "total": _batch_total}

        _batch_cancelled = False  # reset from any previous cancellation
        _batch_skip_prompt = False
        _batch_prompts = cleaned
        _batch_prompt_modes = [mode] * len(cleaned)
        _batch_prompt_branches = [branch] * len(cleaned)
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
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_prompt_branches, _batch_position, _batch_total, _batch_repo, _batch_branch, _batch_mode, _batch_skip_prompt
    _batch_started_at = time.time()

    try:
        while True:
            with _lock:
                # Per-prompt cancel: skip current, move to next
                try:
                    skip_prompt = _batch_skip_prompt
                except (NameError, UnboundLocalError):
                    skip_prompt = False
                if skip_prompt:
                    _batch_skip_prompt = False
                    _batch_cancelled = False
                    # Current prompt was removed from queue; next prompt is at same position
                    if _batch_position >= _batch_total:
                        _batch_running = False
                        _batch_prompts = []
                        _batch_prompt_modes = []
                        _batch_prompt_branches = []
                        _batch_position = 0
                        _batch_total = 0
                        _persist_to_db()
                        logger.info("Batch complete (last prompt skipped)")
                        return
                    _persist_to_db()
                    continue

                if _batch_cancelled or not _batch_running or _batch_position >= _batch_total:
                    _batch_running = False
                    _batch_prompts = []
                    _batch_prompt_modes = []
                    _batch_prompt_branches = []
                    _batch_position = 0
                    _batch_total = 0
                    _persist_to_db()
                    logger.info("Batch complete")
                    return
                # 30-minute global batch timeout
                if time.time() - _batch_started_at > 1800:
                    _msgs().append({
                        "role": "error",
                        "content": "Batch timed out after 30 minutes. Remaining prompts skipped.",
                        "timestamp": int(time.time() * 1000),
                    })
                    _batch_running = False
                    _batch_prompts = []
                    _batch_prompt_modes = []
                    _batch_prompt_branches = []
                    _batch_position = 0
                    _batch_total = 0
                    _persist_to_db()
                    logger.warning("Batch timed out")
                    return
                prompt = _batch_prompts[_batch_position]
                pos = _batch_position + 1
                total = _batch_total
                repo = _batch_repo
                branch = _batch_prompt_branches[_batch_position] if _batch_position < len(_batch_prompt_branches) else _batch_branch
                mode = _batch_prompt_modes[_batch_position] if _batch_position < len(_batch_prompt_modes) else _batch_mode

            # Send the prompt (this blocks — uses the same send() function)
            logger.info("Batch [%d/%d]: %.80s...", pos, total, prompt)
            try:
                result = send(prompt, repo=repo, branch=branch, mode=mode)
                logger.info("Batch [%d/%d]: send() returned status=%s has_error=%s msgs=%d",
                            pos, total,
                            result.get("status") if result else "None",
                            bool(result and "error" in result),
                            len(_msgs()))
            except Exception as e:
                logger.error("Batch send crashed [%d/%d]: %s", pos, total, e)
                result = {"error": str(e)}

            if result and "error" in result:
                # Don't show error for deliberately cancelled prompts
                try:
                    skip = _batch_skip_prompt
                except (NameError, UnboundLocalError):
                    skip = False
                if not skip:
                    with _lock:
                        _msgs().append({
                            "role": "assistant",
                            "content": f"[ERROR] [{pos}/{total}] Failed: {result['error']}",
                            "timestamp": int(time.time() * 1000),
                        })

            with _lock:
                try:
                    skip = _batch_skip_prompt
                except (NameError, UnboundLocalError):
                    skip = False
                if not skip:
                    _batch_position += 1
                _persist_to_db()

            time.sleep(1)  # brief pause between prompts
    except BaseException as e:
        logger.error("Batch worker FATAL crash: %s", e, exc_info=True)
        with _lock:
            _msgs().append({
                "role": "event",
                "content": f"[ERROR] Worker crashed\nType: {type(e).__name__}\nMessage: {e}",
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
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_prompt_branches, _batch_position, _batch_total, _conversation_status
    with _lock:
        _batch_cancelled = True  # non-blocking flag, worker checks each iteration
        _conversation_status = "idle"
        was_running = _batch_running
        _batch_running = False
        remaining = _batch_total - _batch_position
        _batch_prompts = []
        _batch_prompt_modes = []
        _batch_prompt_branches = []
        _batch_position = 0
        _batch_total = 0
    if was_running:
        logger.info("Batch cancelled (%d prompts remaining)", remaining)
    return {"status": "cancelled", "remaining": remaining}


def cancel_batch_prompt(index: int) -> dict:
    """Cancel a single prompt in the batch queue by index."""
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_prompt_branches, _batch_position, _batch_total, _batch_skip_prompt

    with _lock:
        if not _batch_running:
            return {"error": "No batch running"}
        if index < 0 or index >= len(_batch_prompts):
            return {"error": f"Invalid index {index} (queue size: {len(_batch_prompts)})"}
        if index < _batch_position:
            return {"error": "Prompt already processed"}
        if index == _batch_position and _batch_skip_prompt:
            return {"error": "Cancel already in progress for current prompt"}

        removed = _batch_prompts.pop(index)
        mode_removed = _batch_prompt_modes.pop(index) if index < len(_batch_prompt_modes) else "code"
        branch_removed = _batch_prompt_branches.pop(index) if index < len(_batch_prompt_branches) else _batch_branch
        _batch_total -= 1

        if index == _batch_position:
            # Cancelling the currently-running prompt
            _batch_cancelled = True   # interrupt _wait_for_response
            _batch_skip_prompt = True # tell worker to skip, not clear queue
            logger.info("Batch: skipping current prompt [%d/%d]: %.60s...",
                        index + 1, _batch_total + 1, removed)
        else:
            # Cancelling a future prompt — just remove from queue
            logger.info("Batch: removed future prompt [%d/%d]: %.60s...",
                        index + 1, _batch_total + 1, removed)

        if _batch_total == 0:
            _batch_running = False
            logger.info("Batch: queue empty after per-prompt cancel")

        _persist_to_db()

    return {
        "status": "cancelled",
        "removed": removed[:200],
        "mode": mode_removed,
        "position": _batch_position,
        "total": _batch_total,
    }


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _send_message(conversation_id: str, prompt: str) -> tuple[bool, str | None]:
    """Send a follow-up message to an existing conversation via send-message endpoint.

    Returns (success, error_message). Handles 409 (sandbox paused/gone)
    by attempting to resume the sandbox and retrying once.

    Verified against OpenHands Cloud OpenAPI spec.
    """
    global _sandbox_id

    body = {
        "role": "user",
        "content": [{"type": "text", "text": prompt}],
        "run": True,
    }

    for attempt in range(2):
        try:
            resp = httpx.post(
                f"{CLOUD_API_URL}/api/v1/app-conversations/{conversation_id}/send-message",
                headers=_headers(),
                json=body,
                timeout=30,
            )
            resp.raise_for_status()
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 409:
                logger.warning("send-message 409: sandbox not running for %s", conversation_id)
                if attempt == 0 and _sandbox_id:
                    # Try resume sandbox, then retry
                    resume_err = _resume_sandbox(_sandbox_id)
                    if resume_err:
                        return False, f"Sandbox not running and resume failed: {resume_err}"
                    continue  # retry send-message
                return False, f"Sandbox not running (409). Please wait and try again."
            raise  # re-raise other HTTP errors

        data = resp.json()

        # Log full response to find where the agent response lives
        logger.info("send-message response keys: %s", list(data.keys()))
        for k, v in data.items():
            if isinstance(v, str) and len(v) > 10:
                logger.info("  %s: %s...", k, v[:300])
            elif isinstance(v, (list, dict)):
                logger.info("  %s: %s (len=%d)", k, type(v).__name__, len(v))
            else:
                logger.info("  %s: %s", k, repr(v)[:100])

        # Check success field in response body
        if not data.get("success", True):
            sandbox_status = data.get("sandbox_status", "unknown")
            msg = data.get("message", "")
            logger.error("send-message returned success=false (sandbox=%s): %s", sandbox_status, msg)
            return False, f"Agent not available (sandbox status: {sandbox_status}). {msg}".strip()

        # Update sandbox_id from response if we don't have it
        sandbox_status = data.get("sandbox_status", "")
        logger.info("send-message OK (sandbox=%s)", sandbox_status)
        return True, None

    return False, "Sandbox not running after resume attempt"


def _resume_sandbox(sandbox_id: str) -> str | None:
    """Resume a paused sandbox. Returns None on success, error message on failure."""
    try:
        resp = httpx.post(
            f"{CLOUD_API_URL}/api/v1/sandboxes/{sandbox_id}/resume",
            headers=_headers(),
            timeout=30,
        )
        resp.raise_for_status()
        logger.info("Sandbox %s resumed", sandbox_id)
        return None
    except Exception as e:
        logger.error("Failed to resume sandbox %s: %s", sandbox_id, e)
        return str(e)


def _create_conversation(prompt: str, repo: str, branch: str, mode: str) -> str:
    """Create a conversation via POST /api/v1/app-conversations (SAME as agent_runner).

    Returns the conversation_id. Raises on failure.
    """
    # Mode-specific prompt prefix
    if mode == "plan":
        if repo:
            full_prompt = (
                f"Repository: {repo} (branch: {branch}).\n"
                "IMPORTANT: First run `git pull` to get the latest code.\n"
                "IMPORTANT — PLAN MODE:\n"
                "1. FIRST, analyze the task and research the codebase. Read files, search, "
                "understand the architecture. Create a detailed implementation plan saved "
                "to .agents_tmp/PLAN.md. Do NOT implement anything yet.\n"
                "2. After creating the plan, present your findings and ask "
                "whether to proceed with implementation.\n"
                "IMPORTANT: Stop after EXPLORATION + ANALYSIS.\n\n"
                f"Task: {prompt}"
            )
        else:
            full_prompt = (
                "IMPORTANT — PLAN MODE:\n"
                "1. FIRST, analyze the request. Research, think through the problem, "
                "and create a detailed plan saved to .agents_tmp/PLAN.md. "
                "Do NOT implement anything.\n"
                "2. After creating the plan, present it to the user and ask "
                "whether to proceed.\n\n"
                f"Task: {prompt}"
            )
    elif repo:
        full_prompt = (
            f"Repository: {repo} (branch: {branch}).\n"
            "IMPORTANT: First run `git pull` to get the latest code. "
            "When implementing changes: review relevant files, make edits, "
            "commit with a descriptive message, and push.\n\n"
            f"{prompt}"
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


def _wait_for_response(timeout: int | None = None) -> str | None:
    """Poll conversation status + events until the agent finishes (SAME logic as agent_runner).

    Timeout: VIBECODE_CHAT_TIMEOUT env var (default 600s = 10 min).

    Also appends live events (tool calls, observations) to the chat history so the client
    can see what the agent is doing via polling get_state().

    Uses ID-based event dedup (same as agent_runner.py) — immune to API limit=N truncation.
    """

    if timeout is None:
        timeout = _CHAT_TIMEOUT

    global _conversation_status, _sandbox_id, _seen_event_ids, _agent_server_url, _session_api_key

    start = time.time()
    all_new_msgs: list[str] = []
    last_status = ""

    while time.time() - start < timeout:
        time.sleep(3)

        # Check for batch cancel — exit early if cancelled
        if _batch_cancelled or _batch_skip_prompt:
            logger.info("Batch cancelled/skipped during wait — exiting early (%d msgs collected)", len(all_new_msgs))
            with _lock:
                _conversation_status = "idle"
            return "\n\n".join(all_new_msgs) if all_new_msgs else ""  # empty str = no error in send()

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

        # Capture sandbox_id for sandbox management (resume, etc.)
        sid = items[0].get("sandbox_id")
        if sid and sid != _sandbox_id:
            _sandbox_id = sid
            logger.info("Conversation %s sandbox_id=%s", _conversation_id, sid)

        # Capture agent server URL + session key for direct event access
        conv_url = items[0].get("conversation_url", "")
        session_key = items[0].get("session_api_key", "")
        global _agent_server_url, _session_api_key
        if conv_url and session_key:
            _agent_server_url = conv_url.rsplit("/api/conversations", 1)[0]
            _session_api_key = session_key

        # Report status changes to UI
        if status != last_status:
            last_status = status
            _conversation_status = status
            elapsed = int(time.time() - start)
            logger.info("Conversation %s status=%s (elapsed %ds)",
                        _conversation_id, status, elapsed)

            # Stream status as visible event
            status_labels = {
                "starting": f"[STATUS] Agent is starting up... ({elapsed}s)",
                "running": f"[WORKING] Agent is working... ({elapsed}s)",
                "completed": f"[DONE] Task completed ({elapsed}s)",
                "finished": f"[DONE] Task finished ({elapsed}s)",
                "failed": f"[ERROR] Task failed ({elapsed}s)",
                "error": f"[ERROR] Error ({elapsed}s)",
                "stopped": f"[STOP] Task stopped ({elapsed}s)",
            }
            label = status_labels.get(status, f"[STATUS] Status: {status} ({elapsed}s)")
            with _lock:
                _msgs().append({
                    "role": "event",
                    "content": label,
                    "kind": "SystemEvent",
                    "timestamp": int(time.time() * 1000),
                })

        # -- Get events (prefer agent server — may return all events) --
        all_events = []
        try:
            if _agent_server_url and _session_api_key:
                # Agent server endpoint (session-key auth)
                agent_headers = {"X-Session-API-Key": _session_api_key}
                r2 = httpx.get(
                    f"{_agent_server_url}/api/conversations/{_conversation_id}/events/search",
                    headers=agent_headers,
                    params={"limit": 200},
                    timeout=10,
                )
            else:
                r2 = httpx.get(
                    f"{CLOUD_API_URL}/api/v1/conversation/{_conversation_id}/events/search",
                    headers=_headers(),
                    params={"limit": 100},
                    timeout=10,
                )
            r2.raise_for_status()
            events_data = r2.json()
        except Exception as e:
            logger.warning("Events poll error: %s", e)
            continue

        # Robust extraction
        if isinstance(events_data, list):
            all_events = events_data
        elif isinstance(events_data, dict):
            all_events = (
                events_data.get("items")
                or events_data.get("events")
                or events_data.get("data")
                or events_data.get("results")
                or []
            )

        # -- Process all collected events --

        new_count = len(all_events)
        if new_count > 0:
            logger.info("Conversation %s: %d events fetched (ID-based dedup)",
                        _conversation_id, new_count)
        else:
            # No events at all — log every 30s so we know polling works
            if int(time.time() - start) % 30 < 3:
                logger.info("Conversation %s: 0 events so far (elapsed %ds)",
                            _conversation_id, int(time.time() - start))

        # Stream EVERYTHING the agent does as live events (text, tools, observations)
        # ID-based dedup — process all returned events, skip previously seen by ID
        for evt in all_events:
            evt_id = evt.get("id", "")
            if evt_id and evt_id in _seen_event_ids:
                continue
            if evt_id:
                _seen_event_ids.add(evt_id)
            ts = evt.get("timestamp") or evt.get("created_at") or 0
            # API returns timestamps as ISO strings — convert to epoch millis
            if isinstance(ts, str):
                try:
                    ts = int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000)
                except (ValueError, TypeError):
                    ts = 0
            kind = evt.get("kind", "")
            source = evt.get("source", "")
            tool = evt.get("tool_name", "")

            # Track event kinds for diagnostics
            _event_kinds.add(kind)

            if kind == "MessageEvent":
                # Skip user messages (initial prompt echo) — only show agent text
                if source == "user":
                    continue
                # API returns llm_message (a Message object), not plain "message"
                llm_msg = evt.get("llm_message") or evt.get("message") or {}
                text = ""
                if isinstance(llm_msg, str) and llm_msg.strip():
                    text = llm_msg.strip()
                elif isinstance(llm_msg, dict):
                    # content is [{type: "text", text: "..."}, ...]
                    content = llm_msg.get("content") or []
                    if isinstance(content, list):
                        parts = []
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "text":
                                t = block.get("text", "")
                                if t.strip():
                                    parts.append(t.strip())
                        text = "\n".join(parts)
                    elif isinstance(content, str):
                        text = content.strip()
                if text:
                    # OpenHands API returns cumulative llm_message content
                    # (each MessageEvent contains all prior text + new delta).
                    # Deduplicate: if new text starts with the previous entry,
                    # replace it — otherwise append as a fresh message.
                    if all_new_msgs and text.startswith(all_new_msgs[-1]):
                        all_new_msgs[-1] = text
                    else:
                        all_new_msgs.append(text)
                    with _lock:
                        _msgs().append({
                            "role": "event",
                            "content": f"[MSG] {text}",
                            "kind": kind,
                            "timestamp": int(time.time() * 1000),
                        })
                else:
                    logger.warning("MessageEvent found but NO text extracted: source=%s llm_msg_keys=%s",
                                   source, sorted(llm_msg.keys()) if isinstance(llm_msg, dict) else type(llm_msg).__name__)

            # Stream tool calls, observations, errors as live events
            event_preview = _format_event_preview(evt)
            if event_preview:
                with _lock:
                    _msgs().append({
                        "role": "event",
                        "content": event_preview,
                        "kind": kind,
                        "tool_name": tool,
                        "timestamp": int(time.time() * 1000),
                    })

        # Advance the seen index
        # (ID-based dedup above handles this — nothing to reset here)

        if status in ("completed", "finished"):
            _conversation_status = "idle"
            logger.info("Conversation %s: finished. Kinds=%s new_msgs=%d total_msgs=%d",
                        _conversation_id,
                        sorted(_event_kinds),
                        len(all_new_msgs),
                        len(_msgs()))
            break
        elif status in ("failed", "error", "stopped"):
            _conversation_status = "idle"
            err_detail = items[0].get("error_message", "unknown error")
            err_type = items[0].get("error_type", "")
            logger.warning("Conversation %s: type=%s detail=%s", status, err_type, err_detail)
            # Stream the failure as a visible event
            parts = [f"[ERROR] Conversation {status}"]
            if err_type:
                parts.append(f"Type: {err_type}")
            parts.append(f"Message: {err_detail}")
            with _lock:
                _msgs().append({
                    "role": "event",
                    "content": "\n".join(parts),
                    "kind": "ErrorEvent",
                    "timestamp": int(time.time() * 1000),
                })
            return None

    if not all_new_msgs:
        elapsed = int(time.time() - start)
        logger.warning("No assistant messages found after %ds (status=%s)", elapsed, last_status)
        logger.warning("All event kinds seen: %s", sorted(_event_kinds))
        logger.warning("Total events in last poll: %d, stored messages: %d", len(all_events), len(_msgs()))
        with _lock:
                    _msgs().append({
                        "role": "event",
                        "content": f"[WARN] No response from agent after {elapsed}s (status: {last_status or 'unknown'}). The agent may be stuck or the LLM may not be configured correctly on the server.",
                        "kind": "SystemEvent",
                        "timestamp": int(time.time() * 1000),
                    })

    _conversation_status = "idle"
    response = "\n\n".join(all_new_msgs) if all_new_msgs else None

    # OpenHands Cloud returns cumulative llm_message content — each new
    # MessageEvent includes ALL prior assistant responses as a prefix.
    # Strip them chronologically so only the NEW text remains.
    if response:
        with _lock:
            for m in _msgs():
                if m.get("role") == "assistant" and m.get("content"):
                    prev = m["content"]
                    if prev and response.startswith(prev):
                        response = response[len(prev):].lstrip("\n")
    return response if response else None



def _scrape_events_for_text(events: list[dict]) -> str | None:
    """Fallback: extract any text from events when no MessageEvent found.

    Tries: llm_message.content, observation.content, action.thought, error fields.
    """
    parts: list[str] = []
    for evt in events:
        kind = evt.get("kind", "")
        # llm_message (MessageEvent, any source)
        if kind == "MessageEvent" and evt.get("source") == "user":
            continue  # never scrape user's own messages
        llm_msg = evt.get("llm_message") or evt.get("message")
        if isinstance(llm_msg, dict):
            content = llm_msg.get("content") or []
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("text"):
                        parts.append(str(block["text"]))
            elif isinstance(content, str) and content.strip():
                parts.append(content.strip())
        # Observation content (tool results with text)
        obs = evt.get("observation")
        if isinstance(obs, dict):
            obs_content = obs.get("content") or []
            if isinstance(obs_content, list):
                for block in obs_content:
                    if isinstance(block, dict) and block.get("text"):
                        t = str(block["text"]).strip()
                        if t and len(t) > 20:  # skip trivial messages
                            parts.append(t)
            elif isinstance(obs_content, str) and obs_content.strip():
                parts.append(obs_content.strip())
        # Action thought (agent reasoning before tool call)
        thought = evt.get("thought")
        if isinstance(thought, list):
            for item in thought:
                if isinstance(item, dict) and item.get("text"):
                    parts.append(str(item["text"]))
        # Error text
        err = evt.get("error")
        if isinstance(err, str) and err.strip():
            parts.append(err)
    text = "\n\n".join(parts).strip()
    return text if text else None


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
                return f"[TERMINAL] $ {cmd}"
        elif tool in ("file_editor", "str_replace_editor"):
            cmd = (action.get("command") or "").strip()
            path = action.get("path", "") or action.get("file", "")
            if not cmd:
                logger.warning("file_editor ActionEvent: NO command in action. keys=%s tool=%s",
                               sorted(action.keys()) if isinstance(action, dict) else type(action).__name__,
                               tool)
            if path:
                if cmd == "view":
                    return f"[READ] Reading: {path}"
                if cmd == "create":
                    return f"[EDIT] Creating: {path}"
                if cmd == "undo_edit":
                    return f"[UNDO] Undoing: {path}"
                return f"[EDIT] Editing: {path}"
        elif tool in ("tavily_search", "tavily_tavily_search"):
            q = action.get("query", "") or action.get("content", "")
            if q:
                return f"[SEARCH] Searching: {q}"
        elif tool == "browser_navigate":
            url = action.get("url", "")
            if url:
                return f"[BROWSER] Navigate: {url}"
        else:
            # Unknown tool — show tool name + first action key for visibility
            return f"[TOOL] {tool}: {str(action)[:120]}"

    elif kind == "ObservationEvent":
        obs = evt.get("observation")
        if obs is None:
            return None
        if isinstance(obs, str):
            try:
                obs = json.loads(obs)
            except Exception:
                obs = {"output": str(obs)}
        elif not isinstance(obs, dict):
            # bool, int, float, list — wrap in dict
            obs = {"output": str(obs)}

        if tool in ("bash", "terminal", "execute_bash_command"):
            stdout = obs.get("stdout", "") or obs.get("output", "") or obs.get("content", "")
            stderr = obs.get("stderr", "")
            exit_code = obs.get("exit_code")
            out = stdout or stderr
            if out:
                short = str(out)[:200].replace("\n", " ").strip()
                tag = "[OUT] " if not stderr else "[WARN] stderr: "
                extra = f" (exit={exit_code})" if exit_code is not None and exit_code != 0 else ""
                return f"{tag}{short}{extra}"
        elif tool in ("file_editor", "str_replace_editor"):
            diff = obs.get("diff", "")
            if diff:
                return f"[FILE] Diff ({len(diff)} chars)"
            path = obs.get("path", "")
            if path:
                return f"[FILE] File: {path}"
        elif tool in ("tavily_search", "tavily_tavily_search"):
            results = obs.get("results", [])
            if isinstance(results, list) and results:
                lines = [f"[RESULTS] {len(results)} search results:"]
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
                return f"[BROWSER] Page: ({len(str(text))} chars)"
        else:
            # skip unknown observations
            return None

    elif kind == "ErrorEvent":
        msg = evt.get("message", "")
        error_type = evt.get("error_type", "") or evt.get("type", "")
        text = msg or error_type or "Unknown error"
        return f"[ERROR] {text[:300]}"
    # Catch-all: skip unknown event types
    return None
