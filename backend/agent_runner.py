"""OpenHands Cloud REST API integration for VibeCode.

Uses the OpenHands Cloud REST API (V1) to start conversations, poll events,
and manage sandboxes. MCP servers config follows the Model Context Protocol
format (https://modelcontextprotocol.io/).

API docs: https://docs.openhands.dev/openhands/usage/api/v1
SDK docs: https://docs.openhands.dev/sdk
"""

import json
import logging
import os
import threading
import time
import traceback
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, Optional

import httpx

logger = logging.getLogger(__name__)


@dataclass
class AgentConfig:
    model: str
    api_key: str
    base_url: Optional[str] = None
    git_name: Optional[str] = None
    git_email: Optional[str] = None


# Global LLM config — persisted to DB, survives server restart
_llm_config: Optional[AgentConfig] = None
# Global git config
_git_config = {"name": None, "email": None}
_config_lock = threading.Lock()

CLOUD_API_URL = os.getenv("OPENHANDS_CLOUD_API_URL", "https://app.all-hands.dev")


def _get_kv_db():
    """Lazy-load sync database for KV storage."""
    try:
        from database import get_sync_db
        return get_sync_db()
    except Exception:
        return None


# Restore LLM config from DB on module load
def _restore_llm_config() -> None:
    global _llm_config
    db = _get_kv_db()
    if db is None:
        return
    try:
        row = db.execute("SELECT value FROM kv_store WHERE key = 'llm_config'").fetchone()
        if row:
            data = json.loads(row[0])
            _llm_config = AgentConfig(
                model=data.get("model", ""),
                api_key=data.get("api_key", ""),
                base_url=data.get("base_url"),
            )
            # Also set env vars
            os.environ["LLM_API_KEY"] = _llm_config.api_key
            os.environ["LLM_MODEL"] = _llm_config.model
            if _llm_config.base_url:
                os.environ["LLM_BASE_URL"] = _llm_config.base_url
            logger.info("Restored LLM config: model=%s", _llm_config.model)
    except Exception:
        pass

_restore_llm_config()


def _restore_git_config() -> None:
    global _git_config
    db = _get_kv_db()
    if db is None:
        return
    try:
        row = db.execute("SELECT value FROM kv_store WHERE key = 'git_config'").fetchone()
        if row:
            data = json.loads(row[0])
            _git_config = {"name": data.get("name"), "email": data.get("email")}
            logger.info("Restored git config: name=%s", _git_config["name"])
    except Exception:
        pass

_restore_git_config()


def get_llm_config() -> AgentConfig:
    """Get current LLM config from env or global override."""
    global _llm_config
    with _config_lock:
        if _llm_config:
            return _llm_config
    return AgentConfig(
        model=os.getenv("LLM_MODEL", "deepseek/deepseek-v4-flash"),
        api_key=os.getenv("LLM_API_KEY", ""),
        base_url=os.getenv("LLM_BASE_URL"),
    )


def set_llm_config(config: AgentConfig) -> None:
    """Update LLM config at runtime. Persists to DB for survival across restarts."""
    global _llm_config
    with _config_lock:
        _llm_config = config
    os.environ["LLM_API_KEY"] = config.api_key
    os.environ["LLM_MODEL"] = config.model
    if config.base_url:
        os.environ["LLM_BASE_URL"] = config.base_url

    # Persist to DB
    db = _get_kv_db()
    if db:
        try:
            data = json.dumps({
                "model": config.model,
                "api_key": config.api_key,
                "base_url": config.base_url,
            })
            db.execute(
                "INSERT OR REPLACE INTO kv_store (key, value) VALUES ('llm_config', ?)",
                (data,),
            )
            db.commit()
            logger.info("LLM config persisted: model=%s", config.model)
        except Exception:
            try:
                db.execute(
                    "CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)"
                )
                db.commit()
            except Exception:
                pass


def get_git_config() -> dict:
    """Get current git name/email config."""
    global _git_config
    with _config_lock:
        return dict(_git_config)


def set_git_config(name: str, email: str) -> None:
    """Update git name/email. Persists to DB for survival across restarts."""
    global _git_config
    with _config_lock:
        _git_config = {"name": name, "email": email}
    db = _get_kv_db()
    if db:
        try:
            data = json.dumps({"name": name, "email": email})
            db.execute(
                "INSERT OR REPLACE INTO kv_store (key, value) VALUES ('git_config', ?)",
                (data,),
            )
            db.commit()
            logger.info("Git config persisted: %s <%s>", name, email)
        except Exception:
            try:
                db.execute(
                    "CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)"
                )
                db.commit()
            except Exception:
                pass


def _get_headers() -> dict:
    api_key = os.getenv("OPENHANDS_CLOUD_API_KEY", "")
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


def _serialize_cloud_event(event: dict, index: int) -> dict:
    """Convert a Cloud API event into our storage format."""
    return {
        "event_index": index,
        "timestamp": event.get("timestamp", datetime.now(timezone.utc).isoformat()),
        "kind": event.get("kind", "UnknownEvent"),
        "source": event.get("source"),
        "tool_name": event.get("tool_name"),
        "action_json": json.dumps(event.get("action")) if event.get("action") else None,
        "observation_json": json.dumps(event.get("observation")) if event.get("observation") else None,
        "message_json": event.get("message"),
        "raw_json": json.dumps(event, default=str),
    }


def _build_prompt_text(prompt: str, repo: str, branch: str, mode: str) -> str:
    """Build the full prompt text with repo context and mode instructions."""
    base = (
        f"Repository: {repo} (branch: {branch}).\n"
        "IMPORTANT: First run `git pull` to get the latest code. "
        "When you finish making changes, commit them with a descriptive message "
        "and push to the remote repository. If the user asked to create a pull request, "
        "use the GitHub CLI (gh) or GitHub API to create one.\n\n"
    )

    if mode == "plan":
        return (
            base
            + "IMPORTANT — PLAN MODE:\n"
            + "1. FIRST, analyze the task and research the codebase. Create a detailed implementation plan "
            + "saved to .agents_tmp/PLAN.md. Do NOT implement anything yet.\n"
            + "2. THEN, read the plan from .agents_tmp/PLAN.md and implement all parts.\n\n"
            + f"Task: {prompt}"
        )
    else:
        return base + prompt


def _build_default_mcp_config(mcp_servers: Optional[list[dict]] = None) -> Optional[dict]:
    """Build MCP configuration dict in Model Context Protocol format.

    Automatically enables:
    - Web fetch (mcp-server-fetch): included if VIBECODE_ENABLE_FETCH!=0 (default on)
    - Tavily search: if TAVILY_API_KEY env var is set
    - User-provided MCP servers merged on top

    Format follows the MCP client config spec:
    https://modelcontextprotocol.io/docs/concepts/architecture
    """
    servers: dict = {}

    # Web fetch (mcp-server-fetch): gated behind env var
    if os.getenv("VIBECODE_ENABLE_FETCH", "1") != "0":
        servers["fetch"] = {
            "command": "uvx",
            "args": ["mcp-server-fetch"],
        }

    # Tavily web search if API key provided (uvx = always available in sandbox)
    tavily_key = os.getenv("TAVILY_API_KEY", "")
    if tavily_key:
        servers["tavily"] = {
            "command": "uvx",
            "args": ["tavily-mcp"],
            "env": {"TAVILY_API_KEY": tavily_key},
        }

    # Merge user-provided MCP servers (override defaults)
    if mcp_servers:
        for srv in mcp_servers:
            name = srv.get("name", "")
            config = srv.get("config", {})
            if name and config:
                if "command" in config:
                    servers[name] = {
                        "command": config["command"],
                        "args": config.get("args", []),
                    }
                    if "env" in config:
                        servers[name]["env"] = config["env"]
                elif "url" in config:
                    servers[name] = {"url": config["url"]}
                    if config.get("auth") == "oauth":
                        servers[name]["auth"] = "oauth"

    if not servers:
        return None

    return {"mcpServers": servers}


def run_conversation_sync(
    prompt: str,
    repo: str,
    branch: str,
    mode: str,
    event_callback: Optional[Callable[[dict], None]] = None,
    status_callback: Optional[Callable[[str], None]] = None,
    mcp_servers: Optional[list[dict]] = None,
) -> dict:
    """Run an agent conversation via OpenHands Cloud REST API.

    Called from a background thread. Polls for events every 3 seconds,
    caches them, and returns when the conversation completes or fails.

    Features:
    - Auto MCP servers (web fetch + Tavily search) from env vars
    - Custom LLM config support
    - Real-time event polling with deduplication
    - Auto-clone GitHub repo via selected_repository

    Args:
        mcp_servers: Optional list of MCP server configs. Merged with defaults
                     from TAVILY_API_KEY env var.

    Returns:
        dict with: status, error_message, conversation_id, sandbox_id, events.
    """
    api_key = os.getenv("OPENHANDS_CLOUD_API_KEY", "")
    if not api_key:
        raise RuntimeError("OPENHANDS_CLOUD_API_KEY not set")

    result: dict = {
        "status": "failed",
        "error_message": None,
        "conversation_id": None,
        "sandbox_id": None,
        "events": [],
    }

    headers = _get_headers()
    prompt_text = _build_prompt_text(prompt, repo, branch, mode)

    try:
        if status_callback:
            status_callback("starting")

        # --- Step 1: Start the conversation ---
        cfg = get_llm_config()
        body = {
            "initial_message": {
                "content": [{"type": "text", "text": prompt_text}],
            },
            "selected_repository": repo,
            "selected_branch": branch,
            "title": prompt[:80],
        }
        # Include LLM config if user provided custom settings
        if cfg.api_key:
            body["llm_config"] = {
                "model": cfg.model,
                "api_key": cfg.api_key,
            }
            if cfg.base_url:
                body["llm_config"]["base_url"] = cfg.base_url

        # Include MCP servers (defaults: fetch + Tavily from env)
        mcp_config = _build_default_mcp_config(mcp_servers)
        if mcp_config:
            body["mcp_servers"] = mcp_config

        # Include git config for commits
        git = get_git_config()
        if git["name"] and git["email"]:
            body["git_config"] = {"name": git["name"], "email": git["email"]}

        resp = httpx.post(
            f"{CLOUD_API_URL}/api/v1/app-conversations",
            headers=headers,
            json=body,
            timeout=30,
        )
        resp.raise_for_status()
        start_data = resp.json()

        conversation_id = start_data.get("app_conversation_id")
        start_task_id = start_data.get("id")

        # If async, poll for the conversation ID
        if not conversation_id and start_task_id:
            for _ in range(30):  # up to 150 seconds
                time.sleep(5)
                task_resp = httpx.get(
                    f"{CLOUD_API_URL}/api/v1/app-conversations/start-tasks",
                    headers=headers,
                    params={"ids": start_task_id},
                    timeout=15,
                )
                task_resp.raise_for_status()
                task_data = task_resp.json()
                items = task_data if isinstance(task_data, list) else task_data.get("items", [])
                if items and items[0].get("app_conversation_id"):
                    conversation_id = items[0]["app_conversation_id"]
                    break

        if not conversation_id:
            logger.warning("run_conversation_sync: no conversation_id for task=%s", start_task_id)
            result["error_message"] = "Failed to get conversation ID from start task"
            return result

        result["conversation_id"] = conversation_id
        logger.info("run_conversation_sync: conv=%s for task=%s, polling for completion", conversation_id, start_task_id)

        if status_callback:
            status_callback("running")

        # --- Step 2: Poll for events until completion ---
        seen_event_ids: set = set()
        event_index = 0
        poll_interval = 3  # seconds
        poll_timeout = 900  # 15 min hard timeout
        poll_start = time.time()

        while time.time() - poll_start < poll_timeout:
            time.sleep(poll_interval)

            # Check conversation status
            status_resp = httpx.get(
                f"{CLOUD_API_URL}/api/v1/app-conversations",
                headers=headers,
                params={"ids": conversation_id},
                timeout=15,
            )
            status_resp.raise_for_status()
            status_data = status_resp.json()
            items = status_data if isinstance(status_data, list) else status_data.get("items", [])

            if not items:
                continue

            conv = items[0]
            execution_status = conv.get("execution_status", "")
            result["sandbox_id"] = conv.get("sandbox_id")

            # Fetch events
            try:
                events_resp = httpx.get(
                    f"{CLOUD_API_URL}/api/v1/conversation/{conversation_id}/events/search",
                    headers=headers,
                    params={"limit": 200},
                    timeout=15,
                )
                events_resp.raise_for_status()
                events_data = events_resp.json()
                all_events = events_data if isinstance(events_data, list) else events_data.get("items", [])
            except Exception:
                all_events = []

            # Process new events
            for evt in all_events:
                evt_id = evt.get("id", "")
                if evt_id and evt_id not in seen_event_ids:
                    seen_event_ids.add(evt_id)
                    serialized = _serialize_cloud_event(evt, event_index)
                    event_index += 1
                    result["events"].append(serialized)
                    if event_callback and callable(event_callback):
                        event_callback(serialized)

            # Check if done
            if execution_status in ("completed", "finished"):
                result["status"] = "completed"
                # Extract final assistant response text from events
                for evt in reversed(all_events):
                    if evt.get("kind") == "MessageEvent" and evt.get("source") != "user":
                        msg_obj = evt.get("llm_message") or evt.get("message") or {}
                        if isinstance(msg_obj, str) and msg_obj.strip():
                            result["response"] = msg_obj.strip()
                        elif isinstance(msg_obj, dict):
                            content = msg_obj.get("content") or []
                            if isinstance(content, list):
                                parts = []
                                for block in content:
                                    if isinstance(block, dict) and block.get("type") == "text":
                                        t = block.get("text", "")
                                        if t.strip():
                                            parts.append(t.strip())
                                if parts:
                                    result["response"] = "\n".join(parts)
                            elif isinstance(content, str) and content.strip():
                                result["response"] = content.strip()
                        if result.get("response"):
                            break
                logger.info(
                    "run_conversation_sync: conv=%s completed with %d events (seen=%d) response=%d chars",
                    conversation_id, len(result["events"]), len(seen_event_ids),
                    len(result.get("response", "")),
                )
                break
            elif execution_status in ("failed", "error", "stopped"):
                result["status"] = "failed"
                result["error_message"] = conv.get("error_message") or f"Execution status: {execution_status}"
                logger.warning(
                    "run_conversation_sync: conv=%s %s — %s",
                    conversation_id, execution_status, result["error_message"],
                )
                break
            elif execution_status == "running":
                continue
            else:
                logger.warning("run_conversation_sync: conv=%s unknown status=%s, continuing poll",
                               conversation_id, execution_status)

        else:
            # Polling timeout (while loop exited without break)
            result["status"] = "failed"
            result["error_message"] = f"Task timed out after {poll_timeout}s"
            logger.warning("run_conversation_sync: conv=%s timed out after %.0fs",
                           conversation_id, time.time() - poll_start)

    except httpx.HTTPStatusError as e:
        result["status"] = "failed"
        result["error_message"] = f"API error {e.response.status_code}: {e.response.text[:200]}"
        logger.error(f"HTTPStatusError: {e.response.status_code} {e.response.text[:200]}\n{traceback.format_exc()}")
    except Exception as e:
        result["status"] = "failed"
        result["error_message"] = f"{type(e).__name__}: {str(e)}"
        logger.error(f"Exception: {e}\n{traceback.format_exc()}")

    if status_callback:
        status_callback(result["status"])

    return result
