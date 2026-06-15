"""Async SQLite database layer for VibeCode backend."""

import aiosqlite
import os
from contextlib import asynccontextmanager

DB_PATH = os.getenv("VIBECODE_DB_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "vibecode.db"))


async def _get_db_path() -> str:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    return DB_PATH


async def init_db() -> None:
    """Create tables and indexes if they don't exist."""
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
                error_message TEXT
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
