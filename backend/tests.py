"""Tests for VibeCode backend API.

Run with: uv run pytest tests.py -v -p no:libtmux
"""

import asyncio
import os
import sys
import tempfile

import pytest

# Use a temp DB for tests
os.environ["VIBECODE_DB_PATH"] = os.path.join(tempfile.gettempdir(), "vibecode_test.db")
# Set API key for LLM config tests
os.environ["LLM_API_KEY"] = "sk-test-key-for-llm-config-tests"

from fastapi.testclient import TestClient
from database import init_db
from main import app


def _reset_db():
    """Reset the test database synchronously."""
    db_path = os.environ["VIBECODE_DB_PATH"]
    if os.path.exists(db_path):
        os.remove(db_path)
    asyncio.run(init_db())


@pytest.fixture(autouse=True)
def setup_db():
    """Initialize a fresh test database before each test."""
    _reset_db()
    yield
    db_path = os.environ["VIBECODE_DB_PATH"]
    if os.path.exists(db_path):
        os.remove(db_path)


@pytest.fixture
def client():
    return TestClient(app)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

def test_health(client):
    resp = client.get("/api/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert "model" in data
    assert data["version"] == "1.0.0"


# ---------------------------------------------------------------------------
# Prompts / Tasks
# ---------------------------------------------------------------------------

def test_create_prompt(client):
    resp = client.post("/api/prompts", json={
        "prompt": "Create a hello.py file",
        "repo": "owner/repo",
        "branch": "main",
        "mode": "code",
    })
    assert resp.status_code == 201
    data = resp.json()
    assert data["status"] == "queued"
    assert data["prompt"] == "Create a hello.py file"
    assert data["repo"] == "owner/repo"
    assert data["mode"] == "code"
    assert "id" in data
    return data["id"]


def test_create_prompt_defaults(client):
    resp = client.post("/api/prompts", json={
        "prompt": "Test",
        "repo": "x/y",
    })
    assert resp.status_code == 201
    data = resp.json()
    assert data["branch"] == "main"
    assert data["mode"] == "code"


def test_create_prompt_validation(client):
    # Empty prompt
    resp = client.post("/api/prompts", json={"prompt": "", "repo": "x/y"})
    assert resp.status_code == 422

    # Invalid repo format
    resp = client.post("/api/prompts", json={"prompt": "test", "repo": "invalid"})
    assert resp.status_code == 422

    # Invalid mode
    resp = client.post("/api/prompts", json={"prompt": "test", "repo": "x/y", "mode": "invalid"})
    assert resp.status_code == 422


def test_list_tasks(client):
    # Create 3 tasks
    for i in range(3):
        client.post("/api/prompts", json={"prompt": f"Task {i}", "repo": "x/y"})

    resp = client.get("/api/tasks")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data["tasks"]) == 3
    # Newest first
    assert data["tasks"][0]["prompt"] == "Task 2"


def test_list_tasks_filter(client):
    client.post("/api/prompts", json={"prompt": "Task A", "repo": "x/y"})
    client.post("/api/prompts", json={"prompt": "Task B", "repo": "x/y"})

    resp = client.get("/api/tasks?status=queued")
    assert resp.status_code == 200
    assert len(resp.json()["tasks"]) == 2

    resp = client.get("/api/tasks?status=running")
    assert resp.status_code == 200
    assert len(resp.json()["tasks"]) == 0


def test_get_task(client):
    task_id = test_create_prompt(client)
    resp = client.get(f"/api/tasks/{task_id}")
    assert resp.status_code == 200
    assert resp.json()["id"] == task_id


def test_get_task_404(client):
    resp = client.get("/api/tasks/nonexistent")
    assert resp.status_code == 404


def test_delete_task(client):
    task_id = test_create_prompt(client)
    resp = client.delete(f"/api/tasks/{task_id}")
    assert resp.status_code == 200
    assert resp.json()["status"] == "deleted"

    # Task should be gone
    resp = client.get(f"/api/tasks/{task_id}")
    assert resp.status_code == 404


def test_delete_task_404(client):
    resp = client.delete("/api/tasks/nonexistent")
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

def test_get_events_empty(client):
    task_id = test_create_prompt(client)
    resp = client.get(f"/api/tasks/{task_id}/events")
    assert resp.status_code == 200
    data = resp.json()
    assert data["events"] == []
    assert data["has_more"] is False
    assert data["task_status"] == "queued"


def test_get_events_404(client):
    resp = client.get("/api/tasks/nonexistent/events")
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# FCM Token
# ---------------------------------------------------------------------------

def test_register_fcm_token(client):
    resp = client.post("/api/fcm-token", json={"token": "test-fcm-token-123"})
    assert resp.status_code == 200
    assert resp.json()["status"] == "registered"


# ---------------------------------------------------------------------------
# LLM Config
# ---------------------------------------------------------------------------

def test_update_llm_config(client):
    resp = client.put("/api/config/llm", json={
        "api_key": "sk-test-key",
        "model": "deepseek/deepseek-v4-flash",
        "base_url": "https://api.deepseek.com/v1",
    })
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "updated"
    assert data["model"] == "deepseek/deepseek-v4-flash"


def test_get_llm_config(client):
    # Update first
    client.put("/api/config/llm", json={
        "api_key": "sk-test",
        "model": "deepseek/deepseek-v4-pro",
        "base_url": None,
    })
    resp = client.get("/api/config/llm")
    assert resp.status_code == 200
    data = resp.json()
    assert data["model"] == "deepseek/deepseek-v4-pro"
    assert data["has_api_key"] is True
    assert "api_key" not in data  # Key is never returned


def test_plan_mode_prompt(client):
    """Test that plan mode prompts are accepted."""
    resp = client.post("/api/prompts", json={
        "prompt": "Build a web scraper",
        "repo": "owner/repo",
        "mode": "plan",
    })
    assert resp.status_code == 201
    assert resp.json()["mode"] == "plan"


# ---------------------------------------------------------------------------
# Run directly
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import subprocess
    subprocess.run([sys.executable, "-m", "pytest", __file__, "-v"])
