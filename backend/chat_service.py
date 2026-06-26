"""Chat service — reusable conversation with token-efficient message continuation.

Uses OpenHands Cloud REST API (verified against OpenAPI spec):
- First message: POST /api/v1/app-conversations (creates conversation)
- Subsequent:   POST /api/v1/app-conversations/{id}/send-message (reuses conversation)
- Status poll:  GET  /api/v1/app-conversations?ids={id}
- Events poll:  GET  /api/v1/conversation/{id}/events/search

Thread-safe: _lock serializes access to module-level session state.
State persisted to SQLite — survives server restart.
"""
import base64
import httpx
import json
import logging
import os
import re
import threading
import time
from datetime import datetime, timezone, timedelta

from database import get_sync_db
from agent_runner import get_llm_config, AgentConfig

logger = logging.getLogger(__name__)

CLOUD_API_URL = os.getenv("OPENHANDS_CLOUD_API_URL", "https://app.all-hands.dev")
CLOUD_API_KEY = os.getenv("OPENHANDS_CLOUD_API_KEY", "")

# -- Session state (persisted to DB, survives restart) --
_conversation_id: str | None = None
_conv_id_at_last_assistant: str | None = None  # conversation ID when last assistant msg was stored
_conversation_repo: str = ""
_conversation_branch: str = ""
_conversation_mode: str = "code"
_conversation_llm_model: str = ""  # model used when current Cloud conversation was created
_last_event_index: int = 0
_last_event_timestamp: str = ""  # timestamp of last seen event for min_timestamp filtering
_sandbox_id: str | None = None
_event_kinds: set[str] = set()  # diagnostic: all event kinds seen in current conversation
_seen_event_ids: set[str] = set()  # dedup: event IDs already added to chat
# Content hashes for events without Cloud API IDs (persistent across send() calls)
_seen_event_hashes: set[int] = set()
_current_repo_key: str = ""  # current repo — determines which chat history to show
_messages_by_repo: dict[str, list[dict]] = {}  # per-repo chat history
_msg_counter: int = 0  # monotonically increasing message ID
_lock = threading.Lock()
_processing_repo: str = ""  # repo currently being processed by a non-batch send()

def _next_msg_id() -> int:
    global _msg_counter
    _msg_counter += 1
    return _msg_counter

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
_batch_position: int = 0
_batch_total: int = 0
_batch_repo: str = ""
_batch_branch: str = ""
_batch_mode: str = "code"
_batch_running: bool = False
_batch_cancelled: bool = False
_batch_skip_prompt: bool = False  # set by per-prompt cancel, tells worker to skip current
_batch_started_at: float = 0.0  # set by _process_batch_worker; read by enqueue_batch for stale detection

# Response source tracking for Phase 3 diagnostics
# Set by _wait_for_response() before returning:
# "events/search" - MessageEvent from event poll (normal path)
# "zip"           - MessageEvent from trajectory zip fallback
# "scrape"        - text scraped from observation events
# ""              - no response found
_last_response_source: str = "events/search"

# Current conversation status (for UI visibility)
_conversation_status: str = "idle"
_CHAT_TIMEOUT = int(os.getenv("VIBECODE_CHAT_TIMEOUT", "7200"))  # 2 hour default (large tasks like Flutter builds)

# -- Task log: server-side cache, GitHub is mirror --
# Primary source of truth: in-memory cache. Writes to GitHub are async/background.
# This eliminates 1-3s delay per task and survives GitHub API downtime.
_log_entries: dict[str, list[dict]] = {}       # repo → parsed entries (latest first)
_log_entries_ts: dict[str, float] = {}          # repo → last fetch from GitHub
_log_dirty: set[str] = set()                    # repos needing GitHub sync
_log_sync_lock = threading.Lock()


def _log_append_local(repo: str, entry: dict) -> None:
    """Append entry to in-memory cache (instant). Mark repo dirty for GitHub sync."""
    if repo not in _log_entries:
        _log_entries[repo] = []
    # Insert at beginning (latest first)
    _log_entries[repo].insert(0, entry)
    _log_entries_ts[repo] = time.time()  # refresh cache TTL so new entries are visible
    _log_dirty.add(repo)
    # Kick background sync
    _start_log_sync()


def _start_log_sync() -> None:
    """Start a background thread to sync dirty repos to GitHub."""
    t = threading.Thread(target=_log_sync_worker, daemon=True, name="log-sync")
    t.start()


def _log_sync_worker() -> None:
    """Sync ONE dirty repo to GitHub, then exit. Next append starts a new thread if needed."""
    with _log_sync_lock:
        if not _log_dirty:
            return
        repo = _log_dirty.pop()
        if repo not in _log_entries:
            return
        entries = list(_log_entries[repo])
    # Sync outside lock
    _log_sync_to_github(repo, entries)


def _log_sync_to_github(repo: str, entries: list[dict]) -> None:
    """Merge local entries with existing GitHub VIBECODER_LOG.md, then write back.

    Reads the existing file from GitHub (if any), parses it, merges with local
    entries, deduplicates by prompt prefix, and writes the merged result.
    This prevents losing entries written by parallel processes or earlier sessions.
    """
    if not repo or not entries:
        return
    try:
        # 1. Fetch existing file from GitHub
        existing_entries: list[dict] = []
        existing_sha = ""
        sha_resp = httpx.get(
            f"https://api.github.com/repos/{repo}/contents/VIBECODER_LOG.md",
            headers=_gh_headers(),
            timeout=10,
        )
        if sha_resp.status_code == 200:
            body = sha_resp.json()
            existing_sha = body.get("sha", "")
            raw = base64.b64decode(body.get("content", "")).decode("utf-8", errors="replace")
            existing_entries = _parse_log_md(raw)
        elif sha_resp.status_code != 404:
            logger.warning("VIBECODER_LOG.md sync: GET failed HTTP %s", sha_resp.status_code)
            return

        # 2. Merge: local entries + existing, dedup by prompt prefix (case-insensitive)
        seen = set()
        merged: list[dict] = []
        for e in entries:
            key = (e.get("request", "") or e.get("summary", ""))[:200].strip().lower()
            if key and key not in seen:
                seen.add(key)
                merged.append(e)
        for e in existing_entries:
            key = (e.get("request", "") or e.get("summary", ""))[:200].strip().lower()
            if key and key not in seen:
                seen.add(key)
                merged.append(e)

        # 3. Sort: latest first
        merged.sort(key=lambda e: e.get("timestamp", ""), reverse=True)

        # 4. Build markdown (chronological: oldest first for readability)
        lines = ["## VibeCoder Task Log\n"]
        for e in reversed(merged):
            ts = e.get("timestamp", "")
            summary = e.get("summary", "")
            request = e.get("request", "")
            status = e.get("status", "")
            details = e.get("details", "")
            files = e.get("files", "")
            lines.append(f"\n\n## {ts} — {summary}")
            if request:
                lines.append(f"\n**Request:** {request}")
            if status:
                lines.append(f"\n**Status:** {status}")
            if details:
                lines.append(f"\n**What was done:** {details}")
            if files:
                lines.append(f"\n**Files changed:** {files}")
        new_content = "".join(lines)

        # 5. PUT back to GitHub with retry
        body_put = {
            "message": f"vibecoder: log update ({len(merged)} tasks)",
            "content": base64.b64encode(new_content.encode()).decode(),
        }
        if existing_sha:
            body_put["sha"] = existing_sha

        put_ok = False
        last_status = 0
        for attempt in range(3):
            if attempt > 0:
                time.sleep(2 ** attempt)  # 2s, 4s, 8s backoff
                # Re-fetch SHA in case it changed
                sha_resp2 = httpx.get(
                    f"https://api.github.com/repos/{repo}/contents/VIBECODER_LOG.md",
                    headers=_gh_headers(), timeout=10,
                )
                if sha_resp2.status_code == 200:
                    body_put["sha"] = sha_resp2.json().get("sha", existing_sha)

            put_resp = httpx.put(
                f"https://api.github.com/repos/{repo}/contents/VIBECODER_LOG.md",
                headers=_gh_headers(),
                json=body_put,
                timeout=15,
            )
            last_status = put_resp.status_code
            if last_status in (200, 201):
                put_ok = True
                break
            logger.warning("VIBECODER_LOG.md sync attempt %d/3: HTTP %s",
                          attempt + 1, last_status)

        if put_ok:
            logger.info("VIBECODER_LOG.md synced: %s (%d tasks merged)", repo, len(merged))
        else:
            logger.warning("VIBECODER_LOG.md sync FAILED after 3 attempts: HTTP %s — %s",
                          last_status, "")
            with _log_sync_lock:
                _log_dirty.add(repo)
    except Exception as e:
        logger.warning("VIBECODER_LOG.md sync error: %s", e)
        with _log_sync_lock:
            _log_dirty.add(repo)

# -- Restore state from DB on module load --
def _restore_from_db() -> None:
    global _conversation_id, _conv_id_at_last_assistant, _conversation_repo, _conversation_branch, _conversation_mode, _conversation_llm_model, _last_event_index, _last_event_timestamp, _messages_by_repo, _current_repo_key
    global _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _batch_running, _batch_cancelled, _batch_skip_prompt
    global _msg_counter
    global _seen_event_ids, _seen_event_hashes
    try:
        db = get_sync_db()
    except Exception:
        return
    try:
        row = db.execute("SELECT value FROM kv_store WHERE key = 'chat_session'").fetchone()
        if row:
            data = json.loads(row[0])
            _conversation_id = data.get("conversation_id")
            _conv_id_at_last_assistant = data.get("conv_id_at_last_assistant")
            _conversation_repo = data.get("repo", "")
            _conversation_branch = data.get("branch", "")
            _conversation_mode = data.get("mode", "code")
            _conversation_llm_model = data.get("llm_model", "")
            _last_event_index = data.get("last_event_index", 0)
            _last_event_timestamp = data.get("last_event_timestamp", "")
            _messages_by_repo = data.get("messages_by_repo", {})
            # Migrate old "repo|mode" keys to flat "repo" keys
            _messages_by_repo = _migrate_keys(_messages_by_repo)
            _current_repo_key = data.get("current_repo_key", _repo_key(_conversation_repo))
            # Restore batch queue if server restarted mid-batch
            _batch_prompts = data.get("batch_prompts", [])
            _batch_prompt_modes = data.get("batch_prompt_modes", [])
            _batch_position = data.get("batch_position", 0)
            _batch_total = data.get("batch_total", 0)
            _batch_cancelled = data.get("batch_cancelled", False)
            _batch_skip_prompt = data.get("batch_skip_prompt", False)
            # Auto-resume if server restarted mid-batch (remaining prompts in queue)
            _batch_running = _batch_position < _batch_total and len(_batch_prompts) > _batch_position
            _msg_counter = data.get("msg_counter", 0)
            # Restore seen event IDs and content hashes so the first message
            # after boot correctly deduplicates old events instead of re-adding
            # them with new local IDs (step count inflation fix).
            _seen_event_ids = set(data.get("seen_event_ids", []))
            _seen_event_hashes = set(data.get("seen_event_hashes", []))
            # AUDIT: log all restored state so ANY boot issue is detectable
            repo_msgs = {k: len(v) for k, v in _messages_by_repo.items()}
            event_count = sum(1 for m in _messages_by_repo.get(_current_repo_key, []) if m.get("role") == "event")
            logger.info("AUDIT BOOT: conv=%s repo=%s branch=%s mode=%s model=%s "
                        "idx=%d ts=%s msgs_by_repo=%s cur_key=%s msg_counter=%d "
                        "seen_ids=%d seen_hashes=%d events_in_cur_repo=%d",
                        _conversation_id, _conversation_repo, _conversation_branch,
                        _conversation_mode, _conversation_llm_model,
                        _last_event_index, _last_event_timestamp or "(none)",
                        repo_msgs, _current_repo_key, _msg_counter,
                        len(_seen_event_ids), len(_seen_event_hashes),
                        event_count)
            if _batch_running and not _batch_cancelled:
                # Use globals() lookup so _process_batch_worker is resolved at
                # runtime (it's defined later in the file, after this function).
                _fn = globals().get('_process_batch_worker')
                if _fn:
                    threading.Thread(target=_fn, daemon=True).start()
                    logger.info("Auto-resuming batch: %d/%d remaining", _batch_total - _batch_position, _batch_total)
                else:
                    logger.error("Cannot resume batch: _process_batch_worker not yet defined")
            elif _batch_cancelled:
                logger.info("Batch was cancelled before restart — not resuming")
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
            "conv_id_at_last_assistant": _conv_id_at_last_assistant,
            "repo": _conversation_repo,
            "branch": _conversation_branch,
            "mode": _conversation_mode,
            "llm_model": _conversation_llm_model,
            "last_event_index": _last_event_index,
            "last_event_timestamp": _last_event_timestamp,
            "messages_by_repo": _messages_by_repo,
            "current_repo_key": _current_repo_key,
            # Batch state for survival across restarts
            "batch_prompts": _batch_prompts,
            "batch_prompt_modes": _batch_prompt_modes,
            "batch_position": _batch_position,
            "batch_total": _batch_total,
            "batch_running": _batch_running,
            "batch_cancelled": _batch_cancelled,
            "batch_skip_prompt": _batch_skip_prompt,
            "batch_repo": _batch_repo,
            "batch_branch": _batch_branch,
            "batch_mode": _batch_mode,
            "msg_counter": _msg_counter,
            # Persist seen event IDs so boot correctly deduplicates
            "seen_event_ids": list(_seen_event_ids),
            "seen_event_hashes": list(_seen_event_hashes),
        })
        db.execute(
            "INSERT OR REPLACE INTO kv_store (key, value) VALUES ('chat_session', ?)",
            (data,),
        )
        db.commit()
        # AUDIT: log persist summary
        cur_msgs = _msgs()
        event_count = sum(1 for m in cur_msgs if m.get("role") == "event")
        logger.info("AUDIT persist: conv=%s msgs=%d events=%d seen_ids=%d msg_counter=%d ts=%s",
                    _conversation_id, len(cur_msgs), event_count,
                    len(_seen_event_ids), _msg_counter,
                    _last_event_timestamp or "(none)")
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
    global _conversation_id, _conv_id_at_last_assistant, _conversation_repo, _conversation_branch, _conversation_mode, _conversation_llm_model, _last_event_index, _last_event_timestamp, _messages_by_repo, _event_kinds, _conversation_status, _sandbox_id, _current_repo_key
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _batch_skip_prompt
    with _lock:
        # Cancel running batch
        if _batch_running:
            _batch_cancelled = True
            _batch_skip_prompt = False
            _batch_running = False
            _batch_prompts = []
            _batch_prompt_modes = []
            _batch_position = 0
            _batch_total = 0
            logger.info("Batch cancelled by chat reset")
        # Reset conversation
        _conversation_id = None
        _conv_id_at_last_assistant = None
        _conversation_repo = ""
        _conversation_branch = ""
        _conversation_mode = "code"
        _conversation_llm_model = ""
        _last_event_index = 0
        _last_event_timestamp = ""
        _event_kinds.clear()
        _seen_event_ids.clear()
        _seen_event_hashes.clear()
        _sandbox_id = None
        _messages_by_repo.pop(_current_repo_key, None)  # clear current repo's history
        _current_repo_key = ""
        _conversation_status = "idle"
        _persist_to_db()
    logger.info("Chat session reset")


def get_state(repo: str = "", mode: str = "") -> dict:
    """Return chat state for API consumers.
    
    Messages are filtered by repo so cross-device polling never leaks
    conversations. Batch queue state is ALSO repo-scoped — Device B on
    repo B does NOT see Device A's batch running on repo A.
    """
    global _current_repo_key
    with _lock:
        # Filter messages by requested repo
        if repo:
            msgs = list(_messages_by_repo.get(_repo_key(repo), []))
        else:
            msgs = list(_msgs())
        event_count = sum(1 for m in msgs if m.get("role") == "event")
        
        # Batch state: repo-scoped. If the batch repo doesn't match the
        # requested repo, report it as idle so Device B doesn't show a
        # spinner for Device A's batch on repo A.
        batch_repo_matches = (
            not repo or (_batch_repo and _batch_repo == repo)
        )
        logger.info(
            "AUDIT get_state: repo=%s batch.repo=%s match=%s "
            "running=%s msgs=%d events=%d",
            repo or '(none)', _batch_repo, batch_repo_matches,
            _batch_running, len(msgs), event_count,
        )
        batch_info = {
            "running": _batch_running and batch_repo_matches,
            "cancelled": _batch_cancelled,
            "position": _batch_position if batch_repo_matches else 0,
            "total": _batch_total if batch_repo_matches else 0,
            "done": _batch_position if batch_repo_matches else 0,
            "repo": _batch_repo if batch_repo_matches else "",
            "prompts": list(_batch_prompts) if batch_repo_matches else [],
            "modes": list(_batch_prompt_modes) if batch_repo_matches else [],
        }
        
        # Include the model the current conversation was created with AND
        # the currently configured model (may differ after a settings change).
        from agent_runner import get_llm_config
        try:
            configured_model = get_llm_config().model
        except Exception:
            configured_model = ""
        
        return {
            "messages": msgs,
            "conversation_id": _conversation_id,
            "sandbox_id": _sandbox_id,
            # Return the requested repo (not global _conversation_repo) so
            # each device gets back what it asked for, never a different repo.
            "repo": repo if repo else _conversation_repo,
            "branch": _conversation_branch,
            "mode": _conversation_mode,
            "current_repo_key": _current_repo_key,
            "conversation_status": _conversation_status,
            "llm_model": _conversation_llm_model,
            "configured_model": configured_model,
            "batch": batch_info,
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


def _gh_headers(extra: dict | None = None) -> dict:
    """GitHub API headers with optional auth token."""
    h = {"Accept": "application/vnd.github+json"}
    token = os.getenv("GITHUB_TOKEN", "")
    if token:
        h["Authorization"] = f"Bearer {token}"
    if extra:
        h.update(extra)
    return h


def _auto_append_log(repo: str, prompt: str, response: str, *, ok: bool) -> None:
    """Append a task entry to the in-memory log cache (instant).
    
    GitHub sync happens asynchronously in a background thread.
    Deduplicates by checking if the prompt already appears.
    Response summary is cleaned: markdown stripped, code blocks removed.
    """
    if not repo:
        return
    try:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M")
        one_line = prompt[:80].replace("\n", " ").strip()
        if len(prompt) > 80:
            one_line += "…"

        # Clean response for summary: strip markdown, code blocks, links
        import re
        cleaned = response.strip() if response else ""
        # Remove code blocks (```...```)
        cleaned = re.sub(r'```[\s\S]*?```', ' ', cleaned)
        # Remove inline code (`...`)
        cleaned = re.sub(r'`[^`]+`', ' ', cleaned)
        # Remove markdown links [...](...)
        cleaned = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', cleaned)
        # Remove markdown headers (# ..., ## ...)
        cleaned = re.sub(r'^#{1,6}\s+', '', cleaned, flags=re.MULTILINE)
        # Remove bold/italic markers
        cleaned = re.sub(r'\*{1,3}([^*]+)\*{1,3}', r'\1', cleaned)
        # Collapse whitespace
        cleaned = re.sub(r'\s+', ' ', cleaned).strip()

        if not cleaned:
            summary = "(no output)"
        else:
            sentences = re.split(r'(?<=[.!?])\s+', cleaned)
            summary_sentences = [s for s in sentences[:3] if len(s) > 5]  # skip very short fragments
            summary = " ".join(summary_sentences) if summary_sentences else cleaned[:200]
            words = summary.split()
            if len(words) > 80:
                summary = " ".join(words[:80]) + "…"
            if not summary:
                summary = "(no output)"

        status = "[OK] Success" if ok else "[FAIL] Failed"

        # Dedup against in-memory cache
        existing = _log_entries.get(repo, [])
        for e in existing:
            if e.get("request", "")[:200] == prompt[:200]:
                logger.debug("VIBECODER_LOG.md: skipping duplicate for %.80s", prompt)
                return

        entry = {
            "timestamp": ts,
            "summary": one_line,
            "request": prompt[:200].replace("\n", " "),
            "status": status,
            "details": summary,
            "files": "",
        }
        _log_append_local(repo, entry)
        logger.info("VIBECODER_LOG.md cached: %s — %s", ts, one_line)

    except Exception as e:
        logger.warning("VIBECODER_LOG.md append error: %s", e)


def send(prompt: str, repo: str = "", branch: str = "", mode: str = "code", _from_batch: bool = False) -> dict:
    """Send a chat message and wait for the agent response (synchronous).

    Creates a new conversation when repo or mode changes.
    HTTP calls (create/send) happen OUTSIDE _lock so get_state() polling is never blocked.
    """
    global _conversation_id, _conversation_repo, _conversation_branch
    global _conversation_mode, _conversation_llm_model, _last_event_index
    global _last_event_timestamp, _sandbox_id, _processing_repo
    global _batch_running, _batch_repo, _batch_prompts, _batch_prompt_modes
    global _batch_position, _batch_total, _batch_cancelled, _batch_skip_prompt
    global _current_repo_key, _conversation_status, _last_completed_no_msg

    if not CLOUD_API_KEY:
        logger.error("send: CLOUD_API_KEY not configured")
        return {"error": "OPENHANDS_CLOUD_API_KEY not configured on server"}

    # Validate repo — empty or invalid format is a hard error
    repo = repo.strip()
    branch = branch.strip()
    if not repo:
        logger.error("send: repo is empty — blocking send")
        return {"error": "Repository (owner/repo) is required"}
    import re as _send_re
    if not _send_re.match(r'^[\w.-]+/[\w.-]+$', repo):
        logger.error("send: invalid repo format: '%s'", repo)
        return {"error": f"Invalid repo format: '{repo}'. Use owner/repo"}

    # Validate repo exists on GitHub (non-blocking on network error)
    exists = _repo_exists(repo)
    if exists is False:
        logger.error("send: repo '%s' not found on GitHub — blocking send", repo)
        return {"error": f"Repository '{repo}' not found on GitHub. Check the name and try again."}
    if exists is None:
        logger.warning("send: cannot verify repo '%s' — GitHub API error, proceeding anyway", repo)

    # Guard: if called externally while batch is running, auto-enqueue instead.
    # Batch worker passes _from_batch=True to bypass this guard.
    # CRITICAL: Also prevents concurrent non-batch send() for the same repo.
    # When two requests arrive at the same time (e.g. double-tap, retry),
    # both would pass Phase 1a with `_conversation_id is None` and create
    # SEPARATE conversations. Both Phase 3 write to the SAME _messages_by_repo,
    # producing TWO assistant messages for what the user expects to be ONE
    # response. This is the #1 root cause of the "duplicate response" bug.
    if not _from_batch:
        with _lock:
            if _batch_running:
                if repo != _batch_repo:
                    logger.warning("send: BLOCKED auto-enqueue — batch running with repo=%s but send asked for repo=%s",
                                   _batch_repo, repo)
                    return {
                        "error": (
                            f"Batch already running with repo={_batch_repo or '(none)'}. "
                            f"Switching to repo={repo} mid-batch is not allowed. "
                            "Wait for the current batch to finish, then try again."
                        )
                    }
                _batch_prompts.append(prompt)
                _batch_prompt_modes.append(mode)
                _batch_total = len(_batch_prompts)
                _persist_to_db()
                logger.info("Batch running — auto-enqueued prompt (now %d total)", _batch_total)
                return {"status": "appended", "position": _batch_position, "total": _batch_total}
            # Guard: if ANY repo is being processed, block send() to a DIFFERENT
            # repo. This prevents cross-device conflict (Device A processes repo A,
            # Device B sends to repo B) which would create two concurrent Cloud
            # conversations sharing the same sandbox.
            if _processing_repo and _processing_repo != repo:
                logger.warning("send: BLOCKED — repo %s is being processed, cannot send to repo %s",
                               _processing_repo, repo)
                return {
                    "error": (
                        f"Repo {_processing_repo} is currently being processed. "
                        f"Cannot send to repo {repo}. "
                        "Wait for processing to finish, then try again."
                    )
                }
            # No batch running. Check if another non-batch send() is already
            # processing THIS repo (concurrent requests). If so, auto-start a
            # batch queue so they're processed sequentially instead of both
            # creating separate conversations and writing duplicate responses.
            if _processing_repo == repo:
                logger.info("Concurrent send() detected for repo=%s — starting batch queue", repo)
                _batch_running = True
                _batch_repo = repo
                _batch_prompts = [prompt]
                _batch_prompt_modes = [mode]
                _batch_position = 0
                _batch_total = 1
                _batch_skip_prompt = False
                _batch_cancelled = False
                _persist_to_db()
                # Start worker thread to process queued prompts
                import threading
                t = threading.Thread(target=_process_batch_worker, daemon=True)
                t.start()
                return {"status": "queued", "position": 0, "total": 1}
            # Mark this repo as being processed (cleared in finally block)
            _processing_repo = repo

    # DO NOT reset event cursors here — _last_event_index, _last_event_timestamp,
    # and _seen_event_ids persist across send() calls so the SECOND message in a
    # batch correctly fetches ONLY new events (not re-processing the first message's).
    # Reset happens inside Phase 1a when ctx_changed triggers a new conversation.
    # Reset cancel flag so a stale _batch_cancelled from a previous send doesn't
    # immediately abort this one. _wait_for_response sets it to True only if
    # cancel_batch() is called during this send() call.
    with _lock:
        _batch_cancelled = False
    logger.info("Chat send: prompt=%.80s... repo=%s branch=%s mode=%s", prompt, repo, branch or '(empty)', mode)

    # Phase 0: Branch detection + validation
    # If user typed a branch, verify it exists. If verification fails (API
    # error, rate limited), assume valid rather than rejecting a good branch.
    # If branch is actually invalid, fallback gracefully instead of erroring out.
    branch_provided = bool(branch)
    default_branch = None
    if branch_provided:
        valid_branches = get_branches(repo)
        default_branch = _detect_default_branch(repo)
        all_valid = valid_branches + ([default_branch] if default_branch and default_branch not in valid_branches else [])
        if branch not in all_valid:
            if valid_branches:
                # API returned a real list — branch is genuinely invalid.
                # Fallback: use default branch (or leave empty for auto-detect).
                logger.warning("send: branch '%s' not found in %s — available: %s, falling back",
                              branch, repo, all_valid[:10])
                branch = ""  # clear invalid branch — auto-detect takes over
                branch_provided = False
            else:
                # API returned empty (network error, rate limit, etc.).
                # Don't reject a potentially valid branch.
                logger.warning("send: cannot verify branch '%s' for %s — API failed, assuming valid",
                              branch, repo)
        else:
            logger.info("send: branch '%s' validated for %s", branch, repo)

    # Phase 0b: Determine effective branch for this send()
    # If user provided a branch, use it. If not, use conversation default.
    effective_branch = branch if branch else (_conversation_branch or default_branch or "")
    logger.info("send: effective_branch='%s' (provided='%s' conv='%s' default='%s')",
                effective_branch, branch, _conversation_branch, default_branch or "")

    # Phase 1a: Quick check under lock — do we need a new conversation?
    with _lock:
        # effective_branch already computed in Phase 0b: branch (validated) or
        # _conversation_branch or default_branch or ""
        # Detect LLM model change — the current Cloud conversation was
        # created with _conversation_llm_model; if get_llm_config() now
        # returns a different model, force a new conversation (same as
        # mode/repo change). This preserves message history in _messages_by_repo.
        # Skip model check for batch messages so a single batch doesn't create
        # multiple conversations if the model changes mid-batch.
        cfg = get_llm_config()
        current_model = cfg.model if cfg else ""
        model_changed = (
            not _from_batch
            and _conversation_id is not None
            and _conversation_llm_model
            and current_model
            and current_model != _conversation_llm_model
        )
        if model_changed:
            logger.info("Model changed '%s'→'%s' — will create new conversation",
                        _conversation_llm_model, current_model)
        ctx_changed = (
            _conversation_id is not None
            and (repo != _conversation_repo or mode != _conversation_mode or model_changed)
        )
        branch_switched = (
            _conversation_id is not None
            and not ctx_changed
            and effective_branch != _conversation_branch
        )
        # AUDIT: log Phase 1a decision state
        logger.info("AUDIT 1a: conv=%s repo=%s mode=%s model=%s cur_model=%s "
                    "from_batch=%s model_changed=%s ctx=%s branch_sw=%s need_new=%s conv_status=%s",
                    _conversation_id or "(none)", _conversation_repo, _conversation_mode,
                    _conversation_llm_model or "(none)", current_model,
                    _from_batch, model_changed, ctx_changed, branch_switched,
                    _conversation_id is None, _conversation_status)
        # Reuse the same conversation across tasks so DeepSeek's prompt
        # caching works (shared prefix = cached = ~90% cheaper). Only create
        # a new conversation when forced by error/timeout recovery (which
        # already sets _conversation_id = None) or context change (repo/mode/
        # model switch). Do NOT force a new conv on normal completion — that
        # would burn uncached tokens on every task.
        #
        # The stale-conv check in _process_batch_worker handles the case
        # where a NEW batch finds an idle conversation from a PREVIOUS
        # server session (which may be too large to reuse).
        if ctx_changed:
            logger.info("Context changed: repo='%s'→'%s' mode='%s'→'%s' model='%s'→'%s'",
                        _conversation_repo or '(none)', repo or '(none)',
                        _conversation_mode, mode,
                        _conversation_llm_model or '(none)', current_model or '(none)')
            _conversation_id = None
            _last_event_index = 0
            _sandbox_id = None
            _event_kinds.clear()
            _conversation_repo = repo
            _conversation_mode = mode
            _conversation_branch = effective_branch
            _persist_to_db()
        elif branch_switched:
            logger.info("Branch switch on same repo: '%s'→'%s' — reusing conversation, injecting checkout",
                        _conversation_branch or '(default)', effective_branch or '(default)')
            _conversation_branch = effective_branch
            _persist_to_db()
        need_new_conv = _conversation_id is None
        if not need_new_conv:
            current_conv_id = _conversation_id  # snapshot to use outside lock
        logger.debug("Phase 1a: need_new_conv=%s ctx_changed=%s branch_switched=%s branch_provided=%s",
                     need_new_conv, ctx_changed, branch_switched, branch_provided)

    # Phase 1b: HTTP calls OUTSIDE lock (create may poll start-tasks for up to 150s)
    try:
        if need_new_conv:
            logger.info("Phase 1b: creating new conversation for repo=%s branch=%s mode=%s model=%s",
                        repo, branch or '(empty)', mode, current_model)
            # AUDIT: log the exact llm_config being sent to the Cloud API
            _log_cfg = get_llm_config()
            if _log_cfg:
                logger.info("AUDIT model_cfg: configured_model=%s has_api_key=%s has_base_url=%s",
                            _log_cfg.model, bool(_log_cfg.api_key), bool(_log_cfg.base_url))
            new_conv_id = _create_conversation(prompt, repo, branch, mode)
            logger.info("Phase 1b: created conv=%s (repo=%s mode=%s model=%s seen_ids=%d)",
                        new_conv_id, repo, mode, current_model, len(_seen_event_ids))
        else:
            logger.info("Phase 1b: reusing conv=%s repo=%s mode=%s seen_ids=%d",
                        current_conv_id, repo, mode, len(_seen_event_ids))
            effective_prompt = prompt
            # Inject git checkout + pull for the effective branch.
            # When user provides a branch: always checkout that branch (sandbox
            # may be on a different branch from last operation), then pull.
            # When user provides no branch: just pull (keep whatever branch
            # the sandbox is on — typically the default).
            # IMPORTANT: sandbox repo may be at /workspace, /workspace/project/<name>,
            # or another subpath. Don't hardcode — find the .git directory first.
            if effective_branch:
                checkout_cmd = (
                    f"for d in /workspace /workspace/project/* /workspace/*; do "
                    f"[ -d \"$d/.git\" ] && cd \"$d\" && "
                    f"git fetch origin && git checkout {effective_branch} 2>&1 && "
                    f"git pull origin {effective_branch} 2>&1 && break; done "
                    f"|| echo 'git checkout/pull failed'"
                )
                git_prefix = f"{checkout_cmd}\n\n"
                logger.info("send: injected git checkout+pull for branch=%s (branch_provided=%s branch_switched=%s)",
                            effective_branch, branch_provided, branch_switched)
                effective_prompt = f"{git_prefix}{effective_prompt}"
            else:
                logger.info("send: no branch — sending prompt as-is, no git pull")
            success, send_err = _send_message(current_conv_id, effective_prompt)
            if not success:
                # If sandbox is paused/gone, auto-recover: reset + create new
                # conversation with same prompt. The caller never sees a 409.
                if send_err and "409" in str(send_err):
                    logger.warning("Sandbox paused/gone for conversation %s — recovering", current_conv_id)
                    recent_user_msgs: list = []
                    with _lock:
                        # Capture ONLY user messages from recent context so the new
                        # conversation knows what was discussed (not just UI history).
                        # EXCLUDE assistant responses — injecting them causes the AI
                        # to get confused between its own prior output and the new task,
                        # leading to repeated responses, code-file output, and skipped
                        # tool execution steps.
                        for m in _msgs()[-6:]:
                            role = m.get("role", "")
                            if role == "user" and m.get("content"):
                                recent_user_msgs.append(m["content"])
                        _conversation_id = None
                        _last_event_index = 0
                        _sandbox_id = None
                        _persist_to_db()
                    if recent_user_msgs:
                        # Use a clean factual summary so the AI never confuses
                        # injected history with its own pending response.
                        summarized = "; ".join(
                            m[:200].replace("\n", " ") for m in recent_user_msgs
                        )
                        enhanced = (
                            f"Previous user messages (from before server restart): {summarized}\n\n"
                            f"---\n\n"
                            f"{prompt}"
                        )
                        logger.info("AUDIT 409-recovery: %d user msgs injected, prompt=%s",
                                    len(recent_user_msgs), prompt[:80])
                    else:
                        enhanced = prompt
                    new_conv_id = _create_conversation(enhanced, repo, branch, mode)
                    logger.info("Recovered: created new conv=%s (%d user msgs injected)",
                                new_conv_id, len(recent_user_msgs))
                    need_new_conv = True  # Phase 1c will store it
                else:
                    logger.warning("send_message failed (non-409): send_err=%s — attempting recovery with new conversation. "
                                   "conv=%s status=%s seen_ids=%d",
                                   send_err, current_conv_id, _conversation_status, len(_seen_event_ids))
                    # Non-409 failures (timeout, model busy, sandbox gone) should
                    # NOT kill the user's request. Create a fresh conversation and
                    # retry. This handles cases where the old conversation is too
                    # large (401+ msgs), the sandbox is cold, or the Cloud API is
                    # slow to respond.
                    recent_user_msgs = []
                    with _lock:
                        for m in _msgs()[-6:]:
                            role = m.get("role", "")
                            if role == "user" and m.get("content"):
                                recent_user_msgs.append(m["content"])
                        _conversation_id = None
                        _last_event_index = 0
                        _sandbox_id = None
                        _persist_to_db()
                    if recent_user_msgs:
                        summarized = "; ".join(
                            m[:200].replace("\n", " ") for m in recent_user_msgs
                        )
                        enhanced = (
                            f"Previous user messages (from before timeout): {summarized}\n\n"
                            f"---\n\n"
                            f"{prompt}"
                        )
                        logger.info("AUDIT non-409-recovery: %d user msgs injected, prompt=%s",
                                    len(recent_user_msgs), prompt[:80])
                    else:
                        enhanced = prompt
                    new_conv_id = _create_conversation(enhanced, repo, branch, mode)
                    logger.info("Recovered from non-409: created new conv=%s", new_conv_id)
                    need_new_conv = True
    except httpx.HTTPStatusError as e:
        status_code = e.response.status_code
        logger.error("HTTP error: %s %s", status_code, e.response.text[:200])
        # Reset conversation on ANY error that makes the current conv unusable:
        # 404 (gone), 409 (paused), 410 (deleted), 429 (rate limited), 5xx (server error)
        if status_code in (404, 409, 410) or status_code >= 429:
            logger.warning("HTTP %s — resetting conversation_id to force fresh conv on next send", status_code)
            with _lock:
                _conversation_id = None
                _last_event_index = 0
                _sandbox_id = None
                _persist_to_db()
        else:
            logger.warning("HTTP %s — NOT resetting conversation. May cause issues on next send.", status_code)
        if not _from_batch:
            with _lock:
                if _processing_repo == repo:
                    _processing_repo = ""
        return {"error": f"Cloud API error: {status_code}"}
    except Exception as e:
        # Sanitize raw exceptions — never leak Python error messages to the client.
        # httpx timeout exceptions produce messages like "read operation timed out"
        # which look like network bugs but actually mean the AI model is still
        # generating. Map them to user-friendly, actionable messages.
        err_msg = str(e).lower()
        logger.error("Chat error (keeping conversation): %s", e, exc_info=True)
        if "timeout" in err_msg or "timed out" in err_msg:
            friendly = (
                "The AI model is taking longer than expected to respond. "
                "Please wait and try again."
            )
        elif "connection" in err_msg and ("refused" in err_msg or "reset" in err_msg or "abort" in err_msg):
            friendly = (
                "Connection to the AI service was lost. "
                "Please check your connection and try again."
            )
        else:
            friendly = "Something went wrong. Please try again."
        if not _from_batch:
            with _lock:
                if _processing_repo == repo:
                    _processing_repo = ""
        return {"error": friendly}

    # Phase 1c: Update state + save user message under lock
    with _lock:
        if need_new_conv:
            _conversation_id = new_conv_id
            _conversation_repo = repo
            # Use effective_branch (includes default "main" fallback) rather
            # than raw `branch` (which may be ""). This ensures the stored
            # branch matches what was actually sent to _create_conversation.
            _conversation_branch = effective_branch
            _conversation_mode = mode
            _conversation_llm_model = current_model
            _current_repo_key = _repo_key(repo)
            _last_event_index = 0
            _last_event_timestamp = ""  # reset min_timestamp for new conversation
            _seen_event_ids.clear()
            _seen_event_hashes.clear()
            logger.info("Phase 1c: stored new conv=%s repo=%s branch=%s mode=%s model=%s seen_ids=0",
                        new_conv_id, repo, _conversation_branch, mode, current_model)
            logger.info("AUDIT 1c_model: conv_model=%s configured_model=%s (match=%s)",
                        current_model, get_llm_config().model if get_llm_config() else "?",
                        current_model == (get_llm_config().model if get_llm_config() else None))
        msg_id = _next_msg_id()
        _msgs().append({"id": msg_id, 
            "role": "user",
            "content": prompt,
            "timestamp": int(time.time() * 1000),
        })
        _persist_to_db()
        # AUDIT: log Phase 1c state
        event_count = sum(1 for m in _msgs() if m.get("role") == "event")
        logger.info("AUDIT 1c: conv=%s need_new=%s msg_id=%d msgs=%d events=%d seen_ids=%d msg_counter=%d",
                    _conversation_id, need_new_conv, msg_id,
                    len(_msgs()), event_count, len(_seen_event_ids), _msg_counter)

    # Phase 2: Long wait — NO LOCK, get_state() can read events live
    # Track message count before wait so we can replace live [MSG] events
    # with the clean assistant response afterwards.
    with _lock:
        _msg_count_before = len(_msgs())
    logger.info("Phase 2: waiting for response (msg_count_before=%d)", _msg_count_before)
    response: str | None = None
    try:
        response = _wait_for_response()
        logger.info("Phase 2: done, response=%s", "non-empty (%d chars)" % len(response) if response else "None/empty")
    except Exception as e:
        logger.error("Phase 2 crashed: %s", e, exc_info=True)
        response = None
        if not _from_batch:
            with _lock:
                if _processing_repo == repo:
                    _processing_repo = ""

    # Phase 3: Save result under lock.
    # _wait_for_response collects only new MessageEvent texts via event ID
    # dedup. In rare cases the API may return cumulative content (old + new),
    # so handle prefix-stripping against the LAST assistant message.
    # Do NOT reject exact content matches — that would break legitimate
    # identical responses (e.g. user sends the same prompt twice in a batch
    # and the AI produces the same text both times). Those ARE real responses.
    #
    # AUDIT: Determine response source for diagnostics.
    # - events/search: response came from a new MessageEvent in the event poll
    # - zip: response came from trajectory zip fallback
    # - scrape: response came from _scrape_events_for_text (observation text)
    # - None: no response found
    _response_source = _last_response_source if _last_response_source else "unknown"
    with _lock:
        if response and response.strip():
            response = response.strip()
            msgs = _msgs()
            # Cumulative prefix: the API may return the NEW response prepended
            # with the previous assistant message. Strip the known prefix.
            # Only check the LAST assistant (cumulative builds on consecutive
            # turns, same conversation). Checking ALL previous messages would
            # false-positive when two different turns produce the same text.
            # CRITICAL: only strip if we are in the SAME conversation as when
            # the last assistant was stored. After conv_done creates a fresh
            # conversation, the response comes from a different Cloud
            # conversation and is NOT cumulative — stripping it would remove
            # legitimate content copied from the previous turn.
            for m in reversed(msgs):
                if m.get("role") == "assistant":
                    last_assistant = m.get("content", "")
                    if (last_assistant and response.startswith(last_assistant)
                            and _conversation_id == _conv_id_at_last_assistant):
                        stripped = response[len(last_assistant):].strip()
                        if stripped:
                            logger.info("Phase 3: stripped cumulative prefix (was %d, now %d chars) source=%s",
                                        len(response), len(stripped), _response_source)
                            response = stripped
                    break  # only check the most recent assistant
            # Filter out task_tracker tool output masquerading as assistant response.
            # The AI uses task_tracker.plan() internally, and the Cloud API sometimes
            # returns the tool's output text as a MessageEvent. Detect and discard.
            if response and response.strip():
                stripped = response.strip()
                # Task_tracker outputs are EXACT tool outputs (entire response),
                # never a substring of a legitimate AI answer. Use fullmatch to
                # avoid discarding responses that merely MENTION task updates.
                # Patterns: "Task list has been updated with N item(s)."
                #           "Tasks have been updated."  "task list updated"
                # Require either "list" after "task" OR plural "tasks"
                # plus optional aux verb and optional item count.
                if stripped and re.fullmatch(
                    r'(?i)(?:(?:task\s+list)|tasks)\s+(?:(?:has\s+been\s+|have\s+been\s+|was\s+|were\s+)|list\s+)?updated\s*(?:with\s+(?:\d+|N)\s+item(?:\(s\)|s)?)?\.?\s*',
                    stripped
                ):
                    logger.warning("Phase 3: discarding task_tracker output (%.80s...) source=%s",
                                   stripped[:80], _response_source)
                    response = ""
            if response:
                resp_msg_id = _next_msg_id()
                event_count_before = sum(1 for m in msgs if m.get("role") == "event")
                _msgs().append({"id": resp_msg_id, 
                    "role": "assistant",
                    "content": response,
                    "timestamp": int(time.time() * 1000),
                })
                _conv_id_at_last_assistant = _conversation_id
                _persist_to_db()
                # AUDIT: log Phase 3 state
                event_count_after = sum(1 for m in _msgs() if m.get("role") == "event")
                logger.info("AUDIT 3: conv=%s resp_id=%d msgs=%d events_before=%d events_after=%d "
                            "seen_ids=%d msg_counter=%d ts=%s",
                            _conversation_id, resp_msg_id, len(_msgs()),
                            event_count_before, event_count_after,
                            len(_seen_event_ids), _msg_counter,
                            _last_event_timestamp or "(none)")
            conv_id = _conversation_id

    if response:
        _auto_append_log(repo, prompt, response, ok=True)
        if not _from_batch:
            with _lock:
                if _processing_repo == repo:
                    _processing_repo = ""
        return {"response": response, "conversation_id": conv_id}
    else:
        _auto_append_log(repo, prompt, str(response), ok=False)
        logger.warning("send: returning error (no response)")
        if not _from_batch:
            with _lock:
                if _processing_repo == repo:
                    _processing_repo = ""
        return {
            "error": "Agent did not produce a response (timeout or conversation error)",
            "conversation_id": _conversation_id,
        }


# ---------------------------------------------------------------------------
# Batch queue — server-side, survives client disconnect
# ---------------------------------------------------------------------------


def enqueue_batch(prompts: list[str], repo: str = "", branch: str = "", mode: str = "code") -> dict:
    """Queue multiple prompts for sequential processing in the same conversation.

    Returns immediately. Processing happens in a background thread.
    Call get_state() to track progress.
    If a batch is already running, appends to it.
    """
    global _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _batch_repo, _batch_branch, _batch_mode, _batch_running, _batch_cancelled, _batch_skip_prompt, _batch_started_at

    cleaned = [p.strip() for p in prompts if p.strip()]
    if not cleaned:
        return {"error": "No valid prompts"}

    # Validate repo exists before enqueuing (instant error, not after delay)
    exists = _repo_exists(repo)
    if exists is False:
        logger.error("enqueue_batch: repo '%s' not found on GitHub", repo)
        return {"error": f"Repository '{repo}' not found on GitHub. Check the name and try again."}
    if exists is None:
        logger.warning("enqueue_batch: cannot verify repo '%s' — GitHub API error, proceeding", repo)

    with _lock:
        if _batch_running:
            # Stale batch detection: if the batch worker started but hasn't
            # made progress for > 30 min, auto-clear it. This handles the
            # case where the worker crashed silently or the backend was
            # restarted while a batch was "running".
            _stale_since = ""
            if _batch_started_at > 0:
                _elapsed = time.time() - _batch_started_at
                if _elapsed > 1800:
                    _stale_since = f" (stale — started {int(_elapsed)}s ago)"
                    logger.warning("enqueue_batch: auto-clearing stale batch (started %ds ago)", int(_elapsed))
                    _batch_running = False
                    _batch_repo = ""
                    _batch_total = 0
                    _batch_position = 0
                    _batch_prompts = []
                    _batch_prompt_modes = []
                    _persist_to_db()
                else:
                    _stale_since = f" (running for {int(_elapsed)}s)"
            elif _batch_started_at == 0:
                _stale_since = " (worker never started — zombie batch)"
                logger.warning("enqueue_batch: auto-clearing zombie batch (_batch_started_at=0)")
                _batch_running = False
                _batch_repo = ""
                _batch_total = 0
                _batch_position = 0
                _batch_prompts = []
                _batch_prompt_modes = []
                _persist_to_db()

        if _batch_running:
            # Reject append if repo changed — prevents cross-repo contamination
            if repo != _batch_repo:
                return {
                    "error": (
                        f"Batch already running with repo={_batch_repo or '(none)'}"
                        f"{_stale_since}. "
                        "Wait for it to finish or tap 'New conversation' to start fresh."
                    )
                }
            # Append to running batch (cross-mode allowed: plan+code share same chat)
            _batch_prompts.extend(cleaned)
            _batch_prompt_modes.extend([mode] * len(cleaned))
            _batch_total = len(_batch_prompts)
            _batch_mode = mode  # update default mode
            logger.info("Batch appended: +%d prompts (now %d total, mode=%s)", len(cleaned), _batch_total, mode)
            return {"status": "appended", "added": len(cleaned), "total": _batch_total}

        _batch_cancelled = False  # reset from any previous cancellation
        _batch_skip_prompt = False
        _batch_prompts = cleaned
        _batch_prompt_modes = [mode] * len(cleaned)
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
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes
    global _batch_position, _batch_total, _batch_repo, _batch_branch, _batch_mode, _batch_skip_prompt
    global _conversation_id, _conversation_status, _last_event_index, _last_event_timestamp, _sandbox_id
    global _last_completed_no_msg, _batch_started_at
    global _seen_event_ids, _seen_event_hashes, _event_kinds
    _batch_started_at = time.time()

    try:
        while True:
            with _lock:
                # Per-prompt cancel: skip current, move to next
                skip_prompt = _batch_skip_prompt
                if skip_prompt:
                    _batch_skip_prompt = False
                    _batch_cancelled = False
                    # Current prompt was removed from queue; next prompt is at same position
                    if _batch_position >= _batch_total:
                        _batch_running = False
                        _batch_prompts = []
                        _batch_prompt_modes = []
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
                    _batch_position = 0
                    _batch_total = 0
                    _persist_to_db()
                    logger.info("Batch complete")
                    return
                # 30-minute global batch timeout
                if time.time() - _batch_started_at > 1800:
                    _msgs().append({"id": _next_msg_id(), 
                        "role": "error",
                        "content": "Batch timed out after 30 minutes. Remaining prompts skipped.",
                        "timestamp": int(time.time() * 1000),
                    })
                    _batch_running = False
                    _batch_prompts = []
                    _batch_prompt_modes = []
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
                mode = _batch_prompt_modes[_batch_position] if _batch_position < len(_batch_prompt_modes) else _batch_mode

            # Send the prompt (this blocks — uses the same send() function)
            logger.info("Batch [%d/%d]: %.80s... repo=%s branch=%s mode=%s",
                        pos, total, prompt, repo, branch or '(default)', mode)

            # CRITICAL: if this is the FIRST prompt in the batch and the old
            # conversation is idle (completed by a PREVIOUS batch), force a
            # fresh conversation. Without this guard, _from_batch=True prevents
            # conv_done from triggering (line 786), so a stale conversation
            # with 401+ messages gets reused and _send_message() times out.
            if pos == 1:
                with _lock:
                    if _conversation_id is not None and _conversation_status == "idle":
                        logger.info("Batch [%d/%d]: clearing stale conv=%s (idle from previous batch) "
                                    "to force fresh conversation", pos, total, _conversation_id)
                        _conversation_id = None
                        _last_event_index = 0
                        _last_event_timestamp = ""
                        _sandbox_id = None
                        _seen_event_ids.clear()
                        _seen_event_hashes.clear()
                        _event_kinds.clear()
                        _persist_to_db()

            try:
                result = send(prompt, repo=repo, branch=branch, mode=mode, _from_batch=True)
                logger.info("Batch [%d/%d]: send() returned status=%s has_error=%s msgs=%d",
                            pos, total,
                            result.get("status") if result else "None",
                            bool(result and "error" in result),
                            len(_msgs()))
            except Exception as e:
                logger.error("Batch send crashed [%d/%d]: %s", pos, total, e)
                err = str(e).lower()
                if "timeout" in err or "timed out" in err:
                    result = {"error": "The AI model is taking longer than expected. Try again."}
                elif "connection" in err and ("refused" in err or "reset" in err or "abort" in err):
                    result = {"error": "Connection to the AI service was lost."}
                else:
                    result = {"error": "Something went wrong. Try again."}

            if result and "error" in result:
                # Check if this was a deliberate cancellation — show STOPPED, not ERROR
                with _lock:
                    was_cancelled = _batch_cancelled
                    was_skipped = _batch_skip_prompt
                logger.warning("BATCH_RESULT [%d/%d]: error=%s cancelled=%s skipped=%s conv=%s",
                               pos, total, result.get("error", "?"), was_cancelled, was_skipped, _conversation_id)

                # COMPLETED_NO_MSG recovery: if the conversation completed but
                # produced no agent response, reset it so the NEXT prompt in
                # the batch creates a fresh conversation. Without this guard,
                # every subsequent prompt reuses the same broken conv → 409 →
                # resume → retry → same COMPLETED_NO_MSG → infinite loop =
                # "cascade swallowing". The first retry is allowed to reuse
                # the conv (cache preserved). Consecutive failures trigger reset.
                if _last_completed_no_msg and _conversation_id is not None:
                    logger.warning("BATCH COMPLETED_NO_MSG [%d/%d]: resetting stale conv=%s "
                                   "to prevent cascade swallowing of remaining prompts",
                                   pos, total, _conversation_id)
                    with _lock:
                        _conversation_id = None
                        _conv_id_at_last_assistant = None
                        _last_event_index = 0
                        _last_event_timestamp = ""
                        _sandbox_id = None
                        _seen_event_ids.clear()
                        _seen_event_hashes.clear()
                        _event_kinds.clear()
                        _persist_to_db()

                if was_cancelled:
                    with _lock:
                        _msgs().append({"id": _next_msg_id(), 
                            "role": "event",
                            "content": f"[STOPPED] [{pos}/{total}] Cancelled",
                            "kind": "SystemEvent",
                            "timestamp": int(time.time() * 1000),
                        })
                elif was_skipped:
                    pass  # per-prompt cancel, silently skip
                else:
                    with _lock:
                        _msgs().append({"id": _next_msg_id(), 
                            "role": "error",
                            "content": f"[ERROR] [{pos}/{total}] Failed: {result['error']}",
                            "timestamp": int(time.time() * 1000),
                        })

            with _lock:
                skip_prompt = _batch_skip_prompt
                if not skip_prompt:
                    _batch_position += 1
                else:
                    _batch_skip_prompt = False  # reset after consumption
                _persist_to_db()

            time.sleep(1)  # brief pause between prompts
    except BaseException as e:
        logger.error("Batch worker FATAL crash: %s", e, exc_info=True)
        err = str(e).lower()
        if "timeout" in err or "timed out" in err:
            msg = "Worker timed out. Try again."
        elif "connection" in err and ("refused" in err or "reset" in err or "abort" in err):
            msg = "Worker lost connection to the AI service."
        else:
            msg = f"Worker crashed. Try again."
        with _lock:
            _msgs().append({"id": _next_msg_id(), 
                "role": "error",
                "content": msg,
                "timestamp": int(time.time() * 1000),
            })
    finally:
        with _lock:
            _batch_running = False
            _batch_position = 0
            _batch_total = 0
        _persist_to_db()


def cancel_batch() -> dict:
    """Cancel the running batch queue OR any in-progress send. Non-blocking.
    
    Sets _batch_cancelled flag unconditionally — _wait_for_response() checks
    this flag on every poll, regardless of batch or direct send.
    
    Edge cases handled:
    - Worker blocked in send() → _batch_cancelled detected on next poll cycle
    - Direct send (no batch) → _batch_cancelled flag still checked by _wait_for_response
    - Worker idle / no send in progress → flag set but no-op (reset by next send)
    - Already cancelled → no-op
    - No batch running but direct send running → cancel flag set, send detects it
    """
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _conversation_status
    with _lock:
        if _batch_cancelled:
            logger.info("cancel_batch: already cancelled — no-op")
            return {"status": "already_cancelled"}
        _batch_cancelled = True  # checked by _wait_for_response (both batch and direct)
        _conversation_status = "idle"
        was_running = _batch_running
        if was_running:
            _batch_running = False
            remaining = _batch_total - _batch_position
            _batch_prompts = []
            _batch_prompt_modes = []
            # Don't reset position/total here — let worker detect cancel and
            # append a [STOPPED] message. Worker's finally block resets fully.
            logger.info("cancel_batch: cancelled batch (%d remaining, worker will finalize)", remaining)
        else:
            remaining = 0
            logger.info("cancel_batch: no batch running, set cancel flag for in-progress send")
    return {"status": "cancelled", "remaining": remaining}


def cancel_batch_prompt(index: int) -> dict:
    """Cancel a single prompt in the batch queue by index.
    
    Edge cases handled:
    - Prompt currently running (index == position) → sets skip flag,
      does NOT set _batch_cancelled (which would cancel the entire batch)
    - Prompt queued ahead (index > position) → removed from list
    - Already cancelled prompt → error
    - Empty batch / no batch running → error
    """
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _batch_skip_prompt

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
        _batch_total -= 1

        if index == _batch_position:
            # Cancelling the currently-running prompt
            # Use _batch_skip_prompt ONLY (NOT _batch_cancelled), so
            # the worker loop continues processing remaining prompts
            _batch_skip_prompt = True
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
                timeout=120,
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
        except httpx.TimeoutException:
            return False, (
                "The AI model is taking longer than expected to respond. "
                "Try again in a moment."
            )

        data = resp.json()

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
        # Don't leak raw exception text to the caller
        return "failed to resume sandbox"


# Cache for GitHub default branch detection (repo → branch, 1h TTL)
_default_branch_cache: dict[str, tuple[str, float]] = {}


def _detect_default_branch(repo: str) -> str | None:
    """Query GitHub API for the repo's default branch. Cached for 1 hour."""
    now = time.time()
    entry = _default_branch_cache.get(repo)
    if entry:
        cached_branch, cached_at = entry
        if now - cached_at < 3600:
            return cached_branch
        del _default_branch_cache[repo]

    try:
        resp = httpx.get(
            f"https://api.github.com/repos/{repo}",
            headers={"Accept": "application/vnd.github+json"},
            timeout=5,
        )
        if resp.status_code == 200:
            data = resp.json()
            branch = data.get("default_branch")
            if branch:
                _default_branch_cache[repo] = (branch, now)
                logger.info("Detected default branch for %s: %s", repo, branch)
                return branch
        logger.debug("Failed to detect default branch for %s: HTTP %s", repo, resp.status_code)
    except Exception as e:
        logger.debug("Failed to detect default branch for %s: %s", repo, e)
    return None


def get_branches(repo: str) -> list[str]:
    """Fetch branch list for a repo from GitHub API. Cached 5 min.

    Returns:
        list[str]: Branch names on success.
        []: If API fails or returns error. Callers should check _repo_exists() first.
    """
    if not repo:
        return []
    now = time.time()
    cache_key = f"branches:{repo}"
    entry = _branch_cache.get(cache_key)
    if entry:
        branches, cached_at = entry
        if now - cached_at < 300:
            return list(branches)
        del _branch_cache[cache_key]
    try:
        resp = httpx.get(
            f"https://api.github.com/repos/{repo}/branches?per_page=50",
            headers=_gh_headers(),
            timeout=10,
        )
        if resp.status_code == 200:
            branches = [b["name"] for b in resp.json()]
            _branch_cache[cache_key] = (branches, now)
            logger.info("Fetched %d branches for %s", len(branches), repo)
            return branches
        logger.warning("Failed to fetch branches for %s: HTTP %s", repo, resp.status_code)
    except Exception as e:
        logger.warning("Failed to fetch branches for %s: %s", repo, e)
    return []


def _repo_exists(repo: str) -> bool | None:
    """Check if a GitHub repo exists. Returns True/False, or None on network error."""
    if not repo:
        return False
    try:
        resp = httpx.get(
            f"https://api.github.com/repos/{repo}",
            headers=_gh_headers(),
            timeout=5,
        )
        if resp.status_code == 200:
            return True
        if resp.status_code == 404:
            return False
        # 403 rate limited, 301 moved, etc. — ambiguous
        logger.warning("repo_exists(%s): ambiguous HTTP %s", repo, resp.status_code)
        return None
    except Exception as e:
        logger.warning("repo_exists(%s): network error %s", repo, e)
        return None


_branch_cache: dict[str, tuple[list[str], float]] = {}


# Cache for task log from VIBECODER_LOG.md (repo → (entries, cached_at), 5-min TTL)


def get_task_log(repo: str) -> list[dict]:
    """Fetch task log entries for a repo (latest first, 72h window).

    Primary: in-memory cache (instant, updated by _auto_append_log).
    Fallback: GitHub API (populates cache on first call for a repo).
    """
    now = time.time()

    # Check in-memory cache
    recent_ts = _log_entries_ts.get(repo, 0)
    if repo in _log_entries and now - recent_ts < 300:
        return _filter_72h(_log_entries[repo])

    # Fallback: fetch from GitHub and populate cache
    try:
        resp = httpx.get(
            f"https://api.github.com/repos/{repo}/contents/VIBECODER_LOG.md",
            headers=_gh_headers({"Accept": "application/vnd.github.raw+json"}),
            timeout=10,
        )
        if resp.status_code == 200:
            content = resp.text
            gh_entries = _parse_log_md(content)
            # Merge: in-memory entries (newest, via _auto_append_log) come first,
            # then unique GitHub entries (that aren't already in memory).
            # Otherwise _log_entries[repo] = gh_entries would overwrite and lose
            # recent entries that haven't been synced to GitHub yet.
            existing = _log_entries.get(repo, [])
            existing_keys = {(e.get("timestamp", ""), e.get("summary", "")) for e in existing}
            merged = list(existing)
            for e in gh_entries:
                key = (e.get("timestamp", ""), e.get("summary", ""))
                if key not in existing_keys:
                    merged.append(e)
                    existing_keys.add(key)
            _log_entries[repo] = merged
            _log_entries_ts[repo] = now
            logger.info("VIBECODER_LOG.md loaded from GitHub: %s (%d gh + %d mem = %d merged)",
                       repo, len(gh_entries), len(existing), len(merged))
            return _filter_72h(merged)
        elif resp.status_code == 404:
            # No log file yet — empty cache
            if repo not in _log_entries:
                _log_entries[repo] = []
            _log_entries_ts[repo] = now
            return []
        else:
            logger.warning("VIBECODER_LOG.md fetch failed for %s: HTTP %s", repo, resp.status_code)
    except Exception as e:
        logger.warning("VIBECODER_LOG.md fetch error for %s: %s", repo, e)

    # Return from cache even if stale
    return _filter_72h(_log_entries.get(repo, []))


def _filter_72h(entries: list[dict]) -> list[dict]:
    """Filter entries to last 72 hours, already expected to be latest-first."""
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=72)
    return [e for e in entries
            if _parse_entry_ts(e.get("timestamp", "")) >= cutoff]


def _parse_entry_ts(ts: str) -> datetime:
    """Parse a timestamp from VIBECODER_LOG.md format."""
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(ts[:16], fmt).replace(tzinfo=timezone.utc)
        except (ValueError, IndexError):
            continue
    return datetime.min.replace(tzinfo=timezone.utc)


def _parse_log_md(content: str) -> list[dict]:
    """Parse VIBECODER_LOG.md into task entry dicts.

    Robust: accepts any well-formed entry with `## timestamp — summary`.
    Fields are optional — missing fields get empty defaults.
    Unknown fields are preserved as-is.
    """
    import re
    entries = []
    # Match: ## 2026-06-22T10:27 — One-line summary
    header_pat = re.compile(r'^##\s+(\S+)\s+—\s+(.+)$', re.MULTILINE)
    # Match any **Key:** Value line (key is anything between ** and **)
    field_pat = re.compile(r'^\*\*([^*]+)\*\*:\s*(.+)$', re.MULTILINE)

    # Split by ## headers
    sections = re.split(r'\n(?=## )', content)
    for section in sections:
        section = section.strip()
        if not section or not section.startswith("## "):
            continue
        header = header_pat.search(section)
        if not header:
            # Try relaxed: just "## timestamp" without em-dash
            simple = re.match(r'^##\s+(\S+)', section)
            if simple:
                entry = {
                    "timestamp": simple.group(1),
                    "summary": section.split("\n", 1)[0][len(simple.group(0)):].strip().lstrip("—- "),
                    "request": "",
                    "status": "",
                    "details": "",
                    "files": "",
                }
            else:
                continue
        else:
            entry = {
                "timestamp": header.group(1),
                "summary": header.group(2),
                "request": "",
                "status": "",
                "details": "",
                "files": "",
            }

        for m in field_pat.finditer(section):
            key = m.group(1).strip().lower()
            val = m.group(2).strip()
            if "request" in key:
                entry["request"] = val
            elif "status" in key:
                entry["status"] = val
            elif "what was done" in key or "details" in key:
                entry["details"] = val
            elif "files" in key:
                entry["files"] = val
            # Unknown fields are silently preserved (not used by UI but not lost)

        entries.append(entry)

    # File is written oldest-first; reverse to latest-first (consistent with in-memory cache)
    entries.reverse()
    return entries



def _create_conversation(prompt: str, repo: str, branch: str, mode: str) -> str:
    """Create a conversation via POST /api/v1/app-conversations (SAME as agent_runner).

    Returns the conversation_id. Raises on failure.
    """
    # Auto-detect default branch if repo given and branch is empty
    effective_branch = branch
    if repo and not branch:
        detected = _detect_default_branch(repo)
        if detected:
            effective_branch = detected

    # Mode-specific prompt prefix
    if mode == "plan":
        if repo:
            full_prompt = (
                f"Repository: {repo} (branch: {effective_branch}).\n"
                f"IMPORTANT — PLAN MODE:\n"
                f"1. FIRST, analyze the task and research the codebase. Read files, search, "
                f"understand the architecture. Create a detailed implementation plan saved "
                f"to .agents_tmp/PLAN.md. Do NOT implement anything yet.\n"
                f"2. After creating the plan, present your findings and ask "
                f"whether to proceed with implementation.\n"
                f"3. You are in READ-ONLY mode. Do NOT edit, create, or delete any files "
                f"other than .agents_tmp/PLAN.md. Do NOT run git commit or git push.\n"
                f"IMPORTANT: Stop after EXPLORATION + ANALYSIS.\n\n"
                f"[SANDBOX] REPO RESTRICTION: You are confined to repository `{repo}`. "
                f"Switch branches freely, but NEVER touch any other repo.\n\n"
                f"Task: {prompt}"
            )
        else:
            full_prompt = (
                "IMPORTANT — PLAN MODE:\n"
                "1. FIRST, analyze the request. Research, think through the problem, "
                "and create a detailed plan saved to .agents_tmp/PLAN.md. "
                "Do NOT implement anything.\n"
                "2. After creating the plan, present it to the user and ask "
                "whether to proceed.\n"
                "3. READ-ONLY: Do NOT edit, create, or delete any files "
                "other than .agents_tmp/PLAN.md.\n\n"
                f"Task: {prompt}"
            )
    elif repo:
        full_prompt = (
            f"Repository: {repo} (branch: {effective_branch}).\n"
            f"IMPORTANT: First run `git pull` to get the latest code. "
            f"The repo's .git directory is NOT at /workspace directly — it's in "
            f"a subdirectory like /workspace/project/<name>/. "
            f"Run `cd /workspace && ls` to find it, then cd into the right dir "
            f"and run `git pull origin {effective_branch}`.\n"
            f"Read the user's message below and implement what it asks. "
            f"Make edits, commit with a descriptive message, and push.\n\n"
            f"[SANDBOX] REPO RESTRICTION: You are confined to repository `{repo}`. "
            f"You may switch branches within it freely, but you MUST NOT "
            f"clone, fetch, push to, or interact with any other repository. "
            f"All file edits, git operations, and commits must stay within "
            f"`{repo}`.\n\n"
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
        body["selected_branch"] = effective_branch

    # Apply custom LLM config if set (same as agent_runner)
    try:
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


def _extract_message_text(evt: dict) -> str | None:
    """Extract assistant response text from a MessageEvent.

    Returns the text string, or None if no text could be extracted
    (event has no llm_message, wrong format, empty content, etc.).
    """
    if evt.get("source") == "user":
        return None
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
    elif isinstance(llm_msg, list):
        parts = []
        for block in llm_msg:
            if isinstance(block, dict):
                t = block.get("text", "") or block.get("content", "")
                if t and str(t).strip():
                    parts.append(str(t).strip())
            elif isinstance(block, str) and block.strip():
                parts.append(block.strip())
        if parts:
            text = '\n'.join(parts)
        else:
            text = str(llm_msg)[:200]
    return text if text.strip() else None


# Module-level flag: set by _wait_for_response when conversation completed
# normally (status="completed"/"finished") but NO MessageEvent text was found
# after ALL fallbacks (desperation poll, zip retry). send() uses this to
# decide whether to reset the stale conversation for the next request.
_last_completed_no_msg: bool = False


def _wait_for_response(timeout: int | None = None) -> str | None:
    """Poll conversation status + events until the agent finishes (SAME logic as agent_runner).

    Timeout: VIBECODE_CHAT_TIMEOUT env var (default 7200s = 2 hours).
    """
    global _last_event_index, _last_event_timestamp, _conversation_status, _sandbox_id, _last_response_source
    global _conversation_id, _seen_event_ids, _seen_event_hashes, _event_kinds
    global _last_completed_no_msg

    if timeout is None:
        timeout = _CHAT_TIMEOUT

    start = time.time()
    _wait_started_at_ts = str(int(time.time() * 1000))  # unix ms for event filtering
    all_new_msgs: list[str] = []
    last_status = ""
    last_event_count = 0
    _last_completed_no_msg = False

    # AUDIT: log entry state
    logger.info("AUDIT wait_entry: conv=%s ts=%s seen_ids=%d seen_hashes=%d last_idx=%d timeout=%d msgs_before=%d",
                _conversation_id, _last_event_timestamp or "(none)",
                len(_seen_event_ids), len(_seen_event_hashes), _last_event_index,
                timeout, len(_msgs()))

    poll_count = 0
    _completed_normally = False  # True only if loop exits via "completed"/"finished"
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
                _msgs().append({"id": _next_msg_id(), 
                    "role": "event",
                    "content": label,
                    "kind": "SystemEvent",
                    "timestamp": int(time.time() * 1000),
                })

        # -- Get events (SAME endpoint as agent_runner) --
        # Use min_timestamp to get only new events after the last seen one.
        # IMPORTANT: Cloud API's events/search does NOT support `offset`
        # (returns 422). Max limit=100 (confirmed by OpenHands API docs).
        # 100 events per poll is sufficient for real-time streaming.
        all_events: list = []
        try:
            params: dict = {"limit": 100}
            if _last_event_timestamp:
                params["min_timestamp"] = _last_event_timestamp
            r2 = httpx.get(
                f"{CLOUD_API_URL}/api/v1/conversation/{_conversation_id}/events/search",
                headers=_headers(),
                params=params,
                timeout=10,
            )
            r2.raise_for_status()
            events_data = r2.json()

            # Robust extraction: try "items", "events", "data", "results", or bare list
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
            if _last_event_timestamp and all_events:
                logger.info("Events poll min_ts=%s: got %d events",
                            _last_event_timestamp[:19], len(all_events))
        except Exception as e:
            logger.warning("Events poll error: %s", e)
            if not all_events:
                continue

        # _last_event_index might be stale (from a previous send() call), so
        # use the raw diff for logging only. Negative means events were trimmed
        # or min_timestamp advanced beyond the previous index.
        if len(all_events) != last_event_count:
            last_event_count = len(all_events)
            logger.info("Conversation %s: %d events this poll (index=%d seen_ids=%d)",
                        _conversation_id, len(all_events), _last_event_index,
                        len(_seen_event_ids))
            if all_events:
                first = all_events[0]
                logger.info("First event: kind=%s source=%s tool=%s keys=%s",
                            first.get("kind"), first.get("source"),
                            first.get("tool_name"),
                            sorted(first.keys())[:8])
        elif len(all_events) == 0:
            # No events at all — log every 30s so we know polling works
            if int(time.time() - start) % 30 < 3:
                logger.info("Conversation %s: 0 events so far (elapsed %ds)",
                            _conversation_id, int(time.time() - start))

        # Stream ALL events, using _seen_event_ids for dedup (NOT index-based
        # slicing — _last_event_index and min_timestamp track different things
        # and get out of sync when _last_event_index is not reset each call).
        processed_count = 0
        with_id = 0
        no_id = 0
        skipped = 0
        added = 0
        for evt in all_events:
            evt_id = evt.get("id", "")
            kind = evt.get("kind", "")
            source = evt.get("source", "")
            tool = evt.get("tool_name", "")

            # --- DEDUP WITH DEFERRED REGISTRATION FOR MessageEvents ---
            # For non-MessageEvents: register dedup immediately (correct).
            # For MessageEvents: register dedup ONLY AFTER successful text
            # extraction below. This prevents "dedup poisoning" where a
            # MessageEvent with empty/unparseable text is permanently skipped
            # on subsequent polls (the _seen_event_ids set grows unboundedly
            # and the event can never be re-parsed).
            dedup_by_id = bool(evt_id) and evt_id in _seen_event_ids
            if not evt_id:
                no_id += 1
                content_str = f"{kind}:{source}:{tool}:{json.dumps(evt.get('llm_message', evt.get('message', '')), sort_keys=True, default=str)}"
                content_hash = hash(content_str)
                dedup_by_content = content_hash in _seen_event_hashes
            else:
                with_id += 1
                content_hash = 0
                dedup_by_content = False
            if dedup_by_id or dedup_by_content:
                processed_count += 1
                skipped += 1
                continue
            added += 1
            # Defer dedup registration for MessageEvents (registered after
            # text extraction succeeds). For all other events, register now.
            _is_msg_evt = (kind == "MessageEvent" and source != "user")
            if not _is_msg_evt:
                if evt_id:
                    _seen_event_ids.add(evt_id)
                else:
                    _seen_event_hashes.add(content_hash)
            if skipped == 0 and added < 5:
                # First new events — log a few to aid debugging
                logger.info("_wait_for_response: FIRST_NEW_EVENTS id=%s kind=%s source=%s tool=%s",
                            evt_id[:20] if evt_id else "(no_id)", kind, source, tool)

            # Track event kinds for diagnostics
            _event_kinds.add(kind)

            if kind == "MessageEvent":
                # Skip user messages (initial prompt echo) — only show agent text
                if source == "user":
                    # If we deferred dedup for a user msg, register it now
                    if _is_msg_evt and evt_id:
                        _seen_event_ids.add(evt_id)
                    elif _is_msg_evt and not evt_id:
                        _seen_event_hashes.add(content_hash)
                    continue
                # Use shared helper for text extraction
                text = _extract_message_text(evt)
                if text:
                    # ONLY keep the LAST assistant message (replace, not append).
                    # Multiple MessageEvents per turn (intermediate + final) must
                    # not all be joined — the final one IS the response.
                    all_new_msgs = [text]
                    # Register dedup NOW that text extraction succeeded.
                    # This prevents re-parsing the same event on future polls
                    # while also NOT poisoning the dedup set with events whose
                    # text could not be extracted (they get retried next poll).
                    if evt_id:
                        _seen_event_ids.add(evt_id)
                    else:
                        _seen_event_hashes.add(content_hash)
                else:
                    logger.warning("MessageEvent found but NO text extracted: source=%s evt_id=%s",
                                   source, evt_id[:20] if evt_id else "(no_id)")
                    # DO NOT register dedup — the event may be parseable on
                    # the next poll (e.g. llm_message was not yet populated
                    # when we first polled). This is the "dedup poisoning" fix.

            # Stream tool calls, observations, errors as live events
            event_preview = _format_event_preview(evt)
            if event_preview:
                with _lock:
                    _msgs().append({"id": _next_msg_id(), 
                        "role": "event",
                        "content": event_preview,
                        "kind": kind,
                        "tool_name": tool,
                        "timestamp": int(time.time() * 1000),
                    })

        # Advance the min_timestamp to the last event's timestamp for API-level
        # filtering on the next poll. _last_event_index is tracked for logging
        # only (dedup uses _seen_event_ids, not index-based slicing).
        _last_event_index = len(all_events)
        if all_events:
            last_ts = all_events[-1].get("timestamp", "")
            if last_ts:
                _last_event_timestamp = str(last_ts)  # normalize to str for API param
            logger.debug("Events processed: %d new, %d total in this batch, %d seen_ids",
                         processed_count, _last_event_index, len(_seen_event_ids))

        # AUDIT: log per-poll stats for event streaming diagnostics
        poll_count += 1
        tool_count = sum(1 for m in _msgs() if m.get("role") == "event" and m.get("kind") not in ("SystemEvent",))
        status_count = sum(1 for m in _msgs() if m.get("role") == "event" and m.get("kind") == "SystemEvent")
        logger.info("AUDIT wait_poll_%d: conv=%s status=%s elapsed=%ds "
                    "events_this_poll=%d tool_evts=%d status_evts=%d "
                    "all_new_msgs=%d total_msgs=%d seen=%d ts=%s",
                    poll_count, _conversation_id, status, int(time.time()-start),
                    len(all_events) if all_events else 0,
                    tool_count, status_count,
                    len(all_new_msgs), len(_msgs()),
                    len(_seen_event_ids),
                    _last_event_timestamp or "(none)")

        if status in ("completed", "finished"):
            _conversation_status = "idle"
            _completed_normally = True
            logger.info("Conversation %s: finished. Kinds=%s new_msgs=%d total_msgs=%d "
                        "with_id=%d no_id=%d skipped=%d added=%d seen_ids=%d seen_hashes=%d",
                        _conversation_id,
                        sorted(_event_kinds),
                        len(all_new_msgs),
                        len(_msgs()),
                        with_id, no_id, skipped, added,
                        len(_seen_event_ids), len(_seen_event_hashes))
            # CRITICAL: even if no MessageEvent found (race condition where
            # final message isn't indexed yet), do NOT reset _conversation_id.
            # The zip fallback below tries recovery. If zip also fails, the
            # next send() reuses the same conversation — _send_message() gets
            # 409 (sandbox paused), _resume_sandbox() wakes it, retry succeeds.
            # This preserves DeepSeek caching (same conv = cached prefix).
            # Only create a new conv if the 409 recovery itself fails.
            if not all_new_msgs:
                logger.warning("COMPLETED_NO_MSG: conv=%s status=%s new_msgs=0 seen_ids=%d — "
                               "keeping conv for zip fallback + next send",
                               _conversation_id, status, len(_seen_event_ids))
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
                _msgs().append({"id": _next_msg_id(), 
                    "role": "event",
                    "content": "\n".join(parts),
                    "kind": "ErrorEvent",
                    "timestamp": int(time.time() * 1000),
                })
            # Return any accumulated messages instead of None — the AI may
            # have generated a partial response before the error. Discarding
            # it makes the user see only tool events + error (no AI output).
            # A non-empty response keeps Phase 3 happy and the user informed.
            if all_new_msgs:
                logger.info("Error with %d accumulated msgs — returning them", len(all_new_msgs))
                return "\n\n".join(all_new_msgs) if len(all_new_msgs) > 1 else all_new_msgs[-1]
            # No messages — return error detail as response so user knows why
            return f"Task {status}: {err_detail}"

    # When finished, try trajectory zip to get the COMPLETE last response.
    # events/search may return truncated event lists. Only use zip as a
    # FALLBACK — if events/search already found assistant messages, trust
    # that data (zip extraction can override multiple msgs with one).
    #
    # CRITICAL: zip may contain events from PREVIOUS turns (not yet updated).
    # Skip any MessageEvent whose text matches last_assistant — that would
    # be a stale copy from a previous turn, causing Phase 3 to reject the
    # response as "cached" (byte-identical to last_assistant). Also skip
    # events with IDs already in _seen_event_ids.

    # --- DESPERATION POLL: retry events/search WITHOUT min_timestamp ---
    # The main poll loop uses min_timestamp to avoid re-processing old events.
    # Bug scenario: events/search?limit=100 returns events AFTER min_timestamp,
    # but the MessageEvent has a timestamp JUST BEFORE the cutoff (race between
    # event indexing and the final status poll). The min_timestamp filter then
    # EXCLUDES the MessageEvent and we get COMPLETED_NO_MSG.
    #
    # Fix: do ONE final events/search call with NO timestamp filter.
    # Scan ALL returned events for any agent MessageEvent that isn't already
    # in _seen_event_ids. This catches MessageEvents that were excluded by
    # the min_timestamp race.
    if last_status in ("completed", "finished") and not all_new_msgs:
        try:
            logger.info("DESPERATION_POLL: conv=%s ts=%s seen_ids=%d — retrying events/search WITHOUT min_timestamp",
                        _conversation_id, _last_event_timestamp or "(none)", len(_seen_event_ids))
            r_final = httpx.get(
                f"{CLOUD_API_URL}/api/v1/conversation/{_conversation_id}/events/search",
                headers=_headers(),
                params={"limit": 100},
                timeout=10,
            )
            r_final.raise_for_status()
            fd = r_final.json()
            final_events = (
                fd if isinstance(fd, list)
                else fd.get("items") or fd.get("events") or fd.get("data") or fd.get("results") or []
            )
            for evt in reversed(final_events):
                if evt.get("kind") != "MessageEvent" or evt.get("source") == "user":
                    continue
                eid = evt.get("id", "")
                if eid and eid in _seen_event_ids:
                    continue
                msg_text = _extract_message_text(evt)
                if msg_text:
                    logger.info("DESPERATION_POLL: FOUND assistant MessageEvent! len=%d ts=%s",
                                len(msg_text), evt.get("timestamp", 0))
                    all_new_msgs = [msg_text]
                    _last_response_source = "events/search"
                    # Register dedup now that extraction succeeded
                    if eid:
                        _seen_event_ids.add(eid)
                    break
            if not all_new_msgs:
                logger.info("DESPERATION_POLL: no MessageEvent found in %d events (seen_ids=%d)",
                            len(final_events), len(_seen_event_ids))
        except Exception as e:
            logger.warning("DESPERATION_POLL error: %s", e)

    # --- ZIP FALLBACK with retry ---
    # If both the main poll AND desperation poll failed, try the trajectory
    # zip download. The zip may not be immediately available after the
    # conversation finishes (race with Cloud API zip generation), so retry
    # with backoff.
    if last_status in ("completed", "finished") and not all_new_msgs:
        import io, re, zipfile
        _zip_exc: Exception | None = None
        for zip_attempt in range(3):
            try:
                # Snapshot last_assistant BEFORE the lock check (Phase 3 uses lock)
                _last_assistant_text: str | None = None
                with _lock:
                    for m in reversed(_msgs()):
                        if m.get("role") == "assistant":
                            _last_assistant_text = m.get("content", "")
                            break
                r3 = httpx.get(
                    f"{CLOUD_API_URL}/api/v1/app-conversations/{_conversation_id}/download",
                    headers=_headers(),
                    timeout=30,
                )
                r3.raise_for_status()
                zf = zipfile.ZipFile(io.BytesIO(r3.content))
                def _num_key(name: str) -> list:
                    return [int(t) if t.isdigit() else t.lower() for t in re.split(r'(\d+)', name)]
                event_files = sorted(
                    [n for n in zf.namelist() if n.startswith("event_") and n.endswith(".json")],
                    key=_num_key,
                )
                if not event_files:
                    event_files = sorted(
                        [n for n in zf.namelist() if "event" in n.lower() and n.endswith(".json")],
                        key=_num_key,
                    )
                logger.info("ZIP_ATTEMPT %d/3: %d event files, searching for agent MessageEvent",
                            zip_attempt + 1, len(event_files))
                found = False
                for fname in reversed(event_files):
                    with zf.open(fname) as f:
                        evt = json.loads(f.read())
                    if evt.get("kind") == "MessageEvent" and evt.get("source") == "agent":
                        # Skip if already seen via events/search (duplicate event ID)
                        evt_id = evt.get("id", "")
                        if evt_id and evt_id in _seen_event_ids:
                            logger.info("ZIP_ATTEMPT %d/3: skipping MessageEvent id=%s (already seen via events/search)",
                                        zip_attempt + 1, evt_id[:20])
                            continue
                        # Use shared helper
                        raw = _extract_message_text(evt)
                        if not raw:
                            continue
                        # CRITICAL: skip if text matches last_assistant (stale from previous turn)
                        if _last_assistant_text and raw.strip() == _last_assistant_text.strip():
                            logger.warning("ZIP_ATTEMPT %d/3: SKIPPING MessageEvent ts=%s (text matches last_assistant — stale zip)",
                                           zip_attempt + 1, evt.get("timestamp", 0))
                            continue
                        evt_ts = evt.get("timestamp", 0)
                        logger.info("ZIP_ATTEMPT %d/3: FOUND new agent MessageEvent ts=%s (len=%d)",
                                    zip_attempt + 1, evt_ts, len(raw))
                        all_new_msgs = [raw]
                        _last_response_source = "zip"
                        # Register dedup
                        if evt_id:
                            _seen_event_ids.add(evt_id)
                        found = True
                        break
                if found:
                    break
                else:
                    logger.warning("ZIP_ATTEMPT %d/3: no NEW assistant MessageEvent in %d files",
                                   zip_attempt + 1, len(event_files))
                    if zip_attempt < 2:
                        backoff = 2 ** (zip_attempt + 1)  # 2s, 4s
                        logger.info("ZIP_ATTEMPT %d/3: retrying in %ds (zip may not be ready yet)", zip_attempt + 1, backoff)
                        time.sleep(backoff)
            except Exception as e:
                _zip_exc = e
                logger.warning("ZIP_ATTEMPT %d/3 error: %s", zip_attempt + 1, e)
                if zip_attempt < 2:
                    backoff = 2 ** (zip_attempt + 1)
                    time.sleep(backoff)

    if not all_new_msgs:
        elapsed = int(time.time() - start)
        logger.warning("No assistant messages found after %ds (status=%s)", elapsed, last_status)
        logger.warning("All event kinds seen: %s", sorted(_event_kinds))
        logger.warning("Total events: %d, messages: %d", len(all_events), len(_msgs()))
        logger.warning("No MessageEvent found after %ds (status=%s) — returning None. "
                       "All event kinds: %s. Total events: %d.",
                       elapsed, last_status, sorted(_event_kinds), len(all_events))

        # Set module-level flag so send() can detect this specific failure mode
        # and reset the stale conversation to prevent cascade swallowing.
        _last_completed_no_msg = bool(_completed_normally)

        with _lock:
            _msgs().append({"id": _next_msg_id(), 
                "role": "event",
                "content": f"[WARN] No response from agent after {elapsed}s (status: {last_status or 'unknown'}). The agent may be stuck or the LLM may not be configured correctly on the server.",
                "kind": "SystemEvent",
                "timestamp": int(time.time() * 1000),
            })

    _conversation_status = "idle"
    # CRITICAL: on timeout (not completed, not failed), do NOT return partial
    # MessageEvent text — that's the "half-cut response" bug. Phase 3 would
    # save it as the final assistant message, making the user think the AI
    # finished when it actually timed out mid-work.
    #
    # Do NOT reset _conversation_id here. The conversation is still "running"
    # on the Cloud. The next send() reuses it — _send_message() queues a new
    # message or gets 409 → resume → retry. Either way: SAME conversation →
    # DeepSeek caching preserved → cheap. Only create a new conv if the
    # 409 recovery itself fails (handled in send() recovery path).
    if not _completed_normally:
        elapsed = int(time.time() - start)
        if all_new_msgs:
            logger.warning("TIMEOUT_CLEANUP (%ds): discarding %d partial msgs, conv=%s NOT reset (kept for caching)",
                           elapsed, len(all_new_msgs), _conversation_id)
            all_new_msgs.clear()
        else:
            logger.warning("TIMEOUT_CLEANUP (%ds): no partial msgs, conv=%s NOT reset (kept for caching). "
                           "status=%s last_status=%s events=%d seen_ids=%d completed=%s",
                           elapsed, _conversation_id, _conversation_status, last_status,
                           len(all_events) if 'all_events' in dir() else -1,
                           len(_seen_event_ids), _completed_normally)
        _msgs().append({"id": _next_msg_id(), 
            "role": "event",
            "content": f"[TIMEOUT] Agent did not finish within {elapsed}s. The agent may still be running — try 'continue'.",
            "kind": "SystemEvent",
            "timestamp": int(time.time() * 1000),
        })
    # AUDIT: log final state before returning
    tool_count = sum(1 for m in _msgs() if m.get("role") == "event" and m.get("kind") not in ("SystemEvent",))
    status_count = sum(1 for m in _msgs() if m.get("role") == "event" and m.get("kind") == "SystemEvent")
    # Determine response source for Phase 3 diagnostics
    # all_new_msgs was populated by: events/search (default), zip fallback,
    # or scrape fallback. The zip fallback sets a flag; scrape is the last resort.
    # Snapshot the source global so Phase 3 can log it.
    if all_new_msgs:
        # Check if zip fallback found data (zip sets _last_zip_response_ts)
        # We use a heuristic: if all_new_msgs was populated by the event loop
        # (normal path), _last_response_source stays "events/search".
        # If the zip or scrape ran, they should have set the source.
        # If nothing set it, default to events/search.
        pass  # source was already set by zip/scrape if they ran
    else:
        _last_response_source = ""  # no response
    logger.info("AUDIT wait_exit: conv=%s elapsed=%ds msgs=%d tool_evts=%d status_evts=%d "
                "all_new_msgs=%d seen=%d ts=%s has_response=%s source=%s",
                _conversation_id, int(time.time()-start), len(_msgs()),
                tool_count, status_count, len(all_new_msgs), len(_seen_event_ids),
                _last_event_timestamp or "(none)",
                bool(all_new_msgs), _last_response_source)
    return "\n\n".join(all_new_msgs) if all_new_msgs else None



def _format_event_preview(evt: dict) -> str | None:
    """Format a Cloud API event for UI display. All text is TRUNCATED to short
    previews — the full content is in the Cloud conversation, not needed in chat."""
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
                cmd_short = cmd[:200].replace("\n", " ").strip()
                return f"[TERMINAL] $ {cmd_short}"
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
                q_short = q[:150].replace("\n", " ").strip()
                return f"[SEARCH] Searching: {q_short}"
        elif tool == "browser_navigate":
            url = action.get("url", "")
            if url:
                url_short = url[:150].replace("\n", " ").strip()
                return f"[BROWSER] Navigate: {url_short}"
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
                short = str(out)[:2000].replace("\n", " ").strip()
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
                    title = r.get("title", "")[:100].strip()
                    url = r.get("url", "")[:100].strip()
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
            # Generic observation preview for all unhandled tools.
            # Previously these were silently dropped, which made the user
            # see "[TOOL] read: {...}" action but NEVER the result — the
            # "swallowed events" bug (#3).
            output = ""
            for key in ("output", "content", "text", "result", "data"):
                val = obs.get(key, "")
                if isinstance(val, (str, int, float)):
                    output = str(val)
                    break
                if isinstance(val, dict) and val.get("output"):
                    output = str(val["output"])
                    break
            if not output:
                output = str(obs)
            short = output[:1000].replace("\n", " ").strip()
            if short:
                return f"[OUT] {short}"
            return None

    elif kind == "ErrorEvent":
        msg = evt.get("message", "")
        error_type = evt.get("error_type", "") or evt.get("type", "")
        text = msg or error_type or "Unknown error"
        return f"[ERROR] {text[:300]}"
    elif kind == "ConversationStateUpdateEvent":
        key = evt.get("key", "")
        val = evt.get("value", "")
        if key and val:
            val_short = str(val)[:100].replace("\n", " ").strip()
            return f"[STATE] {key}={val_short}"
        return None
    elif kind == "SystemPromptEvent":
        return None  # internal prompt, not user-facing
    elif kind in ("MessageEvent",):
        return None  # handled in _wait_for_response
    # Catch-all: show unknown event kinds so the user never sees a
    # silent drop — even a generic "[EVENT]" is better than nothing.
    kind_label = kind or "UnknownEvent"
    evt_str = str(evt.get("message", evt.get("content", "")))[:200]
    if evt_str:
        return f"[{kind_label}] {evt_str}"
    return f"[{kind_label}] (raw)"
