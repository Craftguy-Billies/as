/**
 * VibeCode Cloudflare Worker
 *
 * Async orchestration: POST /api/chat/batch returns immediately,
 * GET /api/chat polls Cloud API status. The Flutter provider already
 * uses batch exclusively (not blocking POST /api/chat).
 *
 * State is stored in KV (key = "state:{repo}").
 *
 * Architecture:
 *   /batch  → stores prompt in KV queue, returns immediately
 *   /state  → creates Cloud conv if needed, polls status, returns messages
 *   (each /state call is quick — under 30s wall clock)
 *
 * Conversation creation sends prompt as initial_message.
 * Follow-up prompts reuse conversation via send-message.
 */

const CLOUD_API = 'https://app.all-hands.dev';
const GH_API = 'https://api.github.com';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
};

function simpleHash(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = ((h << 5) - h) + s.charCodeAt(i);
    h |= 0;
  }
  return 'h' + h;
}

function safeStr(v, maxLen) {
  if (v == null) return '';
  if (typeof v === 'string') return v.slice(0, maxLen || 200);
  if (typeof v === 'object') {
    try { return JSON.stringify(v).slice(0, maxLen || 200); } catch { return String(v).slice(0, maxLen || 200); }
  }
  return String(v).slice(0, maxLen || 200);
}

async function cloudHeaders(env) {
  let key = env.OPENHANDS_CLOUD_API_KEY || '';
  if (!key) {
    try {
      const raw = await env.VIBECODE.get('config:llm');
      if (raw) {
        const cfg = JSON.parse(raw);
        key = cfg.api_key || '';
      }
    } catch (_) {}
  }
  return { 'Authorization': `Bearer ${key}`, 'Content-Type': 'application/json', 'Accept': 'application/json' };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json', ...CORS } });
}

function error(msg, status = 400) {
  return json({ error: msg }, status);
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const now = () => Date.now();

// ---------------------------------------------------------------------------
// KV state helpers
// ---------------------------------------------------------------------------

async function readState(env, repo) {
  const raw = await env.VIBECODE.get(`state:${repo}`);
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

async function writeState(env, repo, state) {
  // Trim state before writing to KV to stay under limits.
  if (state.messages && state.messages.length > 500) {
    state.messages = state.messages.slice(-400);
  }
  if (state.event_kinds && Object.keys(state.event_kinds).length > 1000) {
    state.event_kinds = {};
  }
  if (state._extracted_hashes && Object.keys(state._extracted_hashes).length > 100) {
    state._extracted_hashes = {};
  }
  if (state.seen_event_ids && state.seen_event_ids.length > 2000) {
    state.seen_event_ids = state.seen_event_ids.slice(-1500);
  }
  if (state._batch_skip && Object.keys(state._batch_skip).length > 100) {
    state._batch_skip = undefined;
  }
  try {
    await env.VIBECODE.put(`state:${repo}`, JSON.stringify(state));
  } catch (_) {
    // KV write limit exceeded — worker stays functional in-memory, next poll retries.
  }
}

function buildStateResponse(state, q, hasPending, repo, mode, convStatus) {
  // Dedup messages: skip consecutive event messages with identical content
  // (cold start can reprocess events, creating duplicates in memory)
  const msgs = state.messages || [];
  const messages = [];
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i];
    if (m.role === 'event' && i > 0) {
      const prev = msgs[i - 1];
      if (prev.role === 'event' && prev.content === m.content) continue;
    }
    messages.push(m);
  }
  return json({
    messages,
    conversation_id: state.conversation_id,
    sandbox_id: state.sandbox_id || null,
    repo,
    branch: state.branch || '',
    mode: state.mode || mode || 'code',
    current_repo_key: repo,
    conversation_status: convStatus,
    llm_model: state.llm_model || '',
    configured_model: state.configured_model || '',
    run_started_at: state._run_started_at || null,
    batch: {
      running: hasPending && !!state.conversation_id,
      cancelled: !!q.cancelled,
      position: q.position || 0,
      total: q.total || 0,
      done: q.done || 0,
      repo,
      prompts: q.prompts || [],
      modes: q.modes || [],
    },
  });
}

function nextMsgId(state) {
  let max = 0;
  if (state.messages) {
    for (const m of state.messages) {
      if (m.id && m.id > max) max = m.id;
    }
  }
  return max + 1;
}

// ---------------------------------------------------------------------------
// Cloud API calls
// ---------------------------------------------------------------------------

// Interactive Cloud API calls: 30s safety timeout (fail fast if API is down).
// ZIP download: no timeout (I/O wait doesn't count toward CF CPU limit).
const CLOUD_API_TIMEOUT = 30000;

async function fetchWithTimeout(url, opts = {}, timeout = CLOUD_API_TIMEOUT) {
  if (timeout <= 0) return fetch(url, opts);
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeout);
  try {
    return await fetch(url, { ...opts, signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function cloudGet(env, path) {
  const resp = await fetchWithTimeout(`${CLOUD_API}${path}`, { headers: await cloudHeaders(env) });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`${resp.status}:${text.slice(0, 200)}`);
  }
  return resp.json();
}

async function cloudPost(env, path, body) {
  const resp = await fetchWithTimeout(`${CLOUD_API}${path}`, {
    method: 'POST',
    headers: await cloudHeaders(env),
    body: JSON.stringify(body),
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`${resp.status}:${text.slice(0, 200)}`);
  }
  return resp.json();
}

// ---------------------------------------------------------------------------
// Config (KV)
// ---------------------------------------------------------------------------

async function readConfig(env) {
  const raw = await env.VIBECODE.get('config:llm');
  if (raw) {
    try { return JSON.parse(raw); } catch {}
  }
  return { model: env.LLM_MODEL || 'deepseek/deepseek-v4-flash', api_key: env.LLM_API_KEY || '' };
}

async function writeConfig(env, cfg) {
  await env.VIBECODE.put('config:llm', JSON.stringify(cfg));
}

// ---------------------------------------------------------------------------
// GitHub API
// ---------------------------------------------------------------------------

async function getBranches(repo) {
  try {
    const resp = await fetch(`${GH_API}/repos/${repo}/branches?per_page=100`, {
      headers: { 'Accept': 'application/vnd.github.v3+json', 'User-Agent': 'vibecode-worker' },
    });
    if (!resp.ok) return [];
    const data = await resp.json();
    return (Array.isArray(data) ? data : []).map(b => b.name);
  } catch { return []; }
}

async function getDefaultBranch(repo) {
  try {
    const resp = await fetch(`${GH_API}/repos/${repo}`, {
      headers: { 'Accept': 'application/vnd.github.v3+json', 'User-Agent': 'vibecode-worker' },
    });
    if (!resp.ok) return '';
    const data = await resp.json();
    return data.default_branch || 'main';
  } catch { return ''; }
}

// ---------------------------------------------------------------------------
// Cloud conversation create (with initial_message)
// ---------------------------------------------------------------------------

async function createConversation(env, prompt, repo, branch, mode) {
  // Build prompt with repo context (matching chat_service.py)
  let fullPrompt = prompt;
  const effectiveBranch = branch || (repo ? (await getDefaultBranch(repo)) : '') || 'main';
  if (mode === 'plan' && repo) {
    fullPrompt =
      `Repository: ${repo} (branch: ${effectiveBranch}).\n` +
      `IMPORTANT — PLAN MODE:\n` +
      `1. FIRST, analyze the task and research the codebase. Read files, search, ` +
      `understand the architecture. Create a detailed implementation plan saved ` +
      `to .agents_tmp/PLAN.md. Do NOT implement anything yet.\n` +
      `2. After creating the plan, present your findings and ask ` +
      `whether to proceed with implementation.\n` +
      `3. You are in READ-ONLY mode. Do NOT edit, create, or delete any files ` +
      `other than .agents_tmp/PLAN.md. Do NOT run git commit or git push.\n` +
      `IMPORTANT: Stop after EXPLORATION + ANALYSIS.\n\n` +
      `[SANDBOX] REPO RESTRICTION: You are confined to repository \`${repo}\`. ` +
      `Switch branches freely, but NEVER touch any other repo.\n\n` +
      `Task: ${prompt}`;
  } else if (repo) {
    fullPrompt =
      `Repository: ${repo} (branch: ${effectiveBranch}).\n` +
      `IMPORTANT: First run \`git pull\` to get the latest code. ` +
      `The repo's .git directory is NOT at /workspace directly — it's in ` +
      `a subdirectory like /workspace/project/<name>/. ` +
      `Run \`cd /workspace && ls\` to find it, then cd into the right dir ` +
      `and run \`git pull origin ${effectiveBranch}\`.\n` +
      `Read the user's message below and implement what it asks. ` +
      `Make edits, commit with a descriptive message, and push.\n\n` +
      `[SANDBOX] REPO RESTRICTION: You are confined to repository \`${repo}\`. ` +
      `You may switch branches within it freely, but you MUST NOT ` +
      `clone, fetch, push to, or interact with any other repository. ` +
      `All file edits, git operations, and commits must stay within ` +
      `\`${repo}\`.\n\n` +
      `${prompt}`;
  } else if (mode === 'plan') {
    fullPrompt =
      `IMPORTANT — PLAN MODE:\n` +
      `1. FIRST, analyze the request. Research, think through the problem, ` +
      `and create a detailed plan saved to .agents_tmp/PLAN.md. ` +
      `Do NOT implement anything.\n` +
      `2. After creating the plan, present it to the user and ask ` +
      `whether to proceed.\n` +
      `3. READ-ONLY: Do NOT edit, create, or delete any files ` +
      `other than .agents_tmp/PLAN.md.\n\n` +
      `Task: ${prompt}`;
  }

  const cfg = await readConfig(env);
  const body = {
    initial_message: { content: [{ type: 'text', text: fullPrompt }] },
    title: prompt.slice(0, 80),
    llm_model: cfg.model || env.LLM_MODEL || 'deepseek/deepseek-v4-flash',
  };
  if (repo) {
    body.selected_repository = repo;
    body.selected_branch = effectiveBranch;
  }

  // Add MCP servers (matching agent_runner.py _build_default_mcp_config):
  // 1. Web fetch (mcp-server-fetch): gated behind VIBECODE_ENABLE_FETCH env var
  // 2. Tavily search: if TAVILY_API_KEY env var is set
  const mcpServers = [];
  if (env.VIBECODE_ENABLE_FETCH !== '0') {
    mcpServers.push({ name: 'fetch', command: 'uvx', args: ['mcp-server-fetch'] });
  }
  const tavilyKey = env.TAVILY_API_KEY || '';
  if (tavilyKey) {
    mcpServers.push({ name: 'tavily', command: 'uvx', args: ['tavily-mcp'], env: { TAVILY_API_KEY: tavilyKey } });
  }
  if (mcpServers.length) {
    body.mcp_servers = mcpServers;
  }

  // Add git config if user configured it
  try {
    const raw = await env.VIBECODE.get('config:git');
    if (raw) {
      const git = JSON.parse(raw);
      if (git.name && git.email) {
        body.git_config = { name: git.name, email: git.email };
      }
    }
  } catch (_) {}

  const resp = await fetchWithTimeout(`${CLOUD_API}/api/v1/app-conversations`, {
    method: 'POST',
    headers: await cloudHeaders(env),
    body: JSON.stringify(body),
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`Create conv failed: ${resp.status}:${text.slice(0, 200)}`);
  }
  const data = await resp.json();

  // Match agent_runner.py exactly: 'app_conversation_id' is the real conversation ID.
  // 'id' is the START TASK ID — never use it as a conversation_id.
  const directId = data.app_conversation_id || data.conversation_id || '';
  const taskId = data.id || data.start_task_id || '';
  const sboxId = data.sandbox_id || '';
  return {
    conversation_id: directId,
    start_task_id: taskId,
    sandbox_id: sboxId,
  };
}

// ---------------------------------------------------------------------------
// Poll start-task endpoint for real conversation_id
// ---------------------------------------------------------------------------

async function pollForConvId(env, startTaskId) {
  // Single attempt — retried across polls via stateful counter
  await sleep(5000);
  try {
    const data = await cloudGet(env, `/api/v1/app-conversations/start-tasks?ids=${startTaskId}`);
    const items = Array.isArray(data) ? data : (data.items || []);
    if (items.length) {
      const item = items[0];
      // app_conversation_id is the real conversation ID; 'id' is the start-task itself.
      const convId = item.app_conversation_id || item.conversation_id || '';
      if (convId) {
        return { conversation_id: convId, sandbox_id: item.sandbox_id || '' };
      }
      // Check if the task has failed (status field may indicate this)
      if (item.status === 'failed' || item.status === 'error') {
        throw new Error(`Start task failed: ${item.error || item.status || 'unknown'}`);
      }
    }
  } catch (e) {
    // Re-throw non-status errors so the caller can distinguish
    if (e.message?.startsWith('Start task failed')) throw e;
  }
  return null;
}

// ---------------------------------------------------------------------------
// send-message (follow-up) with 409 resume
// ---------------------------------------------------------------------------

async function sendMessage(env, convId, prompt, sandboxId) {
  const body = {
    role: 'user',
    content: [{ type: 'text', text: prompt }],
    run: true,
  };
  let lastErr = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    const resp = await fetchWithTimeout(`${CLOUD_API}/api/v1/app-conversations/${convId}/send-message`, {
      method: 'POST',
      headers: await cloudHeaders(env),
      body: JSON.stringify(body),
    });
    if (resp.ok) {
      // Bug #14698 mitigation: trigger /run if agent stuck idle
      try {
        const convData = await cloudGet(env, `/api/v1/app-conversations?ids=${convId}`);
        const items = Array.isArray(convData) ? convData : (convData.items || []);
        if (items.length) {
          const status = items[0].execution_status || '';
          if (['completed', 'finished', 'idle'].includes(status)) {
            const acp = items[0].acp_server || '';
            const sk = items[0].session_api_key || '';
            if (acp && sk) {
              fetch(`${acp}/api/conversations/${convId}/run`, {
                method: 'POST',
                headers: { 'X-Session-API-Key': sk },
              }).catch(() => {});
            }
          }
        }
      } catch (_) {}
      return null;  // success
    }
    if (resp.status === 409 && attempt === 0 && sandboxId) {
      try {
        const r = await fetch(`${CLOUD_API}/api/v1/sandboxes/${sandboxId}/resume`, {
          method: 'POST', headers: await cloudHeaders(env),
        });
        if (r.ok) continue;  // retry send-message
      } catch (_) {}
    }
    const text = await resp.text();
    lastErr = `${resp.status}:${text.slice(0, 200)}`;
    break;
  }
  return lastErr;
}

// ---------------------------------------------------------------------------
// Poll conversation status & fetch response events
// ---------------------------------------------------------------------------

async function pollConversation(env, convId, state) {
  let data;
  try {
    data = await cloudGet(env, `/api/v1/app-conversations?ids=${convId}`);
  } catch (e) {
    // Transient API error — retry next poll (matches reference: continue on error)
    return { status: 'pending', sandbox_id: state.sandbox_id || '' };
  }
  const items = Array.isArray(data) ? data : (data.items || []);
  // Empty or null items = conversation not ready yet. Don't error out
  // (matches reference: `if not items: continue`). Return pending so the
  // caller doesn't clear conversation_id — next poll retries with same ID.
  if (!items || !items.length) return { status: 'pending', sandbox_id: state.sandbox_id || '' };
  const conv = items[0];
  if (!conv) return { status: 'pending', sandbox_id: state.sandbox_id || '' };
  const execStatus = conv.execution_status || '';
  const sandboxId = conv.sandbox_id || state.sandbox_id || '';

  if (execStatus === 'running' || execStatus === 'starting') {
    return { status: execStatus, sandbox_id: sandboxId };
  }

  if (execStatus === 'completed' || execStatus === 'finished') {
    const responseText = await fetchResponse(env, convId, state);
    // Save response text in state for crash recovery
    if (responseText) state._pending_response = responseText;
    return { status: 'completed', response: responseText, sandbox_id: sandboxId };
  }

  if (['failed', 'error', 'stopped'].includes(execStatus)) {
    return { status: 'failed', error: conv.error_message || conv.error || execStatus, sandbox_id: sandboxId };
  }

  return { status: execStatus || 'pending', sandbox_id: sandboxId };
}

async function fetchResponse(env, convId, state) {
  // Matches GCP Python backend (agent_runner.py run_conversation_sync):
  //   events/search?limit=100 → reverse → find last MessageEvent (source != 'user')
  //   → extract llm_message | message (string → str, dict → content[].text)
  try {
    // Single call with limit=100, no pagination (matches GCP Python)
    const data = await cloudGet(env, `/api/v1/conversation/${convId}/events/search?limit=100`);
    const list = Array.isArray(data) ? data : (data.events || data.items || []);
    for (let i = list.length - 1; i >= 0; i--) {
      const evt = list[i];
      const kind = evt.kind || evt.type || '';
      const source = evt.source || '';
      if (kind === 'MessageEvent' && source !== 'user') {
        const msg = evt.llm_message || evt.message || {};
        let text = '';
        if (typeof msg === 'string' && msg.trim()) {
          text = msg.trim();
        } else if (typeof msg === 'object') {
          const content = msg.content || [];
          if (Array.isArray(content)) {
            const parts = [];
            for (const block of content) {
              if (block?.type === 'text' && block.text?.trim()) {
                parts.push(block.text.trim());
              }
            }
            if (parts.length) text = parts.join('\n');
          } else if (typeof content === 'string' && content.trim()) {
            text = content.trim();
          }
        }
        if (text) return text;
      }
    }
  } catch (_) {}
  return null;
}

/**
 * Process conversation events into state.messages for UI display.
 * Matches GCP Python backend's _serialize_cloud_event + event_callback.
 * Called from the poll handler on each cycle for ALL events.
 */
async function processCloudEvents(env, convId, state) {
  const seen = new Set((state.seen_event_ids || []).map(String));
  try {
    const data = await cloudGet(env, `/api/v1/conversation/${convId}/events/search?limit=100`);
    const list = Array.isArray(data) ? data : (data.events || data.items || []);
    for (const evt of list) {
      const eid = String(evt.id || evt.event_id || '');
      const kind = evt.kind || evt.type || evt.event || '';
      const source = evt.source || '';
      const tool = evt.tool_name || evt.tool || evt.name || '';
      const ts = evt.timestamp || evt.created_at || now();

      // Skip MessageEvents immediately (before dedup registration) to prevent
      // dedup poisoning. Response text extraction is handled by fetchResponse()
      // which does its own fresh API call — it never reads seen_event_ids.
      // Matching the reference pattern: deferred dedup for MessageEvents.
      if (kind === 'MessageEvent') continue;

      // Track already-seen events by ID (registered AFTER MessageEvent skip)
      if (eid && seen.has(eid)) continue;
      if (eid) seen.add(eid);

      // AgentStateChangeEvent
      if (kind === 'AgentStateChangeEvent') {
        const agentState = evt.agent_state || evt.state || '';
        if (agentState) {
          const label = {
            thinking: '🤔 Thinking...',
            running: '▶️ Running...',
            completed: '✅ Done',
            paused: '⏸ Paused',
            awaiting_user_input: '💬 Waiting for input...',
            failed: '❌ Failed',
          }[agentState] || `▶️ ${agentState}`;
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[STATUS] ${label}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        }
        continue;
      }

      // ActionEvent (tool invocations)
      if (kind === 'ActionEvent') {
        let action = evt.action || evt.content || evt.message || {};
        if (typeof action === 'string') {
          try { action = JSON.parse(action); } catch { action = { content: action }; }
        }
        const cmd = (action.command || action.cmd || '').trim();
        const path = action.path || action.file || '';
        const query = action.query || '';

        if (tool.includes('bash') || tool.includes('terminal') || tool.includes('execute')) {
          const snippet = cmd.slice(0, 200).replace(/\n/g, ' ').trim();
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[TERMINAL] ${snippet}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        } else if (tool.includes('file_editor') || tool.includes('str_replace')) {
          let eventText = '';
          if (cmd === 'view') eventText = `Reading ${path}`;
          else if (cmd === 'create') eventText = `Creating ${path}`;
          else if (cmd === 'undo_edit') eventText = `Undoing ${path}`;
          else eventText = `Editing ${path}`;
          const prefix = cmd === 'view' ? '[READ]' : '[EDIT]';
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `${prefix} ${eventText}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        } else if (tool.includes('tavily') || tool.includes('search')) {
          const q = query || cmd || '';
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[SEARCH] Searching: ${q.slice(0, 150)}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        } else if (tool.includes('browser') || tool.includes('navigate')) {
          const url = action.url || cmd || '';
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[BROWSER] Navigate: ${url.slice(0, 150)}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        } else {
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[TOOL] ${tool}: ${JSON.stringify(action).slice(0, 120)}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        }
        continue;
      }

      // ObservationEvent (tool results)
      if (kind === 'ObservationEvent') {
        let obs = evt.observation || evt.output || evt.content || {};
        if (typeof obs === 'string') {
          try { obs = JSON.parse(obs); } catch { obs = { output: obs }; }
        }
        const stdout = safeStr(obs.stdout || obs.output || obs.content || '', 200);
        const stderr = safeStr(obs.stderr || '', 200);
        if (tool.includes('bash') || tool.includes('terminal') || tool.includes('execute')) {
          const out = stdout || stderr;
          if (out) {
            const tag = stderr ? '[WARN]' : '[OUT]';
            state.messages.push({ id: nextMsgId(state), role: 'event', content: `${tag} ${out}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
          }
        } else if (tool.includes('file_editor') || tool.includes('str_replace')) {
          const diff = obs.diff || '';
          if (diff) {
            state.messages.push({ id: nextMsgId(state), role: 'event', content: `[FILE] Diff (${String(diff).length} chars)`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
          }
        }
        continue;
      }

      // ToolEvent / GenericEvent fallback
      if (kind === 'ToolEvent' || kind === 'tool') {
        const input = evt.input || evt.arguments || evt.text || '';
        const summary = input ? (typeof input === 'string' ? input.slice(0, 100) : JSON.stringify(input).slice(0, 100)) : '';
        state.messages.push({ id: nextMsgId(state), role: 'event', content: `[TOOL] ${tool}: ${summary}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        continue;
      }
      if (kind === 'GenericEvent' || kind === 'generic') {
        const text = evt.text || evt.message || evt.content || '';
        if (text && text.trim()) {
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[INFO] ${String(text).trim().slice(0, 200)}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        }
        continue;
      }
    }
  } catch (_) {}

  state.seen_event_ids = Array.from(seen);
}


// Minimal: finds events.json in a ZIP by scanning the central directory.
const zipFindEntry = (buf, name) => {
  const dv = new DataView(buf);
  // Search for End of Central Directory (EOCD) signature: 0x06054b50
  let eocdOffset = -1;
  for (let i = buf.byteLength - 22; i >= 0; i--) {
    if (dv.getUint32(i, true) === 0x06054b50) { eocdOffset = i; break; }
  }
  if (eocdOffset < 0) return null;
  const cdOffset = dv.getUint32(eocdOffset + 16, true);
  const cdEntries = dv.getUint16(eocdOffset + 10, true);
  // Search central directory for the target file
  let ptr = cdOffset;
  for (let i = 0; i < cdEntries; i++) {
    if (dv.getUint32(ptr, true) !== 0x02014b50) break;
    const fnameLen = dv.getUint16(ptr + 28, true);
    const extraLen = dv.getUint16(ptr + 30, true);
    const commentLen = dv.getUint16(ptr + 32, true);
    const fname = new TextDecoder().decode(new Uint8Array(buf, ptr + 46, fnameLen));
    if (fname === name) {
      const method = dv.getUint16(ptr + 10, true);  // 0=stored, 8=deflate
      const csize = dv.getUint32(ptr + 20, true);
      const usize = dv.getUint32(ptr + 24, true);
      const localOffset = dv.getUint32(ptr + 42, true);
      // Read local file header to get actual data offset
      const lhdr = localOffset + 30 + dv.getUint16(localOffset + 26, true) + dv.getUint16(localOffset + 28, true);
      const data = new Uint8Array(buf, lhdr, csize);
      return { data, method, csize, usize };
    }
    ptr += 46 + fnameLen + extraLen + commentLen;
  }
  return null;
}

const zipInflate = async (data, usize) => {
  // Cloudflare Workers support DecompressionStream
  const ds = new DecompressionStream('deflate-raw');
  const writer = ds.writable.getWriter();
  writer.write(data);
  writer.close();
  const reader = ds.readable.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    total += value.length;
  }
  const result = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { result.set(c, off); off += c.length; }
  return result;
}


async function fetchResponseFromZip(env, convId, state) {
  try {
    // No timeout: ZIP export takes 1-3min and I/O wait doesn't count toward CPU limit.
    const resp = await fetchWithTimeout(`${CLOUD_API}/api/v1/app-conversations/${convId}/download`, { headers: await cloudHeaders(env) }, 0);
    if (!resp.ok) return null;
    const buf = await resp.arrayBuffer();
    // Try events.json first (standard OpenHands trajectory format)
    let entry = zipFindEntry(buf, 'events.json');
    if (!entry) {
      // Try event_*.json by finding any .json file in the ZIP (first file)
      const dv = new DataView(buf);
      for (let i = 0; i < buf.byteLength - 30; i++) {
        if (dv.getUint32(i, true) === 0x04034b50) {
          const fnameLen = dv.getUint16(i + 26, true);
          const extraLen = dv.getUint16(i + 28, true);
          const fname = new TextDecoder().decode(new Uint8Array(buf, i + 30, fnameLen));
          if (fname.endsWith('.json') && !fname.startsWith('.')) {
            const method = dv.getUint16(i + 10, true);  // 0=stored, 8=deflate
            const csize = dv.getUint32(i + 18, true);
            const usize = dv.getUint32(i + 22, true);
            const dataOff = i + 30 + fnameLen + extraLen;
            const data = new Uint8Array(buf, dataOff, csize);
            entry = { data, method, csize, usize };
            break;
          }
        }
      }
    }
    if (!entry) return null;
    let raw;
    if (entry.method === 0) {
      raw = entry.data;
    } else if (entry.method === 8) {
      raw = await zipInflate(entry.data, entry.usize || entry.data.length * 3);
    } else {
      return null;
    }
    const text = new TextDecoder().decode(raw);
    const events = JSON.parse(text);
    const list = Array.isArray(events) ? events : (events.events || events.items || []);
    // Find the last assistant MessageEvent
    let responseText = '';
    for (const evt of list) {
      const kind = evt.kind || evt.type || '';
      const source = evt.source || '';
      if (kind === 'MessageEvent' && source !== 'user') {
        const msg = evt.message || evt.llm_message || evt.content || '';
        let text = '';
        if (typeof msg === 'string' && msg.trim()) {
          text = msg.trim();
        } else if (typeof msg === 'object') {
          const content = msg.content || [];
          if (Array.isArray(content)) {
            for (const block of content) {
              if (block?.type === 'text' && block.text?.trim()) {
                if (text) text += '\n';
                text += block.text.trim();
              }
            }
          }
        }
        if (text) responseText = text;
      }
    }
    return responseText || null;
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Build default state for a repo
// ---------------------------------------------------------------------------

function emptyState(repo, branch, mode) {
  return {
    conversation_id: null,
    sandbox_id: null,
    start_task_id: null,
    repo,
    branch: branch || '',
    mode: mode || 'code',
    messages: [],
    queue: { position: 0, total: 0, done: 0, prompts: [], modes: [], cancelled: false },
    seen_event_ids: [],
    event_kinds: {},
    _extracted_hashes: {},
    _batch_skip: undefined,
    last_event_index: 0,
    last_event_timestamp: '',
    last_sent_position: -1,
    llm_model: '',
    configured_model: '',
  };
}

// ---------------------------------------------------------------------------
// Request router
// ---------------------------------------------------------------------------

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const method = request.method;
    const path = url.pathname;

    if (method === 'OPTIONS') return new Response(null, { headers: CORS });

    try {
      return await route(method, path, url, request, env);
    } catch (e) {
      const msg = `${e.message || e}`.slice(0, 300);
      const stack = (e.stack || '').slice(0, 400);
      console.error(`${method} ${path}:`, msg, stack);
      return json({ error: msg, detail: stack }, 500);
    }
  },
};

async function route(method, path, url, request, env) {
  // --- CORS helper for routes that need it ---

  // GET / — status page
  if (path === '/' && method === 'GET') {
    return json({ status: 'ok', worker: 'vibecode-proxy', version: '1.0.0' });
  }
  // Health
  if (path === '/api/health' && method === 'GET') {
    return json({ status: 'ok', timestamp: now() });
  }
  if (path === '/api/hello' && method === 'GET') {
    return json({ message: 'VibeCode Worker' });
  }
  // Cancel batch for a repo — clears queue/pending, keeps chat history.
  // POST /api/chat/cancel?repo=owner/repo
  if (path === '/api/chat/cancel' && method === 'POST') {
    const repo = url.searchParams.get('repo') || '';
    if (!repo) return error('repo required', 400);
    const state = await readState(env, repo);
    if (state) {
      state.queue.prompts = [];
      state.queue.modes = [];
      state.queue.position = 0;
      state.queue.total = 0;
      state.queue.done = 0;
      state.queue.cancelled = false;
      state.last_sent_position = -1;
      state._batch_skip = undefined;
      state._run_started_at = undefined;
      await writeState(env, repo, state);
    }
    return json({ ok: true, message: `Batch cancelled for ${repo}. Chat history preserved.` });
  }

  // Clear queue — full reset (kept for backwards compat, but per-repo cancel above is better)
  if (path === '/api/chat/clear-queue' && method === 'POST') {
    try {
      const list = await env.VIBECODE.list({ prefix: 'state:' });
      for (const key of list.keys) await env.VIBECODE.delete(key.name);
      const list2 = await env.VIBECODE.list({ prefix: 'log:' });
      for (const key of list2.keys) await env.VIBECODE.delete(key.name);
    } catch (_) {}
    return json({ ok: true, message: 'All chat state cleared.' });
  }

  // LLM config
  if (path === '/api/config/llm' && method === 'PUT') {
    const body = await request.json();
    const cfg = await readConfig(env);
    if (body.model) cfg.model = body.model;
    if (body.api_key) cfg.api_key = body.api_key;
    await writeConfig(env, cfg);
    return json({ ok: true, model: cfg.model });
  }
  if (path === '/api/config/llm' && method === 'GET') {
    const cfg = await readConfig(env);
    return json({ model: cfg.model, has_api_key: !!cfg.api_key });
  }

  // Branches
  if (path === '/api/chat/branches' && method === 'GET') {
    const repo = url.searchParams.get('repo') || '';
    if (!repo) return json([]);
    return json(await getBranches(repo));
  }

  // Repos list
  if (path === '/api/chat/repos' && method === 'GET') {
    const repos = [];
    try {
      const list = await env.VIBECODE.list({ prefix: 'state:' });
      for (const key of list.keys) {
        const repoKey = key.name.slice(6);
        if (!repoKey) continue;
        const state = await readState(env, repoKey);
        if (state && state.messages && state.messages.length > 0) {
          repos.push({
            key: repoKey, repo: repoKey, mode: state.mode || 'code',
            message_count: state.messages.length,
            last_timestamp: state.messages[state.messages.length - 1]?.timestamp || 0,
          });
        }
      }
    } catch (_) {}
    return json({ repos });
  }

  // Task log
  if (path === '/api/chat/log' && method === 'GET') {
    const repo = url.searchParams.get('repo') || '';
    if (!repo) return json([]);
    const raw = await env.VIBECODE.get(`log:${repo}`);
    return json(raw ? JSON.parse(raw) : []);
  }

  // Reset
  if (path === '/api/chat' && method === 'DELETE') {
    const repo = url.searchParams.get('repo') || '';
    if (repo) {
      await env.VIBECODE.delete(`state:${repo}`);
    } else {
      try {
        const list = await env.VIBECODE.list({ prefix: 'state:' });
        for (const key of list.keys) await env.VIBECODE.delete(key.name);
      } catch (_) {}
    }
    return json({ ok: true });
  }

  // POST /api/chat — backwards compat (single message, non-blocking)
  if (path === '/api/chat' && method === 'POST') {
    let body;
    try { body = await request.json(); } catch {
      return error('Invalid JSON body', 400);
    }
    if (typeof body !== 'object' || body === null) return error('Invalid request body', 400);
    const prompt = (body.prompt || '').trim();
    const repo = (body.repo || '').trim();
    const branch = (body.branch || '').trim();
    const mode = (body.mode || 'code').trim();
    if (!prompt) return error('prompt is required', 400);
    if (!repo) return error('repo is required', 400);

    // Treat as batch of 1
    const state = (await readState(env, repo)) || emptyState(repo, branch, mode);
    state.queue.prompts.push(prompt);
    state.queue.modes.push(mode);
    state.queue.total = state.queue.prompts.length;
    if (state.queue.position >= state.queue.total) {
      state.queue.position = 0;
      state.queue.done = 0;
    }
    await writeState(env, repo, state);
    return json({ status: 'queued', position: state.queue.position, total: state.queue.total });
  }

  // POST /api/chat/batch — queue prompt(s), return immediately
  if (path === '/api/chat/batch' && method === 'POST') {
    const body = await request.json();
    const prompts = body.prompts;
    if (!Array.isArray(prompts) || !prompts.length) return error('prompts array required', 400);
    const repo = (body.repo || '').trim();
    const branch = (body.branch || '').trim();
    const mode = (body.mode || 'code').trim();
    if (!['code', 'plan'].includes(mode)) return error("mode must be 'code' or 'plan'", 400);
    if (!repo) return error('repo is required', 400);
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) return error(`Invalid repo format: '${repo}'. Use owner/repo`, 400);

    const state = (await readState(env, repo)) || emptyState(repo, branch, mode);
    if (branch) state.branch = branch;
    if (mode) state.mode = mode;

    // If all previous prompts finished OR were cancelled, start fresh (replace queue)
    if (state.queue.position >= state.queue.total || state.queue.cancelled) {
      state.queue.prompts = [];
      state.queue.modes = [];
      state.queue.position = 0;
      state.queue.done = 0;
      state.last_sent_position = -1;
      state._run_started_at = undefined;  // reset timer for new batch
    }
    state.queue.prompts.push(...prompts);
    state.queue.modes.push(...Array(prompts.length).fill(mode));
    state.queue.total = state.queue.prompts.length;
    state.queue.cancelled = false;

    await writeState(env, repo, state);
    return json({ status: 'queued', position: state.queue.position, total: state.queue.total });
  }

  // POST /api/chat/batch/cancel
  if (path.startsWith('/api/chat/batch/cancel') && method === 'POST') {
    const indexStr = path.replace('/api/chat/batch/cancel', '').replace(/^\//, '');
    const index = indexStr ? parseInt(indexStr, 10) : -1;
    let repo = url.searchParams.get('repo') || '';

    // If no repo specified, find the repo with a running batch
    if (!repo) {
      try {
        const list = await env.VIBECODE.list({ prefix: 'state:' });
        for (const key of list.keys) {
          const rk = key.name.slice(6);
          const s = await readState(env, rk);
          if (s && s.queue && s.queue.position < s.queue.total) {
            repo = rk;
            break;
          }
        }
      } catch (_) {}
    }
    if (!repo) return json({ ok: true });

    const state = await readState(env, repo);
    if (!state) return json({ ok: true });

    if (index >= 0 && index < state.queue.total) {
      // Cancel specific prompt
      if (index === state.queue.position) {
        // Current prompt: advance past it
        state.queue.position++;
        state.queue.done++;
        // Also skip past any future-cancelled prompts
        if (state._batch_skip) {
          while (state._batch_skip[state.queue.position]) {
            state.queue.position++;
            state.queue.done++;
          }
        }
      } else if (index > state.queue.position) {
        // Future prompt: mark as skipped, will be advanced past when reached
        if (!state._batch_skip) state._batch_skip = {};
        state._batch_skip[index] = true;
      }
    } else if (index >= state.queue.total) {
      // Out of range — no-op (app has its own bounds check, but be defensive)
      return json({ ok: true });
    } else {
      // index < 0 (no index = POST /api/chat/batch/cancel) → cancel all
      state.queue.cancelled = true;
      state.queue.position = state.queue.total;
      state.queue.done = state.queue.total;
      state.queue.prompts = [];
      state.queue.modes = [];
      state.last_sent_position = -1;
      state._run_started_at = undefined;
    }
    await writeState(env, repo, state);
    return json({ ok: true });
  }

  // --- Task endpoints (KV-backed — matching main.py) ---

  // POST /api/prompts — create a task, store in KV
  if (path === '/api/prompts' && method === 'POST') {
    const body = await request.json();
    const taskId = crypto.randomUUID ? crypto.randomUUID() : `task_${now()}_${Math.random().toString(36).slice(2, 10)}`;
    const created = new Date().toISOString();
    const task = {
      id: taskId, prompt: body.prompt || '', repo: body.repo || '',
      branch: body.branch || '', mode: body.mode || 'code', status: 'queued',
      conversation_id: null, sandbox_id: null, created_at: created,
      completed_at: null, error_message: null, mcp_config: null,
    };
    await env.VIBECODE.put(`task:${taskId}`, JSON.stringify(task));
    // Update task:list (1 KV op for listing all tasks)
    const listRaw = await env.VIBECODE.get('task:list');
    const list = listRaw ? JSON.parse(listRaw) : [];
    list.unshift(task);
    if (list.length > 200) list.length = 200;
    await env.VIBECODE.put('task:list', JSON.stringify(list));
    // Also put into the batch queue (matching POST /api/chat behavior)
    const repo = body.repo || '';
    if (repo) {
      const state = (await readState(env, repo)) || emptyState(repo, body.branch || '', body.mode || 'code');
      state.queue.prompts.push(body.prompt || '');
      state.queue.modes.push(body.mode || 'code');
      state.queue.total = state.queue.prompts.length;
      if (state.queue.position >= state.queue.total) { state.queue.position = 0; state.queue.done = 0; }
      await writeState(env, repo, state);
    }
    return json(task, 201);
  }

  // GET /api/tasks — list from KV (1 read for all tasks, not N reads)
  if (path === '/api/tasks' && method === 'GET') {
    const listRaw = await env.VIBECODE.get('task:list');
    const tasks = listRaw ? JSON.parse(listRaw) : [];
    return json({ tasks });
  }

  // DELETE /api/tasks — delete all non-running tasks
  if (path === '/api/tasks' && method === 'DELETE') {
    const listRaw = await env.VIBECODE.get('task:list');
    const tasks = listRaw ? JSON.parse(listRaw) : [];
    const kept = [];
    for (const t of tasks) {
      if (t.status === 'running' || t.status === 'starting') { kept.push(t); continue; }
      await env.VIBECODE.delete(`task:${t.id}`).catch(() => {});
    }
    await env.VIBECODE.put('task:list', JSON.stringify(kept));
    return json({ ok: true });
  }

  // GET /api/tasks/{id} — single task lookup (1 KV read)
  if (path.startsWith('/api/tasks/') && method === 'GET' && !path.includes('/events')) {
    const taskId = path.split('/').pop();
    const raw = await env.VIBECODE.get(`task:${taskId}`);
    if (!raw) return error('Task not found', 404);
    return json(JSON.parse(raw));
  }

  // DELETE /api/tasks/{id} — delete single task
  if (path.startsWith('/api/tasks/') && method === 'DELETE' && !path.endsWith('/tasks')) {
    const parts = path.split('/');
    const taskId = parts[parts.indexOf('tasks') + 1];
    const raw = await env.VIBECODE.get(`task:${taskId}`);
    if (!raw) return error('Task not found', 404);
    const task = JSON.parse(raw);
    if (task.status !== 'queued' && task.status !== 'failed' && task.status !== 'completed') {
      return error(`Cannot delete task with status '${task.status}'`, 400);
    }
    await env.VIBECODE.delete(`task:${taskId}`).catch(() => {});
    // Remove from list
    const listRaw = await env.VIBECODE.get('task:list');
    if (listRaw) {
      const list = JSON.parse(listRaw).filter(t => t.id !== taskId);
      await env.VIBECODE.put('task:list', JSON.stringify(list));
    }
    return json({ status: 'deleted', task_id: taskId });
  }

  // POST /api/tasks/{id}/retry — reset failed task to queued (2 KV ops)
  if (path.includes('/retry') && method === 'POST') {
    const parts = path.split('/');
    const taskId = parts[parts.indexOf('tasks') + 1];
    const raw = await env.VIBECODE.get(`task:${taskId}`);
    if (!raw) return error('Task not found', 404);
    const task = JSON.parse(raw);
    if (task.status !== 'failed') return error(`Cannot retry task with status '${task.status}'`, 400);
    task.status = 'queued';
    task.error_message = null;
    task.completed_at = null;
    await env.VIBECODE.put(`task:${taskId}`, JSON.stringify(task));
    // Also update in list
    const listRaw = await env.VIBECODE.get('task:list');
    if (listRaw) {
      const list = JSON.parse(listRaw);
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === taskId) { list[i] = {...list[i], status: 'queued', error_message: null, completed_at: null}; break; }
      }
      await env.VIBECODE.put('task:list', JSON.stringify(list));
    }
    return json({ status: 'queued', task_id: taskId });
  }

  // GET /api/tasks/{id}/events — return events from task state (1 KV read + 1 state read)
  if (path.includes('/events') && method === 'GET') {
    const parts = path.split('/');
    const taskId = parts[parts.indexOf('tasks') + 1];
    const raw = await env.VIBECODE.get(`task:${taskId}`);
    if (!raw) return error('Task not found', 404);
    const task = JSON.parse(raw);
    let events = [];
    if (task.repo) {
      const state = await readState(env, task.repo);
      if (state && state.messages) {
        events = state.messages
          .filter(m => m.role === 'event')
          .map((m, i) => ({
            event_index: i,
            type: 'message', timestamp: m.timestamp || now(),
            sender: m.sender || 'agent', content: m.content || '',
            agent_state: null,
          }));
      }
    }
    return json({ events });
  }

  // GET /api/chat — state + poll Cloud API
  if (path === '/api/chat' && method === 'GET') {
    const repo = url.searchParams.get('repo') || '';
    const mode = url.searchParams.get('mode') || '';
    if (!repo) {
      return json({ messages: [], conversation_id: null, repo: '', batch: { running: false, position: 0, total: 0, done: 0 } });
    }

    let state = await readState(env, repo);
    if (!state) {
      return json({
        messages: [], conversation_id: null, sandbox_id: null, repo, branch: '', mode: mode || 'code',
        current_repo_key: repo, conversation_status: 'idle', llm_model: '', configured_model: '',
        batch: { running: false, cancelled: false, position: 0, total: 0, done: 0, repo, prompts: [], modes: [] },
      });
    }

    const q = state.queue;
    // Migration: old code set q.cancelled=true on conv failure, locking the
    // queue. If cancelled but has pending work, clear stale flag and retry.
    let hasPending = q.position < q.total && !q.cancelled;
    if (q.cancelled && q.position < q.total) {
      q.cancelled = false;
      hasPending = true;
    }

    // Queue naturally completed — reset to clean idle state so the app
    // doesn't show stale "1/1 done" after the task finishes.
    if (!hasPending && q.total > 0) {
      q.position = 0;
      q.total = 0;
      q.done = 0;
      q.prompts = [];
      q.modes = [];
      q.cancelled = false;
      state._batch_skip = undefined;
      // Reset timer too; next task will set its own.
      state._run_started_at = undefined;
      // Persist so next poll sees clean state.
      await writeState(env, repo, state);
    }
    let convStatus = 'idle';

    // --- Phase: resolve start_task to conversation_id (stateful retry across polls) ---
    if (!state.conversation_id && state.start_task_id) {
      const stKey = `start_task:${state.start_task_id}`;
      let stCount = 0;
      try {
        const raw = await env.VIBECODE.get(stKey);
        if (raw) stCount = parseInt(raw, 10) || 0;
      } catch (_) {}
      stCount++;
      try {
        const result = await pollForConvId(env, state.start_task_id);
        if (result) {
          state.conversation_id = result.conversation_id;
          if (result.sandbox_id) state.sandbox_id = result.sandbox_id;
          state.start_task_id = null;
          try { await env.VIBECODE.delete(stKey); } catch (_) {}
        } else if (stCount >= 36) {
          // ~3min with 5s sleep per attempt — give up
          const deadId = state.start_task_id;
          state.start_task_id = null;
          try { await env.VIBECODE.delete(stKey); } catch (_) {}
          console.error(`Start task ${deadId} never resolved after ${stCount} attempts`);
        } else {
          try { await env.VIBECODE.put(stKey, String(stCount), { expirationTtl: 600 }); } catch (_) {}
        }
      } catch (e) {
        // Start task explicitly failed (status=error/failed) — give up immediately
        console.error(`Start task failed: ${e.message}`);
        state.start_task_id = null;
        try { await env.VIBECODE.delete(stKey); } catch (_) {}
      }
      await writeState(env, repo, state);
    }

    // --- Phase: create conversation if queue has work ---
    if (hasPending && !state.conversation_id && !state.start_task_id) {
      const prompt = q.prompts[q.position];
      const promptMode = q.modes[q.position] || mode;
      try {
        const result = await createConversation(env, prompt, repo, state.branch, promptMode);
        if (result.conversation_id) {
          state.conversation_id = result.conversation_id;
          if (result.sandbox_id) state.sandbox_id = result.sandbox_id;
          state.last_sent_position = q.position;  // sent via initial_message
          convStatus = 'starting';
        } else if (result.start_task_id) {
          state.start_task_id = result.start_task_id;
          state.last_sent_position = q.position;  // will be sent when conv resolves
          convStatus = 'starting';
        }

        // Save LLM model info
        const cfg = await readConfig(env);
        state.llm_model = cfg.model || '';
        state.configured_model = cfg.model || '';

        // Reset elapsed timer for this new conversation
        state._run_started_at = now();

        // Add user message to local state
        state.messages.push({ id: nextMsgId(state), role: 'user', content: prompt, timestamp: now() });
        state.messages.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent is starting up... (0s)', kind: 'SystemEvent', timestamp: now() });

        await writeState(env, repo, state);
      } catch (e) {
        console.error(`Create conv error: ${e.message}`);
        // Don't cancel the queue — let the next poll retry.
        // Track failures — after 3, skip this prompt to keep queue draining.
        const maxCrash = 3;
        const crashKey = `crash:${repo}:${q.position}`;
        let crashCount = 0;
        try {
          const raw = await env.VIBECODE.get(crashKey);
          if (raw) crashCount = parseInt(raw, 10) || 0;
        } catch (_) {}
        crashCount++;
        if (crashCount >= maxCrash) {
          // Skip this prompt — move to next
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] Skipping prompt #${q.position + 1}: agent stopped responding.`, kind: 'ErrorEvent', timestamp: now() });
          state.messages.push({ id: nextMsgId(state), role: 'assistant', content: `[Skipped: agent failed to start]`, timestamp: now() });
          q.position++;
          q.done = Math.min(q.position, q.total);
          state.conversation_id = null;
          state.sandbox_id = null;
          state.last_sent_position = -1;
          state._run_started_at = undefined;
          // Clean up crash counter
          try { await env.VIBECODE.delete(crashKey); } catch (_) {}
        } else {
          try { await env.VIBECODE.put(crashKey, String(crashCount), { expirationTtl: 120 }); } catch (_) {}
          // Only push error once per batch to avoid spamming
          const lastMsg = state.messages[state.messages.length - 1];
          if (!lastMsg || !lastMsg.content?.includes('starting agent')) {
            state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] Failed to start agent (attempt ${crashCount}/${maxCrash}).`, kind: 'ErrorEvent', timestamp: now() });
          }
        }
        await writeState(env, repo, state);
      }
    }

    // --- Phase: send follow-up message if queue advanced but not sent yet ---
    // This handles: conversation exists, new prompt in queue, not yet sent via
    // send-message. Triggered when last_sent_position < q.position.
    if (hasPending && state.conversation_id && state.last_sent_position < q.position) {
      const prompt = q.prompts[q.position];
      const sendErr = await sendMessage(env, state.conversation_id, prompt, state.sandbox_id);
      if (sendErr) {
        console.error(`sendMessage follow-up error: ${sendErr}`);
        // Any send error means the conversation is dead — clear it
        // so the next batch creates a fresh one.
        state.conversation_id = null;
        state.sandbox_id = null;
        await writeState(env, repo, state);
      } else {
        state.last_sent_position = q.position;
        // Add user message
        state.messages.push({ id: nextMsgId(state), role: 'user', content: prompt, timestamp: now() });
        state.messages.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
        await writeState(env, repo, state);
      }
    }

    const skipFutureCancelled = (q) => {
      while (state._batch_skip && state._batch_skip[q.position]) {
        q.position++;
        q.done = Math.min(q.position, q.total);
      }
    };

    // --- Phase: poll Cloud API for agent status ---
    if (state.conversation_id && hasPending) {
      // Try to read the agent's response from events FIRST.
      // fetchResponse hits events/search directly — it's the most reliable
      // indicator of completion and stays available even after the status
      // endpoint starts returning items:[null].
      const directResponse = await fetchResponse(env, state.conversation_id, state);

      // Process events for UI enrichment (tool calls, status changes).
      await processCloudEvents(env, state.conversation_id, state);

      if (directResponse) {
        // Agent message found via events — skip status API entirely.
        convStatus = 'completed';
        state.messages.push({ id: nextMsgId(state), role: 'assistant', content: directResponse, timestamp: now() });
        q.position++;
        q.done = Math.min(q.position, q.total);
        skipFutureCancelled(q);
        const stillPending = q.position < q.total && !q.cancelled;
        if (stillPending) {
          const nextPrompt = q.prompts[q.position];
          const sendErr = await sendMessage(env, state.conversation_id, nextPrompt, state.sandbox_id);
          if (sendErr) {
            console.error(`sendMessage follow-up error: ${sendErr}`);
          } else {
            state.last_sent_position = q.position;
            state.messages.push({ id: nextMsgId(state), role: 'user', content: nextPrompt, timestamp: now() });
            state.messages.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
          }
        }
        await writeState(env, repo, state);
        return buildStateResponse(state, q, stillPending);
      }

      // No events found — fall back to status-based polling.
      const pollResult = await pollConversation(env, state.conversation_id, state);
      convStatus = pollResult.status;
      if (pollResult.sandbox_id) state.sandbox_id = pollResult.sandbox_id;

      // events already processed above (line ~1344) — no need to call again.
      if (pollResult.status === 'completed') {
        let responseText = pollResult.response || state._pending_response;
        state._pending_response = undefined;

        if (responseText) {
          // Advance queue
          q.position++;
          q.done = Math.min(q.position, q.total);
          skipFutureCancelled(q);
          // Recompute hasPending after queue advance for accurate batch.running
          const stillPending = q.position < q.total && !q.cancelled;
          // If more prompts, send next one
          if (stillPending) {
            const nextPrompt = q.prompts[q.position];
            const sendErr = await sendMessage(env, state.conversation_id, nextPrompt, state.sandbox_id);
            if (sendErr) {
              console.error(`sendMessage error at pos ${q.position}: ${sendErr}`);
            } else {
              state.last_sent_position = q.position;
              state.messages.push({ id: nextMsgId(state), role: 'user', content: nextPrompt, timestamp: now() });
              state.messages.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
            }
          }
          await writeState(env, repo, state);
          return buildStateResponse(state, q, stillPending);
        }

        // No response text found — retry across polls (stateful, non-blocking)
        // Retry state stored in SEPARATE KV key so it survives main state write failures.
        // Each poll does ONE attempt so we never block >30s on free tier.
        // Retry window extends up to ~5min as long as the app keeps polling.
        let retryResponse = null;
        let rState = { count: 0, started_at: 0 };
        try {
          const rRaw = await env.VIBECODE.get(`retry:${state.conversation_id}`);
          if (rRaw) rState = JSON.parse(rRaw);
        } catch (_) {}
        const retryCount = rState.count || 0;

        // Detect repeated completion for same prompt (writeState failed on prev poll)
        if (state._completed_position === q.position) {
          // writeState failed on previous poll — retry state is lost.
          // Don't loop forever: advance queue and move on.
          console.error(`Retry state lost for conv ${state.conversation_id} (position ${q.position}) — advancing`);
          q.position++;
          q.done = Math.min(q.position, q.total);
          skipFutureCancelled(q);
          const stillPending = q.position < q.total && !q.cancelled;
          await writeState(env, repo, state);
          return buildStateResponse(state, q, stillPending, repo, mode, 'idle');
        }
        state._completed_position = q.position;

        if (retryCount < 12) {
          // Increasing delay per attempt: 5s, 10s, 15s, 20s, 30s... up to 60s
          const delays = [5, 10, 15, 20, 30, 30, 40, 40, 50, 50, 60, 60];
          const waitSec = delays[retryCount] || 60;
          const elapsed = rState.started_at ? (Date.now() - rState.started_at) / 1000 : 0;

          if (elapsed >= waitSec) {
            // Time to do this attempt — try both events/search AND ZIP
            retryResponse = await fetchResponse(env, state.conversation_id, state);
            if (!retryResponse) {
              retryResponse = await fetchResponseFromZip(env, state.conversation_id, state);
            }
            // Force /run on early attempts (agent might be stuck)
            if (!retryResponse && retryCount < 3) {
              try {
                const convData = await cloudGet(env, `/api/v1/app-conversations?ids=${state.conversation_id}`);
                const items = Array.isArray(convData) ? convData : (convData.items || []);
                if (items.length) {
                  const acp = items[0].acp_server || '';
                  const sk = items[0].session_api_key || '';
                  if (acp && sk) {
                    await fetch(`${acp}/api/conversations/${state.conversation_id}/run`, {
                      method: 'POST', headers: { 'X-Session-API-Key': sk },
                    }).catch(() => {});
                  }
                }
              } catch (_) {}
            }
            rState.count = retryCount + 1;
            if (!retryResponse) {
              convStatus = 'pending';
            }
          } else {
            convStatus = 'pending';
          }
        } else {
          // 12+ attempts over ~5min — give up
          rState = { count: 0, started_at: 0 };
        }
        if (!rState.started_at) rState.started_at = Date.now();
        // Persist retry state to SEPARATE key (survives main state write failure)
        try { await env.VIBECODE.put(`retry:${state.conversation_id}`, JSON.stringify(rState)); } catch (_) {}

        if (retryResponse) {
          // Clean up retry state
          try { await env.VIBECODE.delete(`retry:${state.conversation_id}`).catch(() => {}); } catch (_) {}
          state.messages.push({ id: nextMsgId(state), role: 'assistant', content: retryResponse, timestamp: now() });

          // Advance queue
          q.position++;
          q.done = Math.min(q.position, q.total);
          skipFutureCancelled(q);
          const stillPending = q.position < q.total && !q.cancelled;

          // If more prompts, send next one
          if (stillPending) {
            const nextPrompt = q.prompts[q.position];
            const sendErr = await sendMessage(env, state.conversation_id, nextPrompt, state.sandbox_id);
            if (sendErr) {
              console.error(`sendMessage error at pos ${q.position}: ${sendErr}`);
            } else {
              state.last_sent_position = q.position;
              state.messages.push({ id: nextMsgId(state), role: 'user', content: nextPrompt, timestamp: now() });
              state.messages.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
            }
          }

          await writeState(env, repo, state);
          return buildStateResponse(state, q, stillPending);
        } else if (convStatus === 'pending') {
          // Still waiting for ZIP to generate — return current state, retry next poll
          // Write main state too so _completed_position is saved
          await writeState(env, repo, state);
          return buildStateResponse(state, q, true, repo, mode, 'pending');
        } else {
          // All retries exhausted — give up
          state.messages.push({ id: nextMsgId(state), role: 'event', content: '[ERROR] Task finished but no response text found', kind: 'ErrorEvent', timestamp: now() });

          // Advance queue
          q.position++;
          q.done = Math.min(q.position, q.total);
          skipFutureCancelled(q);
          const stillPending = q.position < q.total && !q.cancelled;

          if (stillPending) {
            const nextPrompt = q.prompts[q.position];
            const sendErr = await sendMessage(env, state.conversation_id, nextPrompt, state.sandbox_id);
            if (sendErr) {
              console.error(`sendMessage error at pos ${q.position}: ${sendErr}`);
            } else {
              state.last_sent_position = q.position;
              state.messages.push({ id: nextMsgId(state), role: 'user', content: nextPrompt, timestamp: now() });
              state.messages.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
            }
          }

          await writeState(env, repo, state);
          return buildStateResponse(state, q, stillPending);
        }
      } else if (pollResult.status === 'failed') {
        // Agent execution failed — conversation is dead.
        const errMsg = pollResult.error || 'unknown error';
        state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] Agent failed: ${errMsg.slice(0, 200)}`, kind: 'ErrorEvent', timestamp: now() });
        q.position++;
        q.done = Math.min(q.position, q.total);
        skipFutureCancelled(q);
        state.conversation_id = null;
        state.sandbox_id = null;
        state.last_sent_position = -1;
        state.start_task_id = null;
        state._run_started_at = undefined;
        await writeState(env, repo, state);
        const fp = q.position < q.total && !q.cancelled;
        return buildStateResponse(state, q, fp, repo, mode, 'idle');
      } else if (pollResult.status === 'error') {
        // Cloud API returned error (e.g., items:[null]) — conversation is dead.
        const errMsg = pollResult.error || 'unknown error';
        state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] ${errMsg.slice(0, 200)}`, kind: 'ErrorEvent', timestamp: now() });
        q.position++;
        q.done = Math.min(q.position, q.total);
        skipFutureCancelled(q);
        state.conversation_id = null;
        state.sandbox_id = null;
        state.last_sent_position = -1;
        state.start_task_id = null;
        state._run_started_at = undefined;
        await writeState(env, repo, state);
        const fp2 = q.position < q.total && !q.cancelled;
        return buildStateResponse(state, q, fp2, repo, mode, 'idle');
      } else if (pollResult.status === 'idle' || (pollResult.status === 'completed' && !pollResult.response)) {
        // Conversation is idle/completed but queue has work and no response.
        // This means either:
        // 1. send-message was never called
        // 2. send-message failed
        // 3. Agent stuck in idle (bug #14698)
        // → Try sending the current prompt AND force /run
        if (convStatus !== 'starting') {
          const currentPrompt = q.prompts[q.position];
          const sendErr = await sendMessage(env, state.conversation_id, currentPrompt, state.sandbox_id);
          if (sendErr) {
            console.error(`sendMessage idle-retry error: ${sendErr}`);
          } else {
            convStatus = 'running';
          }
          // Also try force /run via ACP directly (bug #14698 mitigation)
          try {
            const convData = await cloudGet(env, `/api/v1/app-conversations?ids=${state.conversation_id}`);
            const items = Array.isArray(convData) ? convData : (convData.items || []);
            if (items.length) {
              const conv = items[0];
              const execStatus = conv.execution_status || '';
              if (['completed', 'finished', 'idle'].includes(execStatus)) {
                const acp = conv.acp_server || '';
                const sessionKey = conv.session_api_key || '';
                if (acp && sessionKey) {
                  fetch(`${acp}/api/conversations/${state.conversation_id}/run`, {
                    method: 'POST',
                    headers: { 'X-Session-API-Key': sessionKey },
                  }).catch(() => {});
                }
              }
            }
          } catch (_) {}
        }
        await writeState(env, repo, state);
        return buildStateResponse(state, q, hasPending, repo, mode, convStatus);
      } else {
        // Still running — show elapsed timer, updated in-memory every poll.
        // _run_started_at is persisted ONCE when first set; no heartbeat writes.
        const nowMs = Date.now();
        if (!state._run_started_at) {
          state._run_started_at = nowMs;
          await writeState(env, repo, state);  // persist the start timestamp once
        }
        const elapsed = Math.floor((nowMs - state._run_started_at) / 1000);
        const elapsedStr = elapsed < 60 ? `${elapsed}s` : `${Math.floor(elapsed / 60)}m${elapsed % 60}s`;

        // Find the last "Working" heartbeat and update in-place (memory only)
        let foundHb = false;
        if (state.messages) {
          for (let i = state.messages.length - 1; i >= 0; i--) {
            const m = state.messages[i];
            if (m.role === 'event' && typeof m.content === 'string' &&
                m.content.includes('[STATUS]') &&
                (m.content.includes('Working') || m.content.includes('working'))) {
              m.content = `[STATUS] Working... (${elapsedStr})`;
              m.timestamp = now();
              foundHb = true;
              break;
            }
          }
        }
        if (!foundHb) {
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[STATUS] Working... (${elapsedStr})`, kind: 'SystemEvent', timestamp: now() });
        }
        // No KV write for heartbeat — elapsed is computed per-poll from _run_started_at.
        // fetchResponse NOT called — all events fetched atomically at completion.
        return buildStateResponse(state, q, hasPending, repo, mode, convStatus);
      }
    }
    // No poll phase ran (no conversation_id or no pending work). Return current state.
    return buildStateResponse(state, q, hasPending, repo, mode, convStatus);
  }

  // GET /api/logs — server log viewer
  if (path === '/api/logs' && method === 'GET') {
    return json({ lines: [] });
  }

  // GET /api/logs/stream — SSE log stream (not applicable to Workers; return empty)
  if (path === '/api/logs/stream' && method === 'GET') {
    return json({ lines: [] });
  }

  // --- Misc stubs ---

  // POST /api/fcm-token — Firebase push notification token (stub)
  if (path === '/api/fcm-token' && method === 'POST') {
    return json({ ok: true });
  }

  // PUT /api/config/git — git user config
  if (path === '/api/config/git' && method === 'PUT') {
    const body = await request.json();
    const git = { name: body.name || '', email: body.email || '' };
    await env.VIBECODE.put('config:git', JSON.stringify(git));
    return json({ ok: true, name: git.name, email: git.email });
  }
  // GET /api/config/git
  if (path === '/api/config/git' && method === 'GET') {
    const raw = await env.VIBECODE.get('config:git');
    const git = raw ? JSON.parse(raw) : { name: '', email: '' };
    return json(git);
  }

  return json({ error: `Not found: ${method} ${path}` }, 404);
}
