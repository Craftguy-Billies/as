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

# Current conversation status (for UI visibility)
_conversation_status: str = "idle"
_CHAT_TIMEOUT = int(os.getenv("VIBECODE_CHAT_TIMEOUT", "600"))  # 10 min default

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
    global _conversation_id, _conversation_repo, _conversation_branch, _conversation_mode, _conversation_llm_model, _last_event_index, _last_event_timestamp, _messages_by_repo, _current_repo_key
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
                threading.Thread(target=_process_batch_worker, daemon=True).start()
                logger.info("Auto-resuming batch: %d/%d remaining", _batch_total - _batch_position, _batch_total)
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
    global _conversation_id, _conversation_repo, _conversation_branch, _conversation_mode, _conversation_llm_model, _last_event_index, _last_event_timestamp, _messages_by_repo, _event_kinds, _conversation_status, _sandbox_id, _current_repo_key
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
    """Return current chat state for API consumers.
    
    If repo/mode are provided, switch the active repo key first.
    This lets the Flutter client request messages for a specific repo.
    """
    global _current_repo_key
    with _lock:
        if repo or mode:
            _current_repo_key = _repo_key(repo)
        msgs = list(_msgs())
        event_count = sum(1 for m in msgs if m.get("role") == "event")
        # AUDIT: log state response (limit event_count to avoid spam)
        logger.info("AUDIT get_state: repo=%s mode=%s conv=%s msgs=%d events=%d seen_ids=%d batch_running=%s",
                    _current_repo_key, mode, _conversation_id, len(msgs),
                    event_count, len(_seen_event_ids), _batch_running)
        # Build batch status: position is 0-based index of current prompt.
        # done = number of completed prompts (prompts[0:done] are finished).
        return {
            "messages": msgs,
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
                "position": _batch_position,
                "total": _batch_total,
                "done": _batch_position,
                "prompts": list(_batch_prompts),
                "modes": list(_batch_prompt_modes),
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
    global _conversation_id, _conversation_repo, _conversation_branch, _conversation_mode, _conversation_llm_model, _last_event_index, _last_event_timestamp, _sandbox_id

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

    # Guard: if called externally while batch is running, auto-enqueue instead.
    # Batch worker passes _from_batch=True to bypass this guard.
    if not _from_batch:
        with _lock:
            if _batch_running:
                _batch_prompts.append(prompt)
                _batch_prompt_modes.append(mode)
                _batch_total = len(_batch_prompts)
                _persist_to_db()
                logger.info("Batch running — auto-enqueued prompt (now %d total)", _batch_total)
                return {"status": "appended", "position": _batch_position, "total": _batch_total}

    # DO NOT reset event cursors here — _last_event_index, _last_event_timestamp,
    # and _seen_event_ids persist across send() calls so the SECOND message in a
    # batch correctly fetches ONLY new events (not re-processing the first message's).
    # Reset happens inside Phase 1a when ctx_changed triggers a new conversation.
    logger.info("Chat send: prompt=%.80s... repo=%s branch=%s mode=%s", prompt, repo, branch or '(empty)', mode)

    # Branch validation: if user explicitly provided a branch, verify it exists.
    # If invalid, reject immediately — no git pull, no message sent.
    branch_provided = bool(branch)
    if branch_provided:
        valid_branches = get_branches(repo)
        # Also consider the default branch valid (in case GitHub API fails or
        # the branch list doesn't include it yet — e.g. a very fresh repo).
        default_branch = _detect_default_branch(repo)
        all_valid = valid_branches + ([default_branch] if default_branch and default_branch not in valid_branches else [])
        if branch not in all_valid:
            logger.warning("send: invalid branch '%s' for %s — available: %s", branch, repo, all_valid[:10])
            return {"error": f"Branch '{branch}' not found in {repo}. Available: {', '.join(all_valid[:10]) or 'unknown'}"}
        logger.info("send: branch '%s' validated for %s", branch, repo)

    # Phase 1a: Quick check under lock — do we need a new conversation?
    with _lock:
        effective_branch = branch if branch else _conversation_branch
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
                    "from_batch=%s model_changed=%s ctx=%s branch_sw=%s need_new=%s",
                    _conversation_id or "(none)", _conversation_repo, _conversation_mode,
                    _conversation_llm_model or "(none)", current_model,
                    _from_batch, model_changed, ctx_changed, branch_switched,
                    _conversation_id is None)
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
            new_conv_id = _create_conversation(prompt, repo, branch, mode)
            logger.info("Phase 1b: created conv=%s (repo=%s mode=%s model=%s seen_ids=%d)",
                        new_conv_id, repo, mode, current_model, len(_seen_event_ids))
        else:
            logger.info("Phase 1b: reusing conv=%s repo=%s mode=%s seen_ids=%d",
                        current_conv_id, repo, mode, len(_seen_event_ids))
            effective_prompt = prompt
            # Only inject git pull when user explicitly provided a branch.
            # No branch = no git pull = no detection = work on whatever the sandbox has.
            if branch_provided:
                git_prefix = f"cd /workspace && git pull origin {branch} 2>&1 || echo 'git pull failed'\n\n"
                if branch_switched:
                    checkout_cmd = f"cd /workspace && git fetch origin && git checkout {branch} && git pull origin {branch}"
                    git_prefix = f"{checkout_cmd}\n\n"
                    logger.info("Injected branch switch: checkout %s", branch)
                else:
                    logger.info("Injected git pull: branch %s", branch)
                effective_prompt = f"{git_prefix}{prompt}"
            else:
                logger.info("No branch — sending prompt as-is, no git pull")
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
                    logger.warning("send_message failed (non-409): send_err=%s", send_err)
                    with _lock:
                        _conversation_id = None
                        _last_event_index = 0
                        _sandbox_id = None
                        _persist_to_db()
                    return {"error": send_err or "Failed to send message to conversation"}
    except httpx.HTTPStatusError as e:
        status_code = e.response.status_code
        logger.error("HTTP error: %s %s", status_code, e.response.text[:200])
        if status_code in (404, 409, 410):
            logger.warning("HTTP %s — resetting conversation_id", status_code)
            with _lock:
                _conversation_id = None
                _last_event_index = 0
                _sandbox_id = None
                _persist_to_db()
        return {"error": f"Cloud API error: {status_code}"}
    except Exception as e:
        logger.error("Chat error (keeping conversation): %s", e, exc_info=True)
        return {"error": str(e)}

    # Phase 1c: Update state + save user message under lock
    with _lock:
        if need_new_conv:
            _conversation_id = new_conv_id
            _conversation_repo = repo
            _conversation_branch = branch if branch else _conversation_branch
            _conversation_mode = mode
            _conversation_llm_model = current_model
            _current_repo_key = _repo_key(repo)
            _last_event_index = 0
            _last_event_timestamp = ""  # reset min_timestamp for new conversation
            _seen_event_ids.clear()
            _seen_event_hashes.clear()
            logger.info("Phase 1c: stored new conv=%s repo=%s branch=%s mode=%s model=%s seen_ids=0",
                        new_conv_id, repo, _conversation_branch, mode, current_model)
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
    try:
        response = _wait_for_response()
        logger.info("Phase 2: done, response=%s", "non-empty (%d chars)" % len(response) if response else "None/empty")
    except Exception as e:
        logger.error("Phase 2 crashed: %s", e, exc_info=True)
        response = None

    # Phase 3: Save result under lock.
    # _wait_for_response collects only new MessageEvent texts via event ID
    # dedup. In rare cases the API may return cumulative content (old + new),
    # so handle prefix-stripping gracefully. Reject byte-identical responses
    # — they indicate the trajectory-zip fallback returned a previous turn's
    # cached response instead of the current turn's output.
    duplicate_rejected = False
    with _lock:
        if response and response.strip():
            response = response.strip()
            msgs = _msgs()
            # Strip cumulative prefix: if response starts with the last
            # assistant message, remove it (handles API returning cumulative
            # content in rare cases). If they're identical, reject — this
            # indicates a stale cached response from a previous turn.
            last_assistant = next(
                (m["content"] for m in reversed(msgs) if m.get("role") == "assistant"),
                None,
            )
            if last_assistant:
                if response == last_assistant:
                    logger.warning("Phase 3: response byte-identical to last assistant — "
                                   "rejecting (len=%d). This indicates the agent returned "
                                   "a cached/stale response from a previous turn.", len(response))
                    duplicate_rejected = True
                    response = None
                elif response.startswith(last_assistant):
                    stripped = response[len(last_assistant):].strip()
                    if stripped:
                        logger.info("Phase 3: stripped cumulative prefix (was %d, now %d chars)",
                                    len(response), len(stripped))
                        response = stripped
                    else:
                        logger.info("Phase 3: only cumulative prefix remains after strip — "
                                    "saving original (len=%d)", len(response))
            if response:  # may have been set to None by duplicate rejection above
                resp_msg_id = _next_msg_id()
                event_count_before = sum(1 for m in msgs if m.get("role") == "event")
                _msgs().append({"id": resp_msg_id, 
                    "role": "assistant",
                    "content": response,
                    "timestamp": int(time.time() * 1000),
                })
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
        return {"response": response, "conversation_id": conv_id}
    elif duplicate_rejected:
        logger.warning("send: returning error (duplicate response rejected)")
        return {
            "error": "Agent returned a cached response identical to the previous reply. "
                     "The conversation may need to be reset — try New Conversation.",
            "conversation_id": _conversation_id,
        }
    else:
        _auto_append_log(repo, prompt, str(response), ok=False)
        logger.warning("send: returning error (no response)")
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
    global _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _batch_repo, _batch_branch, _batch_mode, _batch_running, _batch_cancelled, _batch_skip_prompt

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
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _batch_repo, _batch_branch, _batch_mode, _batch_skip_prompt
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
            logger.info("Batch [%d/%d]: %.80s...", pos, total, prompt)
            try:
                result = send(prompt, repo=repo, branch=branch, mode=mode, _from_batch=True)
                logger.info("Batch [%d/%d]: send() returned status=%s has_error=%s msgs=%d",
                            pos, total,
                            result.get("status") if result else "None",
                            bool(result and "error" in result),
                            len(_msgs()))
            except Exception as e:
                logger.error("Batch send crashed [%d/%d]: %s", pos, total, e)
                result = {"error": str(e)}

            if result and "error" in result:
                # Check if this was a deliberate cancellation — show STOPPED, not ERROR
                with _lock:
                    was_cancelled = _batch_cancelled
                    was_skipped = _batch_skip_prompt
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
        with _lock:
            _msgs().append({"id": _next_msg_id(), 
                "role": "error",
                "content": f"Worker crashed: {type(e).__name__}: {e}",
                "timestamp": int(time.time() * 1000),
            })
    finally:
        with _lock:
            _batch_running = False
            _batch_position = 0
            _batch_total = 0
        _persist_to_db()


def cancel_batch() -> dict:
    """Cancel the running batch queue. Non-blocking — sets flag for worker.
    
    Edge cases handled:
    - Worker blocked in send() → _batch_cancelled flag will be checked on next cycle
    - Worker idle → immediate stop
    - Already cancelled → no-op
    - No batch running → no-op
    """
    global _batch_cancelled, _batch_running, _batch_prompts, _batch_prompt_modes, _batch_position, _batch_total, _conversation_status
    with _lock:
        if not _batch_running and not _batch_cancelled:
            logger.info("cancel_batch: no batch running — no-op")
            return {"status": "idle", "message": "No batch running"}
        if _batch_cancelled:
            logger.info("cancel_batch: already cancelled — no-op")
            return {"status": "already_cancelled"}
        _batch_cancelled = True  # non-blocking flag, worker checks each iteration
        _conversation_status = "idle"
        was_running = _batch_running
        _batch_running = False  # signal weakly — worker_finally block resets fully
        remaining = _batch_total - _batch_position
        _batch_prompts = []
        _batch_prompt_modes = []
        # Don't reset position/total here — let worker detect cancel and
        # append a [STOPPED] message. Worker's finally block resets fully.
    if was_running:
        logger.info("cancel_batch: cancelled (%d remaining, worker will finalize)", remaining)
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
    """Fetch branch list for a repo from GitHub API. Cached 5 min."""
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
            f"When implementing changes: review relevant files, make edits, "
            f"commit with a descriptive message, and push.\n\n"
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


def _wait_for_response(timeout: int | None = None) -> str | None:
    """Poll conversation status + events until the agent finishes (SAME logic as agent_runner).

    Timeout: VIBECODE_CHAT_TIMEOUT env var (default 600s = 10 min).

    Also appends live events (tool calls, observations) to the chat history so the client
    can see what the agent is doing via polling get_state().
    """
    global _last_event_index, _last_event_timestamp, _conversation_status, _sandbox_id

    if timeout is None:
        timeout = _CHAT_TIMEOUT

    start = time.time()
    _wait_started_at_ts = str(int(time.time() * 1000))  # unix ms for event filtering
    all_new_msgs: list[str] = []
    last_status = ""
    last_event_count = 0

    # AUDIT: log entry state
    logger.info("AUDIT wait_entry: conv=%s ts=%s seen_ids=%d seen_hashes=%d last_idx=%d timeout=%d msgs_before=%d",
                _conversation_id, _last_event_timestamp or "(none)",
                len(_seen_event_ids), len(_seen_event_hashes), _last_event_index,
                timeout, len(_msgs()))

    poll_count = 0
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
        # (returns 422). Use a single request with a large enough limit.
        # 1000 events is sufficient for a single turn's tool calls.
        all_events: list = []
        try:
            params: dict = {"limit": 1000}
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

            # Skip already-seen events (dedup across send() calls)
            dedup_by_id = bool(evt_id) and evt_id in _seen_event_ids
            # For events without Cloud API IDs, use content hash as fallback
            # so they're not re-added on every send() (inflating step count).
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
                    all_new_msgs.append(text)
                    with _lock:
                        _msgs().append({"id": _next_msg_id(), 
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
            logger.info("Conversation %s: finished. Kinds=%s new_msgs=%d total_msgs=%d "
                        "with_id=%d no_id=%d skipped=%d added=%d seen_ids=%d seen_hashes=%d",
                        _conversation_id,
                        sorted(_event_kinds),
                        len(all_new_msgs),
                        len(_msgs()),
                        with_id, no_id, skipped, added,
                        len(_seen_event_ids), len(_seen_event_hashes))
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
            return None

    # When finished, try trajectory zip to get the COMPLETE last response.
    # events/search may return truncated event lists. Only use zip as a
    # FALLBACK — if events/search already found assistant messages, trust
    # that data (zip extraction can override multiple msgs with one).
    if last_status in ("completed", "finished") and not all_new_msgs:
        try:
            import io, re, zipfile
            r3 = httpx.get(
                f"{CLOUD_API_URL}/api/v1/app-conversations/{_conversation_id}/download",
                headers=_headers(),
                timeout=30,
            )
            r3.raise_for_status()
            zf = zipfile.ZipFile(io.BytesIO(r3.content))
            # Natural sort: event_1 < event_2 < event_10 (NOT event_1 < event_10 < event_2)
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
            logger.info("Trajectory zip fallback: %d event files, searching for agent MessageEvent", len(event_files))
            found = False
            for fname in reversed(event_files):
                with zf.open(fname) as f:
                    evt = json.loads(f.read())
                if evt.get("kind") == "MessageEvent" and evt.get("source") == "agent":
                    llm_msg = evt.get("llm_message") or evt.get("message") or {}
                    if isinstance(llm_msg, dict):
                        content = llm_msg.get("content") or []
                        if isinstance(content, list):
                            parts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()]
                            if parts:
                                raw = "\n".join(parts)
                                evt_ts = evt.get("timestamp", 0)
                                logger.info("Trajectory zip: found agent MessageEvent ts=%s", evt_ts)
                                all_new_msgs = [raw]
                                found = True
                                break
                    elif isinstance(llm_msg, str) and llm_msg.strip():
                        evt_ts = evt.get("timestamp", 0)
                        logger.info("Trajectory zip: found agent MessageEvent ts=%s — str", evt_ts)
                        all_new_msgs = [llm_msg.strip()]
                        found = True
                        break
            if not found:
                logger.warning("Trajectory zip: no assistant MessageEvent in %d files", len(event_files))
                seen = set()
                for fname in event_files[-30:]:
                    with zf.open(fname) as f:
                        evt = json.loads(f.read())
                    seen.add((evt.get("kind", "?"), evt.get("source", "?")))
                logger.warning("Trajectory zip last 30 (kind,source): %s", sorted(seen))
        except Exception as e:
            logger.warning("Trajectory zip error: %s", e)

    if not all_new_msgs:
        elapsed = int(time.time() - start)
        logger.warning("No assistant messages found after %ds (status=%s)", elapsed, last_status)
        logger.warning("All event kinds seen: %s", sorted(_event_kinds))
        logger.warning("Total events: %d, messages: %d", len(all_events), len(_msgs()))

        # Fallback: scrape events for any text content.
        # Filter to only events from this turn (timestamp >= turn start)
        # to avoid scraping stale agent MessageEvent text from previous turns.
        recent = [e for e in all_events if str(e.get("timestamp", "")) >= _wait_started_at_ts]
        if not recent:
            recent = all_events[-20:]  # fallback within the fallback
        else:
            recent = recent[-20:]
        logger.warning("Fallback scrape: %d recent events (filtered from %d total)", len(recent), len(all_events))
        fallback_text = _scrape_events_for_text(recent)
        if fallback_text:
            logger.info("Fallback: scraped %d chars from last 20 events", len(fallback_text))
            all_new_msgs.append(fallback_text)

        if not all_new_msgs:
            with _lock:
                _msgs().append({"id": _next_msg_id(), 
                    "role": "event",
                    "content": f"[WARN] No response from agent after {elapsed}s (status: {last_status or 'unknown'}). The agent may be stuck or the LLM may not be configured correctly on the server.",
                    "kind": "SystemEvent",
                    "timestamp": int(time.time() * 1000),
                })

    _conversation_status = "idle"
    # AUDIT: log final state before returning
    tool_count = sum(1 for m in _msgs() if m.get("role") == "event" and m.get("kind") not in ("SystemEvent",))
    status_count = sum(1 for m in _msgs() if m.get("role") == "event" and m.get("kind") == "SystemEvent")
    logger.info("AUDIT wait_exit: conv=%s elapsed=%ds msgs=%d tool_evts=%d status_evts=%d "
                "all_new_msgs=%d seen=%d ts=%s has_response=%s",
                _conversation_id, int(time.time()-start), len(_msgs()),
                tool_count, status_count, len(all_new_msgs), len(_seen_event_ids),
                _last_event_timestamp or "(none)",
                bool(all_new_msgs))
    return "\n\n".join(all_new_msgs) if all_new_msgs else None



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
