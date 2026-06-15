"""Pydantic models for VibeCode API."""

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


class PromptRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=10000)
    repo: str = Field(..., min_length=1, pattern=r"^[\w.-]+/[\w.-]+$")
    branch: str = Field(default="main")
    mode: str = Field(default="code", pattern=r"^(code|plan)$")


class LLMConfigRequest(BaseModel):
    api_key: str = Field(..., min_length=1)
    model: str = Field(..., min_length=1)
    base_url: Optional[str] = None


class FCMTokenRequest(BaseModel):
    token: str = Field(..., min_length=1)


class TaskResponse(BaseModel):
    id: str
    prompt: str
    repo: str
    branch: str
    mode: str
    status: str
    conversation_id: Optional[str] = None
    sandbox_id: Optional[str] = None
    created_at: str
    completed_at: Optional[str] = None
    error_message: Optional[str] = None


class EventResponse(BaseModel):
    id: int
    task_id: str
    event_index: int
    timestamp: str
    kind: str
    source: Optional[str] = None
    tool_name: Optional[str] = None
    action_json: Optional[str] = None
    observation_json: Optional[str] = None
    message_json: Optional[str] = None


class HealthResponse(BaseModel):
    status: str
    model: str
    version: str = "1.0.0"


class TasksListResponse(BaseModel):
    tasks: list[TaskResponse]


class EventsListResponse(BaseModel):
    events: list[EventResponse]
    has_more: bool
    task_status: str
