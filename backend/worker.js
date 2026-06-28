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

function cloudHeaders(env) {
  return { 'Authorization': `Bearer ${env.OPENHANDS_CLOUD_API_KEY}`, 'Content-Type': 'application/json', 'Accept': 'application/json' };
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
  // Trim _batch_skip if too many cancelled prompts piled up (unlikely but safe)
  if (state._batch_skip && Object.keys(state._batch_skip).length > 100) {
    state._batch_skip = undefined;
  }
  await env.VIBECODE.put(`state:${repo}`, JSON.stringify(state));
}

function buildStateResponse(state, q, hasPending, repo, mode, convStatus) {
  return json({
    messages: state.messages || [],
    conversation_id: state.conversation_id,
    sandbox_id: state.sandbox_id || null,
    repo,
    branch: state.branch || '',
    mode: state.mode || mode || 'code',
    current_repo_key: repo,
    conversation_status: convStatus,
    llm_model: state.llm_model || '',
    configured_model: state.configured_model || '',
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

async function cloudGet(env, path) {
  const resp = await fetch(`${CLOUD_API}${path}`, { headers: cloudHeaders(env) });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`${resp.status}:${text.slice(0, 200)}`);
  }
  return resp.json();
}

async function cloudPost(env, path, body) {
  const resp = await fetch(`${CLOUD_API}${path}`, {
    method: 'POST',
    headers: cloudHeaders(env),
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
  if (repo) {
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

  // Add MCP servers (Tavily web search) if env var is set
  const tavilyKey = env.TAVILY_API_KEY || '';
  if (tavilyKey) {
    body.mcp_servers = [
      {
        name: 'tavily-search',
        url: 'https://tavily.com/api/mcp',
        env: { TAVILY_API_KEY: tavilyKey },
      },
    ];
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

  const resp = await fetch(`${CLOUD_API}/api/v1/app-conversations`, {
    method: 'POST',
    headers: cloudHeaders(env),
    body: JSON.stringify(body),
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`Create conv failed: ${resp.status}:${text.slice(0, 200)}`);
  }
  const data = await resp.json();

  // Direct response — may have conversation ID or start-task ID
  return {
    conversation_id: data.app_conversation_id || '',
    start_task_id: data.id || '',
    sandbox_id: data.sandbox_id || '',
  };
}

// ---------------------------------------------------------------------------
// Poll start-task endpoint for real conversation_id
// ---------------------------------------------------------------------------

async function pollForConvId(env, startTaskId) {
  for (let i = 0; i < 10; i++) {  // up to 50s
    await sleep(5000);
    try {
      const data = await cloudGet(env, `/api/v1/app-conversations/start-tasks?ids=${startTaskId}`);
      const items = Array.isArray(data) ? data : (data.items || []);
      if (items.length && items[0].app_conversation_id) {
        return { conversation_id: items[0].app_conversation_id, sandbox_id: items[0].sandbox_id || '' };
      }
    } catch (_) {}
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
    const resp = await fetch(`${CLOUD_API}/api/v1/app-conversations/${convId}/send-message`, {
      method: 'POST',
      headers: cloudHeaders(env),
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
          method: 'POST', headers: cloudHeaders(env),
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
    return { status: 'error', error: e.message };
  }
  const items = Array.isArray(data) ? data : (data.items || []);
  if (!items || !items.length) return { status: 'error', error: 'conversation not found' };

  const conv = items[0];
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
  const seen = new Set((state.seen_event_ids || []).map(String));
  let allText = '';
  let offset = 0;
  const limit = 100;
  const maxPages = 20;
  let foundNewAssistant = false;

  for (let page = 0; page < maxPages; page++) {
    let events;
    try {
      events = await cloudGet(env, `/api/v1/conversation/${convId}/events/search?limit=${limit}&offset=${offset}`);
    } catch (_) { break; }
    const list = Array.isArray(events) ? events : (events.events || events.items || []);
    if (!list.length) break;

    for (const evt of list) {
      const eid = String(evt.id || evt.event_id || '');
      const kind = evt.kind || evt.type || evt.event || '';
      const source = evt.source || '';
      const tool = evt.tool_name || evt.tool || evt.name || '';
      const ts = evt.timestamp || evt.created_at || now();

      // --- MessageEvent (assistant response) — NEVER skip via seen check ---
      // MessageEvents are tracked by whether their text was already extracted
      if (kind === 'MessageEvent' && source !== 'user') {
        const llmMsg = evt.llm_message || evt.message || null;
        if (!llmMsg) continue;
        let text = '';
        if (typeof llmMsg === 'string' && llmMsg.trim()) {
          text = llmMsg.trim();
        } else if (typeof llmMsg === 'object') {
          const content = llmMsg.content || [];
          if (Array.isArray(content)) {
            for (const block of content) {
              if (block && block.type === 'text' && block.text && block.text.trim()) {
                if (text) text += '\n';
                text += block.text.trim();
              }
            }
          } else if (typeof content === 'string' && content.trim()) {
            text = content.trim();
          }
        }
        if (text) {
          // Dedup by hash: don't re-extract same text
          const hash = simpleHash(text);
          if (!state._extracted_hashes) state._extracted_hashes = {};
          if (!state._extracted_hashes[hash]) {
            state._extracted_hashes[hash] = true;
            foundNewAssistant = true;
            if (allText) allText += '\n\n';
            allText += text;
          }
        }
        if (eid) seen.add(eid);
        continue;
      }

      // For non-MessageEvents: skip via seen check
      if (eid && seen.has(eid)) continue;
      if (eid) seen.add(eid);

      // Dedup tracking
      if (state.event_kinds?.[eid]) continue;
      if (!state.event_kinds) state.event_kinds = {};
      state.event_kinds[eid] = true;

      // --- AgentStateChangeEvent ---
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

      // --- ActionEvent (tool invocations) ---
      if (kind === 'ActionEvent') {
        let action = evt.action || evt.content || evt.message || {};
        if (typeof action === 'string') {
          try { action = JSON.parse(action); } catch { action = { content: action }; }
        }
        const cmd = (action.command || action.cmd || '').trim();
        const path = action.path || action.file || '';
        const query = action.query || '';

        let eventText = '';
        if (tool.includes('bash') || tool.includes('terminal') || tool.includes('execute')) {
          const snippet = cmd.slice(0, 200).replace(/\n/g, ' ').trim();
          eventText = `$ ${snippet}`;
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[TERMINAL] ${snippet}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
        } else if (tool.includes('file_editor') || tool.includes('str_replace')) {
          if (cmd === 'view') eventText = `Reading ${path}`;
          else if (cmd === 'create') eventText = `Creating ${path}`;
          else if (cmd === 'undo_edit') eventText = `Undoing ${path}`;
          else eventText = `Editing ${path}`;
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[EDIT] ${eventText}`, kind: 'SystemEvent', timestamp: typeof ts === 'number' ? ts : now() });
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

      // --- ObservationEvent (tool results) ---
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

      // --- ToolEvent / GenericEvent fallback ---
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
    if (list.length < limit) break;
    offset += limit;
  }

  state.seen_event_ids = Array.from(seen);
  // Save response text in state for crash recovery
  if (allText) state._pending_response = allText;

  // Silence detection: if conversation is completed but no MessageEvent found,
  // try to force /run on the ACP server (bug #14698 mitigation)
  if (!foundNewAssistant && allText) {
    // We have text from a previous collection — that's fine
    return allText;
  }

  return allText || null;
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
      console.error(`${method} ${path}:`, e.message, e.stack?.slice(0, 500));
      return json({ error: 'Something went wrong. Please try again.' }, 500);
    }
  },
};

async function route(method, path, url, request, env) {
  // Health
  if (path === '/api/health' && method === 'GET') {
    return json({ status: 'ok', timestamp: now() });
  }
  if (path === '/api/hello' && method === 'GET') {
    return json({ message: 'VibeCode Worker' });
  }
  // Clear queue — full reset (same as DELETE /api/chat without repo)
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
    const body = await request.json();
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
    if (!repo) return error('repo is required', 400);

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
      // Clear conversation references so any in-flight poll can't
      // accidentally resume processing after we cancel.
      state.conversation_id = null;
      state.sandbox_id = null;
      state.start_task_id = null;
      state.last_sent_position = -1;
      state._run_started_at = undefined;
    }
    await writeState(env, repo, state);
    return json({ ok: true });
  }

  // --- Task endpoints (stubs for app_shell + task_provider compatibility) ---

  // POST /api/prompts — create a reusable prompt (system prompt template)
  if (path === '/api/prompts' && method === 'POST') {
    const body = await request.json();
    return json({
      id: `prompt_${now()}`,
      prompt: body.prompt || '',
      repo: body.repo || '',
      branch: body.branch || '',
      mode: body.mode || 'code',
      status: 'pending',
      created_at: new Date().toISOString(),
    }, 201);
  }

  // GET /api/tasks — list saved prompts/tasks
  if (path === '/api/tasks' && method === 'GET') {
    return json({ tasks: [] });
  }

  // DELETE /api/tasks — delete all tasks
  if (path === '/api/tasks' && method === 'DELETE') {
    return json({ ok: true });
  }

  // /api/tasks/{id}... — individual task operations
  if (path.startsWith('/api/tasks/') && method === 'GET') {
    // GET /api/tasks/{id}
    return json({ id: path.split('/').pop(), status: 'completed', events: [] });
  }
  if (path.startsWith('/api/tasks/') && method === 'DELETE') {
    // DELETE /api/tasks/{id}
    return json({ ok: true });
  }
  if (path.includes('/retry') && method === 'POST') {
    // POST /api/tasks/{id}/retry
    return json({ ok: true });
  }
  if (path.includes('/events') && method === 'GET') {
    // GET /api/tasks/{id}/events
    return json({ events: [] });
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
    const hasPending = q.position < q.total && !q.cancelled;
    let convStatus = 'idle';

    // --- Phase: resolve start_task to conversation_id ---
    if (!state.conversation_id && state.start_task_id) {
      const result = await pollForConvId(env, state.start_task_id);
      if (result) {
        state.conversation_id = result.conversation_id;
        if (result.sandbox_id) state.sandbox_id = result.sandbox_id;
        state.start_task_id = null;
        await writeState(env, repo, state);
      }
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
        q.cancelled = true;
        state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] Failed to start agent. Please try again.`, kind: 'ErrorEvent', timestamp: now() });
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
        if (sendErr.startsWith('409')) {
          state.conversation_id = null;
          state.sandbox_id = null;
        }
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
      const pollResult = await pollConversation(env, state.conversation_id, state);
      convStatus = pollResult.status;

      // Update sandbox_id
      if (pollResult.sandbox_id) state.sandbox_id = pollResult.sandbox_id;

      // Crash protection: save state immediately after fetchResponse so
      // seen_event_ids + _pending_response survive a Worker crash.
      if (['completed', 'failed', 'error', 'stopped'].includes(pollResult.status)) {
        await writeState(env, repo, state);
      }

      if (pollResult.status === 'completed') {
        // Use _pending_response as fallback if Worker crashed after fetchResponse
        // (response was saved in state but pollResult.response may be stale on retry)
        const responseText = pollResult.response || state._pending_response;
        state._pending_response = undefined;

        if (responseText) {
          state.messages.push({ id: nextMsgId(state), role: 'assistant', content: responseText, timestamp: now() });
          // No [DONE] event — assistant response IS the completion signal.
          // (App groups consecutive events + assistant into one bubble;
          //  a trailing event would create a spurious second bubble.)
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

        // No response text found — retry with delays + force /run (matches Python backend behavior)
        let retryResponse = null;
        for (let attempt = 0; attempt < 3; attempt++) {
          // Wait before retry (3s, 5s, 8s)
          await sleep(attempt === 0 ? 3000 : attempt === 1 ? 5000 : 8000);

          // Fetch events again (new ones may have arrived)
          retryResponse = await fetchResponse(env, state.conversation_id, state);
          if (retryResponse) break;

          // On second retry, try force /run (agent might be stuck)
          if (attempt === 1) {
            try {
              const convData = await cloudGet(env, `/api/v1/app-conversations?ids=${state.conversation_id}`);
              const items = Array.isArray(convData) ? convData : (convData.items || []);
              if (items.length) {
                const acp = items[0].acp_server || '';
                const sk = items[0].session_api_key || '';
                if (acp && sk) {
                  await fetch(`${acp}/api/conversations/${state.conversation_id}/run`, {
                    method: 'POST', headers: { 'X-Session-API-Key': sk },
                  });
                }
              }
            } catch (_) {}
          }
        }

        if (retryResponse) {
          state.messages.push({ id: nextMsgId(state), role: 'assistant', content: retryResponse, timestamp: now() });
        } else {
          state.messages.push({ id: nextMsgId(state), role: 'event', content: '[ERROR] Task finished but no response text found', kind: 'ErrorEvent', timestamp: now() });
        }

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
        // Must return here so we don't fall through to the idle/running handlers
        return buildStateResponse(state, q, stillPending);
      } else if (pollResult.status === 'failed') {
        const errMsg = pollResult.error || 'unknown error';
        state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] Agent failed: ${errMsg.slice(0, 200)}`, kind: 'ErrorEvent', timestamp: now() });
        q.position++;
        q.done = Math.min(q.position, q.total);
        skipFutureCancelled(q);
        await writeState(env, repo, state);
      } else if (['idle', 'pending'].includes(pollResult.status) || (pollResult.status === 'completed' && !pollResult.response)) {
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
      } else {
        // Still running — show elapsed timer, update in-place (no repeated spam).
        // Uses _run_started_at as epoch for elapsed calculation.
        const nowMs = Date.now();
        if (!state._run_started_at) state._run_started_at = nowMs;
        const elapsed = Math.floor((nowMs - state._run_started_at) / 1000);
        const elapsedStr = elapsed < 60 ? `${elapsed}s` : `${Math.floor(elapsed / 60)}m${elapsed % 60}s`;

        // Find the last "Working" heartbeat and update in-place
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

        // Persist timer every 30s (not every poll — saves KV writes)
        const lastHb = state._last_heartbeat || 0;
        if (!lastHb || (nowMs - lastHb) > 28000) {
          state._last_heartbeat = nowMs;
          await writeState(env, repo, state);
        }
        // fetchResponse NOT called — all events fetched atomically at completion.
      }
    }

    // Build response
    return buildStateResponse(state, q, hasPending, repo, mode, convStatus);
  }

  // GET /api/logs — server log viewer (stub: returns empty for Worker, no local logs)
  if (path === '/api/logs' && method === 'GET') {
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
