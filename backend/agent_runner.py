"""OpenHands Cloud API integration for VibeCode.

Uses the OpenHands Cloud REST API (V1) to start conversations, poll events,
and manage sandboxes. Custom LLM is configured via the Cloud API's LLM settings.

API docs: https://docs.openhands.dev/openhands/usage/api/v1
"""

import json
import os
import threading
import time
import traceback
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, Optional

import httpx


@dataclass
class AgentConfig:
    model: str
    api_key: str
    base_url: Optional[str] = None


# Global LLM config — updated via API
_llm_config: Optional[AgentConfig] = None
_config_lock = threading.Lock()

CLOUD_API_URL = os.getenv("OPENHANDS_CLOUD_API_URL", "https://app.all-hands.dev")


def get_llm_config() -> AgentConfig:
    """Get current LLM config from env or global override."""
    global _llm_config
    with _config_lock:
        if _llm_config:
            return _llm_config
    return AgentConfig(
        model=os.getenv("LLM_MODEL", "deepseek-chat"),
        api_key=os.getenv("LLM_API_KEY", ""),
        base_url=os.getenv("LLM_BASE_URL"),
    )


def set_llm_config(config: AgentConfig) -> None:
    """Update LLM config at runtime."""
    global _llm_config
    with _config_lock:
        _llm_config = config
    os.environ["LLM_API_KEY"] = config.api_key
    os.environ["LLM_MODEL"] = config.model
    if config.base_url:
        os.environ["LLM_BASE_URL"] = config.base_url


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
    base = f"Repository: {repo} (branch: {branch}).\n\n"

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


def _build_default_mcp_servers() -> list[dict]:
    """Build default MCP servers from environment variables."""
    servers: list[dict] = []
    
    github_token = os.getenv("GITHUB_TOKEN", "")
    if github_token:
        servers.append({
            "name": "github",
            "config": {"token": github_token},
        })
    
    tavily_key = os.getenv("TAVILY_API_KEY", "")
    if tavily_key:
        servers.append({
            "name": "tavily",
            "config": {"api_key": tavily_key},
        })
    
    return servers


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

    Args:
        mcp_servers: Optional list of MCP server configs (name + config dict).
                     Defaults to building from GITHUB_TOKEN + TAVILY_API_KEY env vars.

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

        # Include MCP servers (defaults: GITHUB_TOKEN + TAVILY_API_KEY from env)
        servers = mcp_servers if mcp_servers is not None else _build_default_mcp_servers()
        if servers:
            body["mcp_servers"] = servers

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
                items = task_data.get("items", [])
                if items and items[0].get("app_conversation_id"):
                    conversation_id = items[0]["app_conversation_id"]
                    break

        if not conversation_id:
            result["error_message"] = "Failed to get conversation ID from start task"
            return result

        result["conversation_id"] = conversation_id

        if status_callback:
            status_callback("running")

        # --- Step 2: Poll for events until completion ---
        seen_event_ids: set = set()
        event_index = 0
        poll_interval = 3  # seconds

        while True:
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
            items = status_data.get("items", [])

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
                all_events = events_data.get("items", [])
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
                    if event_callback:
                        event_callback(serialized)

            # Check if done
            if execution_status in ("completed", "finished"):
                result["status"] = "completed"
                break
            elif execution_status in ("failed", "error", "stopped"):
                result["status"] = "failed"
                result["error_message"] = conv.get("error_message") or f"Execution status: {execution_status}"
                break
            elif execution_status == "running":
                continue
            # If status is "starting" or unknown, keep polling

    except httpx.HTTPStatusError as e:
        result["status"] = "failed"
        result["error_message"] = f"API error {e.response.status_code}: {e.response.text[:200]}"
        traceback.print_exc()
    except Exception as e:
        result["status"] = "failed"
        result["error_message"] = f"{type(e).__name__}: {str(e)}"
        traceback.print_exc()

    if status_callback:
        status_callback(result["status"])

    return result
