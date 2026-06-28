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
  await env.VIBECODE.put(`state:${repo}`, JSON.stringify(state));
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

  for (let page = 0; page < maxPages; page++) {
    let events;
    try {
      events = await cloudGet(env, `/api/v1/conversation/${convId}/events/search?limit=${limit}&offset=${offset}`);
    } catch (_) { break; }
    const list = Array.isArray(events) ? events : (events.events || events.items || []);
    if (!list.length) break;

    for (const evt of list) {
      const eid = String(evt.id || evt.event_id || '');
      if (eid && seen.has(eid)) continue;
      if (eid) seen.add(eid);

      const kind = evt.kind || evt.type || evt.event || '';
      const text = evt.text || evt.message || evt.content || '';
      if ((kind === 'MessageEvent' || kind === 'message') && text && text.trim()) {
        if (allText) allText += '\n\n';
        allText += text.trim();
      }
    }
    if (list.length < limit) break;
    offset += limit;
  }

  state.seen_event_ids = Array.from(seen);
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
    last_event_index: 0,
    last_event_timestamp: '',
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

    // If all previous prompts finished, start fresh (replace queue)
    if (state.queue.position >= state.queue.total) {
      state.queue.prompts = [];
      state.queue.modes = [];
      state.queue.position = 0;
      state.queue.done = 0;
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
      // Cancel specific prompt — advance past it if it's current
      if (index === state.queue.position) {
        state.queue.position++;
        state.queue.done++;
      }
    } else {
      state.queue.cancelled = true;
      state.queue.position = state.queue.total;
      state.queue.done = state.queue.total;
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
          convStatus = 'starting';
        } else if (result.start_task_id) {
          state.start_task_id = result.start_task_id;
          convStatus = 'starting';
        }

        // Save LLM model info
        const cfg = await readConfig(env);
        state.llm_model = cfg.model || '';
        state.configured_model = cfg.model || '';

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

    // --- Phase: poll Cloud API for agent status ---
    if (state.conversation_id && hasPending) {
      const pollResult = await pollConversation(env, state.conversation_id, state);
      convStatus = pollResult.status;

      // Update sandbox_id
      if (pollResult.sandbox_id) state.sandbox_id = pollResult.sandbox_id;

      if (pollResult.status === 'completed' && pollResult.response) {
        // Save assistant response
        state.messages.push({ id: nextMsgId(state), role: 'assistant', content: pollResult.response, timestamp: now() });
        state.messages.push({ id: nextMsgId(state), role: 'event', content: '[DONE] Task completed', kind: 'SystemEvent', timestamp: now() });

        // Advance queue
        q.position++;
        q.done = Math.min(q.position, q.total);

        // If more prompts, send next one
        if (q.position < q.total && !q.cancelled) {
          const nextPrompt = q.prompts[q.position];
          const nextMode = q.modes[q.position] || mode;
          // Don't await — fire-and-forget. Next /state poll will check status.
          sendMessage(env, state.conversation_id, nextPrompt, state.sandbox_id)
            .catch(e => console.error(`sendMessage error: ${e}`));
        }

        await writeState(env, repo, state);
      } else if (pollResult.status === 'failed') {
        const errMsg = pollResult.error || 'unknown error';
        state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] Agent failed: ${errMsg.slice(0, 200)}`, kind: 'ErrorEvent', timestamp: now() });
        q.position++;
        q.done = Math.min(q.position, q.total);
        await writeState(env, repo, state);
      } else if (['idle', 'pending'].includes(pollResult.status)) {
        // Conversation is idle but queue has work. This means either:
        // 1. send-message was never called
        // 2. send-message failed
        // → Try sending the current prompt
        if (convStatus !== 'starting') {
          const currentPrompt = q.prompts[q.position];
          const sendErr = await sendMessage(env, state.conversation_id, currentPrompt, state.sandbox_id);
          if (sendErr) {
            console.error(`sendMessage idle-retry error: ${sendErr}`);
          } else {
            convStatus = 'running';
          }
        }
        await writeState(env, repo, state);
      } else {
        // Still running — save seen event IDs update if poll changed them
        await writeState(env, repo, state);
      }
    }

    // Build response
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

  // --- Misc stubs ---

  // POST /api/fcm-token — Firebase push notification token (stub)
  if (path === '/api/fcm-token' && method === 'POST') {
    return json({ ok: true });
  }

  // PUT /api/config/git — git user config (stub, git not used in Worker)
  if (path === '/api/config/git' && method === 'PUT') {
    return json({ ok: true, name: '', email: '' });
  }
  // GET /api/config/git
  if (path === '/api/config/git' && method === 'GET') {
    return json({ name: '', email: '' });
  }

  return json({ error: `Not found: ${method} ${path}` }, 404);
}
