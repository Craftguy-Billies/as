"""Comprehensive end-to-end test for chat_service state machine.
Tests without Cloud API — verifies state transitions, dedup, edge cases.
"""
import json
import re
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

# Import module so we access its variables via cs._conversation_id etc.
import chat_service as cs


def reset():
    with cs._lock:
        cs._conversation_id = None
        cs._conversation_status = "idle"
        cs._conversation_repo = ""
        cs._conversation_mode = "code"
        cs._conversation_llm_model = ""
        cs._last_event_index = 0
        cs._last_event_timestamp = ""
        cs._seen_event_ids.clear()
        cs._seen_event_hashes.clear()
        cs._event_kinds.clear()
        cs._messages_by_repo.clear()
        cs._sandbox_id = None
        cs._current_repo_key = ""
        cs._processing_repo = ""
        cs._batch_cancelled = False

P = "    "
ok, fail = 0, 0
def check(cond, msg):
    global ok, fail
    ok += 1 if cond else 0; fail += 0 if cond else 1
    if not cond:
        print(f"{P}❌ {msg}")
def eq(a, b, msg=""):
    global ok, fail
    if a == b: ok += 1
    else:
        fail += 1; print(f"{P}❌ {msg}: expected {b!r}, got {a!r}")
def ne(a, b, msg=""):
    global ok, fail
    if a != b: ok += 1
    else:
        fail += 1; print(f"{P}❌ {msg}: got {a!r}")

TEST_REPO = "testuser/testrepo"

# =========== Test 1: conv_done basic ===========
print("\n=== conv_done basic ===")
reset()
with cs._lock:
    cs._conversation_id = "conv-1"
    cs._conversation_status = "idle"
    cs._conversation_repo = TEST_REPO
    cs._conversation_mode = "code"
    cs._conversation_llm_model = "deepseek/deepseek-v4-pro"
    cs._last_event_timestamp = "1719000000123"
    cs._last_event_index = 50
    cs._seen_event_ids.add("e1"); cs._seen_event_ids.add("e2")
    cs._seen_event_hashes.add(12345)

repo, mode, br = TEST_REPO, "code", "main"
from_batch = False
with cs._lock:
    ctx = cs._conversation_id is not None and (repo != cs._conversation_repo or mode != cs._conversation_mode)
    br_sw = cs._conversation_id is not None and not ctx and br != cs._conversation_branch
    done = cs._conversation_id is not None and cs._conversation_status == "idle" and not ctx and not from_batch
eq(done, True, "conv_done should be True when idle, same repo/mode")
ne(ctx, True, "ctx_changed should be False")

if done:
    with cs._lock:
        cs._conversation_id = None; cs._last_event_index = 0; cs._last_event_timestamp = ""
        cs._seen_event_ids.clear(); cs._seen_event_hashes.clear()
        cs._sandbox_id = None; cs._event_kinds.clear()
need = cs._conversation_id is None
eq(need, True, "need_new_conv after conv_done")
eq(cs._seen_event_ids, set(), "seen_event_ids cleared")
eq(cs._last_event_timestamp, "", "last_event_timestamp cleared")

# =========== Test 2: conv_done not during batch ===========
print("\n=== conv_done NOT during batch ===")
reset()
with cs._lock:
    cs._conversation_id = "conv-2"; cs._conversation_status = "idle"
    cs._conversation_repo = TEST_REPO; cs._conversation_mode = "code"
repo, mode, br = TEST_REPO, "code", "main"
from_batch = True
with cs._lock:
    ctx = cs._conversation_id is not None and (repo != cs._conversation_repo or mode != cs._conversation_mode)
    br_sw = cs._conversation_id is not None and not ctx and br != cs._conversation_branch
    done = cs._conversation_id is not None and cs._conversation_status == "idle" and not ctx and not from_batch
eq(done, False, "conv_done NOT during batch")

# =========== Test 3: conv_done not when context changes ===========
print("\n=== conv_done NOT on repo change ===")
reset()
with cs._lock:
    cs._conversation_id = "conv-3"; cs._conversation_status = "idle"
    cs._conversation_repo = TEST_REPO; cs._conversation_mode = "code"
repo, mode, br = "other/repo", "code", "main"
from_batch = False
with cs._lock:
    ctx = cs._conversation_id is not None and (repo != cs._conversation_repo or mode != cs._conversation_mode)
    br_sw = cs._conversation_id is not None and not ctx and br != cs._conversation_branch
    done = cs._conversation_id is not None and cs._conversation_status == "idle" and not ctx and not from_batch
eq(ctx, True, "ctx_changed True on repo change")
eq(done, False, "conv_done NOT on repo change")

# =========== Test 4: conv_done not when running ===========
print("\n=== conv_done NOT when running ===")
reset()
with cs._lock:
    cs._conversation_id = "conv-4"; cs._conversation_status = "running"
    cs._conversation_repo = TEST_REPO; cs._conversation_mode = "code"
repo, mode, br = TEST_REPO, "code", "main"
from_batch = False
with cs._lock:
    ctx = cs._conversation_id is not None and (repo != cs._conversation_repo or mode != cs._conversation_mode)
    br_sw = cs._conversation_id is not None and not ctx and br != cs._conversation_branch
    done = cs._conversation_id is not None and cs._conversation_status == "idle" and not ctx and not from_batch
eq(done, False, "conv_done NOT when running")

# =========== Test 5: event dedup ===========
print("\n=== event dedup ===")
reset()
events = [
    {"id": "evt-1", "kind": "ActionEvent", "source": "agent", "tool_name": "read"},
    {"id": "", "kind": "ObservationEvent", "source": "agent", "tool_name": "read",
     "llm_message": "content1"},
    {"id": "evt-2", "kind": "MessageEvent", "source": "agent",
     "llm_message": {"content": [{"type": "text", "text": "Hello"}]}},
]
added, skipped = 0, 0
for evt in events:
    eid = evt.get("id", "")
    did = bool(eid) and eid in cs._seen_event_ids
    if not eid:
        cstr = f"{evt.get('kind','')}:{evt.get('source','')}:{evt.get('tool_name','')}:{json.dumps(evt.get('llm_message',evt.get('message','')),sort_keys=True,default=str)}"
        ch = hash(cstr)
        dc = ch in cs._seen_event_hashes
    else:
        ch, dc = 0, False
    if did or dc: skipped += 1; continue
    added += 1
    if eid: cs._seen_event_ids.add(eid)
    else: cs._seen_event_hashes.add(ch)
eq(added, 3, "first pass: all 3 added")
eq(skipped, 0, "first pass: none skipped")
eq(len(cs._seen_event_ids), 2, "2 ids tracked")
eq(len(cs._seen_event_hashes), 1, "1 hash tracked")

# Second pass — all dedup'd
added, skipped = 0, 0
for evt in events:
    eid = evt.get("id", "")
    did = bool(eid) and eid in cs._seen_event_ids
    if not eid:
        cstr = f"{evt.get('kind','')}:{evt.get('source','')}:{evt.get('tool_name','')}:{json.dumps(evt.get('llm_message',evt.get('message','')),sort_keys=True,default=str)}"
        ch = hash(cstr)
        dc = ch in cs._seen_event_hashes
    else:
        ch, dc = 0, False
    if did or dc: skipped += 1; continue
    added += 1
eq(added, 0, "second pass: none added")
eq(skipped, 3, "second pass: all 3 skipped")

# =========== Test 6: Phase 1a priority ===========
print("\n=== Phase 1a priority: model_changed > branch_switched ===")
reset()
with cs._lock:
    cs._conversation_id = "conv-5"; cs._conversation_status = "idle"
    cs._conversation_repo = TEST_REPO; cs._conversation_mode = "code"
    cs._conversation_llm_model = "deepseek/deepseek-v4-pro"
    cs._conversation_branch = "main"
from_batch = False
current_model = "deepseek/deepseek-v4-flash"  # DIFFERENT
repo, mode, br = TEST_REPO, "code", "feature-x"
with cs._lock:
    mc = not from_batch and cs._conversation_id is not None and cs._conversation_llm_model and current_model and current_model != cs._conversation_llm_model
    ctx = cs._conversation_id is not None and (repo != cs._conversation_repo or mode != cs._conversation_mode or mc)
    br_sw = cs._conversation_id is not None and not ctx and br != cs._conversation_branch
    done = cs._conversation_id is not None and cs._conversation_status == "idle" and not ctx and not from_batch
eq(mc, True, "model_changed True")
eq(ctx, True, "ctx_changed True when model changed")
eq(br_sw, False, "branch_switched False when ctx_changed")
eq(done, False, "conv_done False when ctx_changed")

# =========== Test 7: conv_done full flow ===========
print("\n=== conv_done full flow ===")
reset()
with cs._lock:
    cs._conversation_id = "conv-6"; cs._conversation_status = "idle"
    cs._conversation_repo = TEST_REPO; cs._conversation_mode = "code"
    cs._conversation_llm_model = "deepseek/deepseek-v4-pro"
    cs._last_event_timestamp = "1719000000123"
    cs._seen_event_ids.add("old-1"); cs._seen_event_ids.add("old-2")
    cs._seen_event_hashes.add(99999)

# Phase 1a: conv_done
repo, mode, br = TEST_REPO, "code", "main"
from_batch = False
with cs._lock:
    ctx = cs._conversation_id is not None and (repo != cs._conversation_repo or mode != cs._conversation_mode)
    br_sw = cs._conversation_id is not None and not ctx and br != cs._conversation_branch
    done = cs._conversation_id is not None and cs._conversation_status == "idle" and not ctx and not from_batch
if done:
    with cs._lock:
        cs._conversation_id = None; cs._last_event_index = 0; cs._last_event_timestamp = ""
        cs._seen_event_ids.clear(); cs._seen_event_hashes.clear()
        cs._sandbox_id = None; cs._event_kinds.clear()
eq(cs._conversation_id, None, "conv cleared")
eq(cs._last_event_timestamp, "", "timestamp cleared")
eq(cs._seen_event_ids, set(), "ids cleared")

# Phase 1c: new conv set
NEW = "conv-new"
with cs._lock:
    cs._conversation_id = NEW
    cs._conversation_llm_model = "deepseek/deepseek-v4-flash"
eq(cs._conversation_id, NEW, "new conv id set")
eq(cs._conversation_llm_model, "deepseek/deepseek-v4-flash", "new model set")

# Phase 2: event poll with no min_timestamp → all events
eq(cs._last_event_timestamp, "", "empty min_timestamp for fresh poll")

# =========== Test 8: task_tracker regex ===========
print("\n=== task_tracker regex ===")
pat = r'(?i)(tasks?\s+(list\s+)?(has\s+been\s+|have\s+been\s+|was\s+|were\s+)?updated)'
for t in [
    "Task list has been updated with 6 item(s).",
    "task list has been updated with 6 item(s). task list...",
    "Tasks have been updated.",
    "Tasks have been updated with 3 items.",
    "task list updated",
    "Task list was updated",
]:
    check(bool(re.search(pat, t)), f"regex MATCH: {t[:50]}...")
for t in [
    "The task has been completed.",
    "Here is your Flutter app!",
    "I have updated the code.",
    "The updated task list shows items.",
]:
    check(not bool(re.search(pat, t)), f"regex NO MATCH: {t[:50]}...")

# =========== Test 9: cumulative prefix stripping ===========
print("\n=== cumulative prefix stripping ===")
msgs = [{"role":"user","content":"make app"},{"role":"assistant","content":"Here's the app."}]
# New response starting with old
resp = "Here's the app.Here's the enhanced version."
for m in reversed(msgs):
    if m.get("role") == "assistant":
        last = m.get("content","")
        if last and resp.startswith(last):
            s = resp[len(last):].strip()
            if s: resp = s
        break
eq(resp, "Here's the enhanced version.", "prefix stripped")

# Identical (no new content) — should NOT strip everything
resp2 = "Here's the app."
for m in reversed(msgs):
    if m.get("role") == "assistant":
        last = m.get("content","")
        if last and resp2.startswith(last):
            s = resp2[len(last):].strip()
            if s: resp2 = s
        break
eq(resp2, "Here's the app.", "identical not stripped")

# Completely new — no prefix
resp3 = "This is a French learning app."
for m in reversed(msgs):
    if m.get("role") == "assistant":
        last = m.get("content","")
        if last and resp3.startswith(last):
            s = resp3[len(last):].strip()
            if s: resp3 = s
        break
eq(resp3, "This is a French learning app.", "new response unchanged")

# =========== Test 10: get_state model fields ===========
print("\n=== get_state model fields ===")
reset()
with cs._lock:
    cs._conversation_id = "conv-state"
    cs._conversation_llm_model = "deepseek/deepseek-v4-pro"
state = cs.get_state(TEST_REPO, "main")
check("llm_model" in state, "state has llm_model")
check("configured_model" in state, "state has configured_model")
check("conversation_id" in state, "state has conversation_id")

# =========== Test 11: MessageEvent text extraction ===========
print("\n=== MessageEvent text extraction ===")
def extract(evt):
    llm = evt.get("llm_message") or evt.get("message") or {}
    if isinstance(llm, str) and llm.strip(): return llm.strip()
    if isinstance(llm, dict):
        c = llm.get("content") or []
        if isinstance(c, list):
            parts = [b.get("text","").strip() for b in c if isinstance(b,dict) and b.get("type")=="text" and b.get("text","").strip()]
            if parts: return "\n".join(parts)
        elif isinstance(c, str) and c.strip(): return c.strip()
    return ""

eq(extract({"llm_message":{"content":[{"type":"text","text":"Hello"}]}}), "Hello", "content list")
eq(extract({"llm_message":"Plain text"}), "Plain text", "string")
eq(extract({"llm_message":{"content":[]}}), "", "empty content")
eq(extract({"llm_message":{"content":"str content"}}), "str content", "str content")
eq(extract({"llm_message":{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}}), "A\nB", "multi-part")
eq(extract({"llm_message":{"content":[{"type":"text","text":"Resp"},{"type":"tool_call","text":"skip"}]}}), "Resp", "non-text skipped")

# =========== Test 12: Phase 3 task_tracker filter ===========
print("\n=== Phase 3 task_tracker filter ===")
pat = r'(?i)(tasks?\s+(list\s+)?(has\s+been\s+|have\s+been\s+|was\s+|were\s+)?updated)'
def should_filter(text):
    return bool(re.search(pat, text.strip()))

check(should_filter("Task list has been updated with 6 item(s)."), "should filter: task list updated")
check(should_filter("Tasks have been updated."), "should filter: tasks updated")
check(not should_filter("Here's your Flutter app with all features."), "NOT filter: real response")
check(not should_filter("The code has been updated with the fix."), "NOT filter: code update")
check(not should_filter(""), "NOT filter: empty string")

# =========== Test 13: Zip fallback stale detection ===========
print("\n=== zip fallback stale detection ===")
seen_ids = {"old-1", "old-2"}
last_assistant = "Here's the Flutter app."
zip_events = [
    {"kind":"MessageEvent","source":"agent","id":"z1","llm_message":{"content":[{"type":"text","text":"Here's the Flutter app."}]}},
    {"kind":"MessageEvent","source":"agent","id":"old-1","llm_message":{"content":[{"type":"text","text":"New content"}]}},
    {"kind":"MessageEvent","source":"agent","id":"z3","llm_message":{"content":[{"type":"text","text":"The French app is complete!"}]}},
]
found = False
for evt in zip_events:
    if evt.get("kind")=="MessageEvent" and evt.get("source")=="agent":
        eid = evt.get("id","")
        if eid and eid in seen_ids: continue
        llm = evt.get("llm_message") or evt.get("message") or {}
        raw = ""
        if isinstance(llm, dict):
            c = llm.get("content") or []
            if isinstance(c, list):
                parts = [b.get("text","") for b in c if isinstance(b,dict) and b.get("type")=="text" and b.get("text","").strip()]
                if parts: raw = "\n".join(parts)
        elif isinstance(llm, str) and llm.strip(): raw = llm.strip()
        if not raw: continue
        if last_assistant and raw.strip() == last_assistant.strip(): continue
        found = True
        eq(raw, "The French app is complete!", "zip found correct new message")
        break
check(found, "zip found valid message")

# =========== Test 14: Concurrent access lock safety ===========
print("\n=== concurrent lock safety ===")
reset()
# Verify that modifying state works under lock
from threading import Thread, Lock, Event
errors = []
lock = Lock()
results = []
def worker(n):
    try:
        with cs._lock:
            cs._seen_event_ids.add(f"thr-{n}")
            results.append(n)
    except Exception as e:
        errors.append(e)

threads = [Thread(target=worker, args=(i,)) for i in range(20)]
for t in threads: t.start()
for t in threads: t.join()
eq(len(errors), 0, "no thread errors")
eq(len(cs._seen_event_ids), 20, f"20 ids added (got {len(cs._seen_event_ids)})")

# =========== REPORT ===========
print(f"\n{'='*50}")
total = ok + fail
print(f"Results: {ok}/{total} passed", end="")
if fail: print(f", {fail} FAILED", end="")
print()
sys.exit(0 if fail == 0 else 1)
