"""Async SQLite database layer for VibeCode backend."""

import aiosqlite
import os
import sqlite3
import threading
from contextlib import asynccontextmanager

DB_PATH = os.getenv("VIBECODE_DB_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "vibecode.db"))

# Thread-local synchronous connection for non-async callers (chat_service, agent_runner)
_sync_conns: threading.local = threading.local()


def _resolve_path() -> str:
    path = DB_PATH
    if not os.path.isabs(path):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def get_sync_db() -> sqlite3.Connection:
    """Get a thread-local synchronous sqlite3 connection (for non-async code)."""
    conn = getattr(_sync_conns, 'conn', None)
    if conn is None:
        conn = sqlite3.connect(_resolve_path())
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        _sync_conns.conn = conn
    return conn


async def _get_db_path() -> str:
    path = DB_PATH
    # Ensure path is absolute so os.path.dirname works even for bare filenames
    if not os.path.isabs(path):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


async def init_db() -> None:
    """Create tables and indexes if they don't exist. Migrate old DBs."""
    path = await _get_db_path()
    async with aiosqlite.connect(path) as db:
        await db.execute("PRAGMA journal_mode=WAL")
        await db.execute("PRAGMA foreign_keys=ON")
        await db.executescript("""
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                prompt TEXT NOT NULL,
                repo TEXT NOT NULL,
                branch TEXT DEFAULT 'main',
                mode TEXT DEFAULT 'code',
                status TEXT DEFAULT 'queued',
                conversation_id TEXT,
                sandbox_id TEXT,
                created_at TEXT NOT NULL,
                completed_at TEXT,
                error_message TEXT,
                mcp_config TEXT
            );

            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                event_index INTEGER NOT NULL,
                timestamp TEXT NOT NULL,
                kind TEXT NOT NULL,
                source TEXT,
                tool_name TEXT,
                action_json TEXT,
                observation_json TEXT,
                message_json TEXT,
                raw_json TEXT NOT NULL,
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_events_task_ts
                ON events(task_id, timestamp);

            CREATE INDEX IF NOT EXISTS idx_events_task_index
                ON events(task_id, event_index);

            CREATE TABLE IF NOT EXISTS app_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS fcm_tokens (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                token TEXT UNIQUE NOT NULL,
                created_at TEXT NOT NULL
            );
        """)
        # Migration: add mcp_config column to existing DBs from older versions
        cursor = await db.execute("PRAGMA table_info(tasks)")
        columns = [row[1] for row in await cursor.fetchall()]
        if "mcp_config" not in columns:
            await db.execute("ALTER TABLE tasks ADD COLUMN mcp_config TEXT")
        await db.commit()


async def get_db() -> aiosqlite.Connection:
    """Get a database connection (caller must close it)."""
    path = await _get_db_path()
    db = await aiosqlite.connect(path)
    db.row_factory = aiosqlite.Row
    await db.execute("PRAGMA foreign_keys=ON")
    return db


@asynccontextmanager
async def get_db_ctx():
    """Async context manager for database connections."""
    db = await get_db()
    try:
        yield db
    finally:
        await db.close()
