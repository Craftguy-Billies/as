#!/usr/bin/env bash
# ==============================================================================
# VibeCode Test Controller — Comprehensive Backend Test Suite
# ==============================================================================
# Usage: ./test_controller.sh [--url WORKER_URL] [--repo OWNER/REPO] [--monitor]
#
# This script provides terminal-level "vision" into the app by exercising
# every API endpoint and verifying queue behavior, conversation management,
# message ordering, and error recovery.
#
# Modes:
#   --monitor     Continuous monitoring: polls state every 2s, shows live queue
#   --test        Run the full test suite (default)
#   --stress      Stress test: rapid concurrent sends to test race conditions
# ==============================================================================

set -euo pipefail

# --- Configuration ---
BASE_URL="${VIBECODE_URL:-http://localhost:8787}"
TEST_REPO="${VIBECODE_REPO:-Craftguy-Billies/search}"
TEST_BRANCH="${VIBECODE_BRANCH:-main}"
MODE="test"
MONITOR_INTERVAL=2

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'

pass=0
fail=0

ok()   { echo -e "  ${GREEN}✓${NC} $1"; ((pass++)); }
failf() { echo -e "  ${RED}✗${NC} $1"; ((fail++)); }
info() { echo -e "${BLUE}ℹ${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }
sub()   { echo -e "${MAGENTA}  ▶ $1${NC}"; }

# --- Helpers ---
api() {
  local method="$1" path="$2" body="${3:-}"
  local opts=(-s -w "\n%{http_code}" -X "$method" "${BASE_URL}${path}")
  opts+=(-H "Content-Type: application/json")
  if [ -n "$body" ]; then opts+=(-d "$body"); fi
  curl "${opts[@]}" 2>/dev/null
}

api_json() {
  local resp
  resp=$(api "$@") || true
  local http_code
  http_code=$(echo "$resp" | tail -1)
  local json
  json=$(echo "$resp" | sed '$d')
  echo "$json"
  return 0
}

get()  { api_json GET "$1"; }
post() { api_json POST "$1" "$2"; }
put()  { api_json PUT "$1" "$2"; }
del()  { api_json DELETE "$1"; }

# Extract field from JSON (simple grep, no jq dependency in CF workers)
json_field() {
  local json="$1" field="$2"
  echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    parts = '$field'.split('.')
    for p in parts:
        if isinstance(d, dict):
            d = d.get(p, '')
        else:
            d = ''
    if isinstance(d, bool):
        print('true' if d else 'false')
    elif d is None:
        print('null')
    else:
        print(d)
except:
    print('PARSE_ERROR')
" 2>/dev/null
}

# --- Test helpers ---
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$label: '$expected'"
  else
    failf "$label: expected='$expected' got='$actual'"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    ok "$label: contains '$needle'"
  else
    failf "$label: does NOT contain '$needle'"
  fi
}

assert_gt() {
  local label="$1" actual="$2" threshold="$3"
  if [ "$actual" -gt "$threshold" ]; then
    ok "$label: $actual > $threshold"
  else
    failf "$label: $actual <= $threshold"
  fi
}

# ==============================================================================
# Test Suite
# ==============================================================================

test_health() {
  header "HEALTH CHECK"
  local resp
  resp=$(get "/api/health")
  local status
  status=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  if [ "$status" = "ok" ]; then
    ok "Health endpoint: ok"
  else
    failf "Health endpoint: FAILED (resp=$resp)"
  fi
}

test_clear_queue() {
  header "CLEAR QUEUE (ensure clean state)"
  local resp
  resp=$(post "/api/chat/cancel?repo=${TEST_REPO}" '{}')
  info "Cleared queue for $TEST_REPO"
  # Also clear via new-conversation
  post "/api/chat/new-conversation?repo=${TEST_REPO}" '{}' >/dev/null 2>&1 || true
  info "Reset conversation for $TEST_REPO"
}

test_queue_single() {
  header "QUEUE SINGLE MESSAGE"
  sub "Sending: 'Make a simple TODO app'"
  local resp
  resp=$(post "/api/chat/batch" "{\"prompts\":[\"Make a simple TODO app\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}")
  info "Response: $resp"
  local status
  status=$(json_field "$resp" "status")
  assert_eq "Batch status" "queued" "$status"

  local total
  total=$(json_field "$resp" "total")
  assert_eq "Queue total" "1" "$total"

  local position
  position=$(json_field "$resp" "position")
  assert_eq "Queue position" "0" "$position"
}

test_queue_multiple_sequential() {
  header "QUEUE MULTIPLE MESSAGES (SEQUENTIAL)"
  sub "Sending 3 messages one by one"

  # First message — should create new batch
  local r1
  r1=$(post "/api/chat/batch" "{\"prompts\":[\"Task 1: Add login page\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}")
  local s1
  s1=$(json_field "$r1" "status")
  assert_eq "Msg1 status" "queued" "$s1"
  local t1
  t1=$(json_field "$r1" "total")
  assert_eq "Msg1 total" "1" "$t1"

  # Second message — should append to batch
  local r2
  r2=$(post "/api/chat/batch" "{\"prompts\":[\"Task 2: Add dashboard\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}")
  local s2
  s2=$(json_field "$r2" "status")
  assert_eq "Msg2 status" "queued" "$s2"
  local t2
  t2=$(json_field "$r2" "total")
  assert_eq "Msg2 total" "2" "$t2"

  # Third message — should append again
  local r3
  r3=$(post "/api/chat/batch" "{\"prompts\":[\"Task 3: Add settings\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}")
  local s3
  s3=$(json_field "$r3" "status")
  assert_eq "Msg3 status" "queued" "$s3"
  local t3
  t3=$(json_field "$r3" "total")
  assert_eq "Msg3 total" "3" "$t3"

  info "All 3 messages queued. Queue should process in order: 1→2→3"
}

test_queue_batch_send() {
  header "QUEUE BATCH SEND (MULTIPLE PROMPTS)"
  sub "Sending 2 prompts in single batch request"
  local resp
  resp=$(post "/api/chat/batch" "{\"prompts\":[\"Create README\",\"Add CI config\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}")
  local status
  status=$(json_field "$resp" "status")
  assert_eq "Batch status" "queued" "$status"
  local total
  total=$(json_field "$resp" "total")
  assert_eq "Batch total" "2" "$total"
}

test_get_state() {
  header "GET STATE (POLL)"
  local resp
  resp=$(get "/api/chat?repo=${TEST_REPO}&mode=code")
  info "State response length: ${#resp} chars"

  local msgs_count
  msgs_count=$(echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('messages', [])))
" 2>/dev/null || echo "PARSE_ERROR")
  info "Messages in state: $msgs_count"

  local batch_running
  batch_running=$(json_field "$resp" "batch.running")
  local batch_pos
  batch_pos=$(json_field "$resp" "batch.position")
  local batch_total
  batch_total=$(json_field "$resp" "batch.total")
  local batch_done
  batch_done=$(json_field "$resp" "batch.done")
  info "Batch: running=$batch_running pos=$batch_pos total=$batch_total done=$batch_done"

  local conv_id
  conv_id=$(json_field "$resp" "conversation_id")
  local conv_status
  conv_status=$(json_field "$resp" "conversation_status")
  info "Conversation: id=${conv_id:0:12}... status=$conv_status"

  # Validate response structure
  assert_contains "Has messages field" "$resp" '"messages"'
  assert_contains "Has batch field" "$resp" '"batch"'
}

test_cancel_current() {
  header "CANCEL CURRENT PROMPT"
  sub "Cancelling prompt at position 0"
  local resp
  resp=$(post "/api/chat/batch/cancel/0?repo=${TEST_REPO}" '{}')
  local ok_val
  ok_val=$(json_field "$resp" "ok")
  assert_eq "Cancel response" "True" "$ok_val"
  info "Cancelled prompt at position 0"
}

test_cancel_all() {
  header "CANCEL ALL PROMPTS"
  sub "Cancelling entire batch"
  local resp
  resp=$(post "/api/chat/batch/cancel?repo=${TEST_REPO}" '{}')
  local ok_val
  ok_val=$(json_field "$resp" "ok")
  assert_eq "Cancel all response" "True" "$ok_val"
  info "Cancelled all prompts in queue"
}

test_new_conversation() {
  header "NEW CONVERSATION"
  local before
  before=$(get "/api/chat?repo=${TEST_REPO}&mode=code")
  local before_conv
  before_conv=$(json_field "$before" "conversation_id")

  local resp
  resp=$(post "/api/chat/new-conversation?repo=${TEST_REPO}" '{}')
  info "New conversation response: $resp"

  local after
  after=$(get "/api/chat?repo=${TEST_REPO}&mode=code")
  local after_conv
  after_conv=$(json_field "$after" "conversation_id")

  if [ "$before_conv" != "$after_conv" ] || [ "$after_conv" = "null" ] || [ -z "$after_conv" ]; then
    ok "Conversation ID changed (new conversation created)"
  else
    info "Conversation ID unchanged (was already null)"
  fi
}

test_conversation_change_notification() {
  header "CONVERSATION CHANGE NOTIFICATION"
  local resp
  resp=$(get "/api/chat?repo=${TEST_REPO}&mode=code")
  local conv_change
  conv_change=$(json_field "$resp" "conversation_change")
  if [ "$conv_change" != "null" ] && [ -n "$conv_change" ]; then
    local reason
    reason=$(json_field "$resp" "conversation_change.reason")
    info "Last conversation change reason: $reason"
  else
    info "No active conversation change (or already acknowledged)"
  fi
}

test_multi_repo() {
  header "MULTI-REPO QUEUE ISOLATION"
  local REPO_A="Craftguy-Billies/search"
  local REPO_B="Craftguy-Billies/test-app"

  sub "Queue message on repo A"
  local ra
  ra=$(post "/api/chat/batch" "{\"prompts\":[\"Repo A task\"],\"repo\":\"${REPO_A}\",\"branch\":\"main\",\"mode\":\"code\"}")
  local ta
  ta=$(json_field "$ra" "total")
  assert_eq "Repo A total" "1" "$ta"

  sub "Queue message on repo B"
  local rb
  rb=$(post "/api/chat/batch" "{\"prompts\":[\"Repo B task\"],\"repo\":\"${REPO_B}\",\"branch\":\"main\",\"mode\":\"code\"}")
  local tb
  tb=$(json_field "$rb" "total")
  assert_eq "Repo B total" "1" "$tb"

  sub "Verify repo A state"
  local sa
  sa=$(get "/api/chat?repo=${REPO_A}&mode=code")
  local ta2
  ta2=$(json_field "$sa" "batch.total")
  assert_eq "Repo A batch total unchanged" "1" "$ta2"

  sub "Verify repo B state"
  local sb
  sb=$(get "/api/chat?repo=${REPO_B}&mode=code")
  local tb2
  tb2=$(json_field "$sb" "batch.total")
  assert_eq "Repo B batch total" "1" "$tb2"

  # Cleanup
  post "/api/chat/cancel?repo=${REPO_A}" '{}' >/dev/null 2>&1 || true
  post "/api/chat/cancel?repo=${REPO_B}" '{}' >/dev/null 2>&1 || true
}

test_duplicate_detection() {
  header "DUPLICATE MESSAGE DETECTION"
  sub "Sending same prompt twice in rapid succession (race condition test)"
  local PROMPT="Test duplicate $(date +%s%N)"

  # Fire both at nearly the same time
  local r1 r2
  r1=$(post "/api/chat/batch" "{\"prompts\":[\"${PROMPT}\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}" &)
  r2=$(post "/api/chat/batch" "{\"prompts\":[\"${PROMPT}\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}" &)
  wait

  # Check state - should have 2 prompts (both queued)
  local state
  state=$(get "/api/chat?repo=${TEST_REPO}&mode=code")
  local total
  total=$(json_field "$state" "batch.total")
  if [ "$total" = "2" ]; then
    ok "Both duplicate prompts queued (no loss)"
  elif [ "$total" = "1" ]; then
    warn "Only 1 prompt queued — KV race condition may have swallowed one"
  else
    failf "Unexpected queue total: $total"
  fi
}

test_queue_persistence() {
  header "QUEUE PERSISTENCE ACROSS REQUESTS"
  sub "Queue a message, then poll multiple times to verify it persists"

  local PROMPT="Persistence test $(date +%s)"
  local r
  r=$(post "/api/chat/batch" "{\"prompts\":[\"${PROMPT}\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}")
  local total
  total=$(json_field "$r" "total")

  # Poll 3 times
  local consistent=true
  for i in 1 2 3; do
    sleep 1
    local s
    s=$(get "/api/chat?repo=${TEST_REPO}&mode=code")
    local t
    t=$(json_field "$s" "batch.total")
    if [ "$t" != "$total" ]; then
      consistent=false
      warn "Poll $i: total=$t (expected=$total) — inconsistent!"
    else
      info "Poll $i: total=$t — consistent"
    fi
  done

  if $consistent; then
    ok "Queue state persisted across 3 polls"
  else
    failf "Queue state inconsistent across polls"
  fi
}

test_message_order() {
  header "MESSAGE ORDER VERIFICATION"
  sub "Verify queued messages maintain FIFO order"

  # First clear the queue
  post "/api/chat/cancel?repo=${TEST_REPO}" '{}' >/dev/null 2>&1 || true
  sleep 1

  # Queue 3 distinct messages
  post "/api/chat/batch" "{\"prompts\":[\"First message\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}" >/dev/null 2>&1
  sleep 0.5
  post "/api/chat/batch" "{\"prompts\":[\"Second message\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}" >/dev/null 2>&1
  sleep 0.5
  post "/api/chat/batch" "{\"prompts\":[\"Third message\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}" >/dev/null 2>&1

  local state
  state=$(get "/api/chat?repo=${TEST_REPO}&mode=code")
  local prompts
  prompts=$(echo "$state" | python3 -c "
import sys, json
d = json.load(sys.stdin)
batch = d.get('batch', {})
prompts = batch.get('prompts', [])
for i, p in enumerate(prompts):
    print(f'{i}:{p}')
" 2>/dev/null || echo "")

  info "Queue order:"
  echo "$prompts" | while read line; do info "  $line"; done

  local first=$(echo "$prompts" | grep "0:" | grep -c "First")
  local second=$(echo "$prompts" | grep "1:" | grep -c "Second")
  local third=$(echo "$prompts" | grep "2:" | grep -c "Third")

  if [ "$first" = "1" ] && [ "$second" = "1" ] && [ "$third" = "1" ]; then
    ok "Messages maintain FIFO order (First→Second→Third)"
  else
    failf "Message order is NOT FIFO"
  fi
}

# ==============================================================================
# Continuous Monitor Mode
# ==============================================================================

monitor() {
  header "CONTINUOUS MONITOR — Ctrl+C to stop"
  echo -e "${GRAY}Polling ${BASE_URL}/api/chat?repo=${TEST_REPO} every ${MONITOR_INTERVAL}s${NC}\n"

  local last_conv_id=""
  local last_pos=-1

  while true; do
    local ts
    ts=$(date "+%H:%M:%S")
    local resp
    resp=$(get "/api/chat?repo=${TEST_REPO}&mode=code") || {
      echo -e "${RED}[${ts}] POLL FAILED${NC}"
      sleep "$MONITOR_INTERVAL"
      continue
    }

    local batch_total batch_pos batch_done batch_running
    batch_total=$(json_field "$resp" "batch.total")
    batch_pos=$(json_field "$resp" "batch.position")
    batch_done=$(json_field "$resp" "batch.done")
    batch_running=$(json_field "$resp" "batch.running")

    local conv_id conv_status
    conv_id=$(json_field "$resp" "conversation_id")
    conv_id_short="${conv_id:0:12}"
    conv_status=$(json_field "$resp" "conversation_status")

    local msgs_count
    msgs_count=$(echo "$resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('messages',[])))" 2>/dev/null || echo "?")

    # Detect conversation changes
    if [ "$conv_id" != "$last_conv_id" ] && [ -n "$conv_id" ] && [ "$conv_id" != "null" ]; then
      local reason
      reason=$(json_field "$resp" "conversation_change.reason")
      echo -e "${MAGENTA}[${ts}] 🔄 NEW CONVERSATION: ${conv_id_short}... reason='${reason}'${NC}"
    fi
    last_conv_id="$conv_id"

    # Detect queue progress
    local progress=""
    if [ "$batch_pos" != "$last_pos" ] && [ "$batch_total" != "0" ]; then
      progress=" ${GREEN}← advanced!${NC}"
    fi
    last_pos="$batch_pos"

    # Status color
    local status_color="$GRAY"
    if [ "$batch_running" = "true" ]; then status_color="$YELLOW"; fi
    if [ "$conv_status" = "completed" ]; then status_color="$GREEN"; fi
    if [ "$conv_status" = "error" ]; then status_color="$RED"; fi

    printf "${status_color}[%s] batch=%s/%s/%s running=%s conv=%s status=%s msgs=%s${NC}%s\n" \
      "$ts" "$batch_pos" "$batch_done" "$batch_total" "$batch_running" \
      "${conv_id_short:-none}" "$conv_status" "$msgs_count" "$progress"

    sleep "$MONITOR_INTERVAL"
  done
}

# ==============================================================================
# Stress Test Mode
# ==============================================================================

stress_test() {
  header "STRESS TEST — RAPID CONCURRENT SENDS"
  local NUM_SENDS=10
  info "Sending $NUM_SENDS messages concurrently..."

  # Clear first
  post "/api/chat/cancel?repo=${TEST_REPO}" '{}' >/dev/null 2>&1 || true
  sleep 1

  for i in $(seq 1 $NUM_SENDS); do
    post "/api/chat/batch" "{\"prompts\":[\"Stress test $i\"],\"repo\":\"${TEST_REPO}\",\"branch\":\"${TEST_BRANCH}\",\"mode\":\"code\"}" >/dev/null 2>&1 &
  done
  wait

  sleep 2

  local state
  state=$(get "/api/chat?repo=${TEST_REPO}&mode=code")
  local total
  total=$(json_field "$state" "batch.total")

  if [ "$total" = "$NUM_SENDS" ]; then
    ok "Stress test: all $NUM_SENDS messages queued (total=$total)"
  else
    failf "Stress test: expected $NUM_SENDS, got $total (some messages lost to race conditions)"
  fi

  # Check no duplicate conversation creation
  local conv_id
  conv_id=$(json_field "$state" "conversation_id")
  info "Conversation ID: ${conv_id:0:12}... (should be exactly one per batch)"
}

# ==============================================================================
# Full Test Suite
# ==============================================================================

run_full_suite() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║        VibeCode Backend — Comprehensive Test Suite       ║"
  echo "║        URL: ${BASE_URL}                       ║"
  echo "║        Repo: ${TEST_REPO}                              ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  test_health
  test_clear_queue
  test_queue_single
  test_get_state
  test_queue_multiple_sequential
  test_get_state
  test_message_order
  test_queue_batch_send
  test_queue_persistence
  test_duplicate_detection
  test_multi_repo
  test_new_conversation
  test_conversation_change_notification
  test_cancel_current
  test_cancel_all
  test_clear_queue

  # --- Summary ---
  echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}RESULTS: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}, $((pass + fail)) total"
  if [ "$fail" -gt 0 ]; then
    echo -e "${RED}⚠ SOME TESTS FAILED — review output above${NC}"
    exit 1
  else
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    exit 0
  fi
}

# ==============================================================================
# Usage & Arg Parsing
# ==============================================================================

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --url URL        Backend worker URL (default: $BASE_URL)"
  echo "  --repo OWNER/REPO  Repository to test with (default: $TEST_REPO)"
  echo "  --monitor         Continuous monitoring mode (Ctrl+C to stop)"
  echo "  --stress          Stress test mode"
  echo "  --test            Run full test suite (default)"
  echo "  --clear           Just clear the queue"
  echo "  --help            Show this help"
  echo ""
  echo "Environment variables:"
  echo "  VIBECODE_URL     Backend worker URL"
  echo "  VIBECODE_REPO    Repository to test with"
  echo ""
  echo "Examples:"
  echo "  $0 --url https://vibecode-proxy.username.workers.dev --monitor"
  echo "  $0 --url http://localhost:8787 --test"
  echo "  $0 --stress"
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --url) BASE_URL="$2"; shift 2 ;;
    --repo) TEST_REPO="$2"; shift 2 ;;
    --monitor) MODE="monitor"; shift ;;
    --stress) MODE="stress"; shift ;;
    --test) MODE="test"; shift ;;
    --clear) MODE="clear"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Encode repo for URL
TEST_REPO_ENCODED=$(echo "$TEST_REPO" | python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null || echo "$TEST_REPO")

case "$MODE" in
  monitor) monitor ;;
  stress) stress_test ;;
  clear) test_clear_queue ;;
  test) run_full_suite ;;
  *) run_full_suite ;;
esac
