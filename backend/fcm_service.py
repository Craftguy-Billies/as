"""Firebase Cloud Messaging service for push notifications."""

import json
import os
from typing import Optional

import aiosqlite


_fcm_initialized = False
_fcm_app = None


def init_firebase() -> bool:
    """Initialize Firebase Admin SDK. Returns True if successful."""
    global _fcm_initialized, _fcm_app

    creds_path = os.getenv("FIREBASE_CREDENTIALS_PATH", "")
    if not creds_path or not os.path.exists(creds_path):
        print(f"[FCM] Firebase credentials not found at {creds_path} — push notifications disabled")
        return False

    try:
        import firebase_admin
        from firebase_admin import credentials

        if not firebase_admin._apps:
            cred = credentials.Certificate(creds_path)
            _fcm_app = firebase_admin.initialize_app(cred)
        _fcm_initialized = True
        print("[FCM] Firebase initialized successfully")
        return True
    except Exception as e:
        print(f"[FCM] Firebase init failed: {e}")
        return False


async def get_fcm_tokens(db: aiosqlite.Connection) -> list[str]:
    """Get all registered FCM tokens from the database."""
    cursor = await db.execute("SELECT token FROM fcm_tokens")
    rows = await cursor.fetchall()
    return [row["token"] for row in rows]


async def send_push_notification(
    db: aiosqlite.Connection,
    task_id: str,
    title: str,
    body: str,
) -> bool:
    """Send a push notification to all registered devices.

    Args:
        db: Database connection.
        task_id: Task ID (used as collapse_key and data payload).
        title: Notification title.
        body: Notification body.

    Returns:
        True if at least one notification was sent successfully.
    """
    if not _fcm_initialized:
        return False

    tokens = await get_fcm_tokens(db)
    if not tokens:
        return False

    try:
        from firebase_admin import messaging

        messages = [
            messaging.Message(
                notification=messaging.Notification(title=title, body=body),
                data={"task_id": task_id, "click_action": "FLUTTER_NOTIFICATION_CLICK"},
                android=messaging.AndroidConfig(
                    priority="high",
                    notification=messaging.AndroidNotification(
                        channel_id="vibecode_tasks",
                        click_action="FLUTTER_NOTIFICATION_CLICK",
                    ),
                ),
                token=token,
            )
            for token in tokens
        ]

        # Send in batches of 500 (FCM limit)
        sent = 0
        for i in range(0, len(messages), 500):
            batch = messages[i : i + 500]
            response = messaging.send_each(messages=batch)
            sent += response.success_count

        print(f"[FCM] Sent notifications: {sent}/{len(tokens)} devices")
        return sent > 0

    except Exception as e:
        print(f"[FCM] Failed to send notification: {e}")
        return False
