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

// Record a conversation change reason for the UI to display.
// Called whenever conversation_id is set (new conv) or cleared (reset).
function recordConvChange(state, reason) {
  state._last_conv_change_reason = reason;
  state._last_conv_change_at = new Date().toISOString();
  state._dirty = true;
  console.log(`[CONV-CHANGE] ${reason}`);
}

// ---------------------------------------------------------------------------
// KV state helpers
// ---------------------------------------------------------------------------

async function readState(env, repo) {
  const raw = await env.VIBECODE.get(`state:${repo}`);
  if (!raw) { console.log(`[KV] readState(${repo}): MISS — no state found`); return null; }
  try { return JSON.parse(raw); } catch (e) { console.error(`[KV] readState(${repo}): PARSE ERROR — ${e.message}`); return null; }
}

/** Trim state in-place before writing to KV to stay under size limits. */
function trimState(state) {
  if (state.messages && state.messages.length > 5000) {
    const before = state.messages.length;
    state.messages = state.messages.slice(-4000);
    console.log(`[KV] trimState: messages trimmed ${before}→${state.messages.length}`);
  }
  if (state.event_kinds && Object.keys(state.event_kinds).length > 1000) {
    console.log(`[KV] trimState: event_kinds reset (${Object.keys(state.event_kinds).length} keys)`);
    state.event_kinds = {};
  }
  if (state._extracted_hashes && Object.keys(state._extracted_hashes).length > 100) {
    console.log(`[KV] trimState: _extracted_hashes reset (${Object.keys(state._extracted_hashes).length} keys)`);
    state._extracted_hashes = {};
  }
  if (state.seen_event_ids && state.seen_event_ids.length > 2000) {
    const before = state.seen_event_ids.length;
    state.seen_event_ids = state.seen_event_ids.slice(-1500);
    console.log(`[KV] trimState: seen_event_ids trimmed ${before}→${state.seen_event_ids.length}`);
  }
  if (state._batch_skip && Object.keys(state._batch_skip).length > 100) {
    console.log(`[KV] trimState: _batch_skip cleared (${Object.keys(state._batch_skip).length} keys)`);
    state._batch_skip = undefined;
  }
}

async function writeState(env, repo, state) {
  trimState(state);
  try {
    await env.VIBECODE.put(`state:${repo}`, JSON.stringify(state));
    return true;
  } catch (e) {
    console.error(`[KV] writeState(${repo}): WRITE FAILED — ${e.message || e}`);
    return false;
  }
}

/** Write state to KV only if the dirty flag is set. Clears flag only on success. */
async function writeStateIfDirty(env, repo, state) {
  if (!state._dirty) return;
  const ok = await writeState(env, repo, state);
  if (ok) state._dirty = false;
}

// Re-read queue total from KV to catch prompts appended by the user
// while this poll was processing. The in-memory q.total was loaded at
// poll start and may be stale. Without this, stillPending = position <
// stale_total is false, and the follow-up prompt is silently lost.
async function syncQueueFromKv(env, repo, q) {
  try {
    const raw = await env.VIBECODE.get(`state:${repo}`);
    if (!raw) return;
    const fresh = JSON.parse(raw);
    if (!fresh?.queue) return;
    if (fresh.queue.total > q.total) {
      console.log(`[SYNC] repo=${repo}: merged queue total ${q.total}→${fresh.queue.total}`);
      q.total = fresh.queue.total;
      q.prompts = fresh.queue.prompts || q.prompts;
      q.modes = fresh.queue.modes || q.modes;
    }
  } catch (_) {}
}

function buildStateResponse(state, q, hasPending, repo, mode, convStatus) {
  // Dedup messages: KV eventual consistency can cause the same assistant
  // response to be pushed twice when a previous poll's state write hasn't
  // propagated by the next poll's read. Content-based dedup prevents
  // duplicate assistant messages from appearing in the UI.
  const msgs = state.messages || [];
  const messages = [];
  const seenAsstContent = new Set();
  let dedupConsecutive = 0;
  let dedupAsstContent = 0;
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i];
    // Filter heartbeat/STATUS events — they're internal progress indicators,
    // not chat bubbles. The Flutter UI has its own progress tracking via batch
    // state (position/total/done) and doesn't need these inline.
    if (m.role === 'event' && m.content && m.content.includes('[STATUS]')) {
      continue;
    }
    // Skip consecutive event messages with identical content
    // (cold start can reprocess events, creating duplicates in memory)
    if (m.role === 'event' && i > 0) {
      const prev = msgs[i - 1];
      if (prev.role === 'event' && prev.content === m.content) { dedupConsecutive++; continue; }
    }
    // Content-based dedup for assistant messages: KV eventual consistency
    // can cause the same response text to be pushed twice with different
    // IDs. Keeping only the first occurrence prevents duplicates.
    if (m.role === 'assistant' && m.content) {
      if (seenAsstContent.has(m.content)) { dedupAsstContent++; continue; }
      seenAsstContent.add(m.content);
    }
    messages.push(m);
  }
  console.log(`[RESP] repo=${repo}: returning ${messages.length} msgs (dedup: ${dedupConsecutive} consecutive+${dedupAsstContent} content) | batch pos=${q.position||0}/${q.total||0} done=${q.done||0} running=${hasPending && (!!state.conversation_id || !!state.start_task_id)} convStatus=${convStatus} convId=${(state.conversation_id||'').slice(0,12)}`);
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
    conversation_change: (state._last_conv_change_reason && state._last_conv_change_at)
      ? { reason: state._last_conv_change_reason, at: state._last_conv_change_at }
      : null,
    batch: {
      running: hasPending && (!!state.conversation_id || !!state.start_task_id),
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

async function createConversation(env, prompt, repo, branch, mode, state) {
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

  // Inject previous chat context when creating a new conversation.
  // Include user/assistant exchanges (last 30, 5000 chars each) plus
  // a concise tool-activity summary reconstructed from SystemEvents.
  if (state && state.messages && state.messages.length > 0) {
    const exchanges = [];
    for (const m of state.messages) {
      const role = m.role || '';
      if (role !== 'user' && role !== 'assistant') continue;
      const content = (m.content || '').trim();
      if (!content) continue;
      exchanges.push(`${role === 'user' ? 'User' : 'Assistant'}: ${content.slice(0, 5000)}`);
    }
    if (exchanges.length > 30) exchanges.splice(0, exchanges.length - 30);

    // Build a tool-activity summary from SystemEvent entries.
    // These contain [EDIT], [READ], [TERMINAL], [FILE], [BROWSER],
    // [SEARCH], [OUT], [WARN], [INFO] prefixes recorded by processCloudEvents.
    const toolLines = [];
    const seenToolKeys = new Set();
    for (const m of state.messages) {
      const text = (m.content || '').trim();
      if (!text) continue;
      // Only SystemEvent entries carry tool activity.
      // The first token (e.g. "[EDIT]") identifies the type.
      const prefix = text.match(/^\[([A-Z]+)\]/)?.[1];
      if (!prefix) continue;
      // Dedup identical lines that appear more than once.
      if (seenToolKeys.has(text)) continue;
      seenToolKeys.add(text);
      // Collect: file reads/edits, terminal commands, browser activity,
      // search queries, file diffs, build output.
      if (prefix === 'EDIT' || prefix === 'READ' || prefix === 'CREATE' ||
          prefix === 'FILE' || prefix === 'BROWSER' || prefix === 'SEARCH' ||
          prefix === 'TOOL') {
        toolLines.push(`  • ${text}`);
      }
    }
    // Keep at most the last 50 tool entries to avoid bloating the prompt.
    if (toolLines.length > 50) toolLines.splice(0, toolLines.length - 50);

    if (exchanges.length > 0 || toolLines.length > 0) {
      let ctx = '[Previous conversation context:]\n';
      if (exchanges.length > 0) {
        ctx += exchanges.join('\n\n');
      }
      if (toolLines.length > 0) {
        ctx += '\n\n[Tool activity in previous conversation:]\n';
        ctx += toolLines.join('\n');
      }
      fullPrompt = `${ctx}\n\n---\n\n${fullPrompt}`;
    }
  }

  const cfg = await readConfig(env);
  const model = cfg.model || env.LLM_MODEL || 'deepseek/deepseek-v4-flash';
  const body = {
    initial_message: { content: [{ type: 'text', text: fullPrompt }] },
    title: prompt.slice(0, 80),
    llm_model: model,
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

  const t0 = Date.now();
  console.log(`[CONV] repo=${repo}: creating conversation — model=${model} promptLen=${fullPrompt.length} mcp=${mcpServers.map(s=>s.name).join(',')||'none'} repo=${repo} branch=${effectiveBranch}`);
  const resp = await fetchWithTimeout(`${CLOUD_API}/api/v1/app-conversations`, {
    method: 'POST',
    headers: await cloudHeaders(env),
    body: JSON.stringify(body),
  });
  if (!resp.ok) {
    const text = await resp.text();
    const err = new Error(`Create conv failed: ${resp.status}:${text.slice(0, 200)}`);
    console.error(`[CONV] repo=${repo}: create FAILED — ${resp.status} (${Date.now()-t0}ms)`);
    throw err;
  }
  const data = await resp.json();

  // Match agent_runner.py exactly: 'app_conversation_id' is the real conversation ID.
  // 'id' is the START TASK ID — never use it as a conversation_id.
  const directId = data.app_conversation_id || data.conversation_id || '';
  const taskId = data.id || data.start_task_id || '';
  const sboxId = data.sandbox_id || '';
  console.log(`[CONV] repo=${repo}: created — convId=${directId.slice(0,12)} startTaskId=${taskId.slice(0,12)} sandboxId=${sboxId.slice(0,12)} (${Date.now()-t0}ms)`);
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
  const t0 = Date.now();
  console.log(`[SEND] conv=${convId.slice(0,12)}: sending msg (${prompt.length} chars) sandboxId=${(sandboxId||'').slice(0,12)}`);
  let lastErr = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    let resp;
    try {
      resp = await fetchWithTimeout(`${CLOUD_API}/api/v1/app-conversations/${convId}/send-message`, {
        method: 'POST',
        headers: await cloudHeaders(env),
        body: JSON.stringify(body),
      }, 120000);  // send-message needs longer timeout (reference uses 120s)
    } catch (e) {
      // Timeout or network error — return error string, don't throw
      lastErr = e.name === 'AbortError' ? 'send-message timed out' : `send-message failed: ${e.message}`;
      console.error(`[SEND] conv=${convId.slice(0,12)}: ${lastErr} (${Date.now()-t0}ms)`);
      break;
    }
    if (resp.ok) {
      // Match reference: check success field in response body
      try {
        const data = await resp.json();
        if (data.success === false) {
          const sbStatus = data.sandbox_status || 'unknown';
          lastErr = `send-message rejected (sandbox=${sbStatus})`;
          console.error(`[SEND] conv=${convId.slice(0,12)}: ${lastErr} (${Date.now()-t0}ms)`);
          break;
        }
      } catch (_) {}
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
              console.log(`[SEND] conv=${convId.slice(0,12)}: triggering /run (agent stuck in ${status})`);
              fetch(`${acp}/api/conversations/${convId}/run`, {
                method: 'POST',
                headers: { 'X-Session-API-Key': sk },
              }).catch(() => {});
            }
          }
        }
      } catch (_) {}
      console.log(`[SEND] conv=${convId.slice(0,12)}: OK (${Date.now()-t0}ms)`);
      return null;  // success
    }
    if (resp.status === 409 && attempt === 0 && sandboxId) {
      console.log(`[SEND] conv=${convId.slice(0,12)}: 409 — resuming sandbox ${sandboxId.slice(0,12)}`);
      try {
        const r = await fetch(`${CLOUD_API}/api/v1/sandboxes/${sandboxId}/resume`, {
          method: 'POST', headers: await cloudHeaders(env),
        });
        if (!r.ok) {
          const txt = await r.text().catch(() => '');
          lastErr = `${r.status}:${txt.slice(0, 200)}`;
          console.error(`[SEND] conv=${convId.slice(0,12)}: sandbox resume failed — ${lastErr}`);
          break;
        }
        // Poll sandbox status until RUNNING (up to ~20s, every 2s).
        // Without this, send-message retry immediately gets another 409
        // because the sandbox is still STARTING.
        const deadline = Date.now() + 20000;
        while (Date.now() < deadline) {
          await sleep(2000);
          try {
            const sr = await fetch(
              `${CLOUD_API}/api/v1/sandboxes/search?sandbox_id=${sandboxId}`,
              { headers: await cloudHeaders(env) }
            );
            if (sr.ok) {
              const sd = await sr.json();
              const list = Array.isArray(sd) ? sd : (sd.items || []);
              const status = (list[0] && list[0].status) || '';
              if (status === 'RUNNING') break;  // sandbox ready, retry send-message
            }
          } catch (_) {}
        }
        continue;  // retry send-message
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
    // Query events using the correct API parameter timestamp__gte (NOT
    // min_timestamp!). Use the conversation's updated_at as a window start
    // so we only fetch the recent events cluster.
    const cutoff = state._last_response_ts || '';
    console.log(`[POLL] conv=${convId}: status=${execStatus} — searching events (cutoff=${(cutoff||'none').slice(0,24)})`);
    try {
      const updatedMs = conv.updated_at ? new Date(conv.updated_at).getTime() : Date.now();
      if (!isNaN(updatedMs)) {
        // Query from 60s before updated_at — captures the current turn's events
        const windowStart = new Date(updatedMs - 60000).toISOString();
        let pageUrl = `/api/v1/conversation/${convId}/events/search?limit=100&timestamp__gte=${encodeURIComponent(windowStart)}&sort_order=TIMESTAMP`;
        for (let page = 0; page < 10; page++) {
          const data = await cloudGet(env, pageUrl);
          const items = data.items || data.events || (Array.isArray(data) ? data : []);
          if (!items.length) break;
          // Scan from end for agent's MessageEvent (most recent first)
          for (let i = items.length - 1; i >= 0; i--) {
            const evt = items[i];
            const source = evt.source || '';
            const kind = evt.kind || evt.type || evt.event || '';
            if ((kind === 'MessageEvent' || kind === 'message') && source !== 'user') {
              const msg = evt.llm_message || evt.message || evt.content || {};
              let text = '';
              if (typeof msg === 'string' && msg.trim()) {
                text = msg.trim();
              } else if (Array.isArray(msg)) {
                for (const block of msg) {
                  if (block?.text?.trim()) text += (text ? '\n' : '') + block.text.trim();
                  else if (block?.content?.trim()) text += (text ? '\n' : '') + block.content.trim();
                  else if (typeof block === 'string' && block.trim()) text += (text ? '\n' : '') + block.trim();
                }
              } else if (typeof msg === 'object') {
                const c = msg.content || [];
                if (Array.isArray(c)) {
                  for (const block of c) {
                    if (block?.type === 'text' && block.text?.trim()) text += (text ? '\n' : '') + block.text.trim();
                  }
                } else if (typeof c === 'string' && c.trim()) {
                  text = c.trim();
                }
              }
              if (text) {
                // Skip events older than last consumed response (prevents
                // sending stale response to a new prompt)
                const msgTs = evt.timestamp || evt.created_at || '';
                const cutoff = state._last_response_ts || '';
                if (cutoff && msgTs && String(msgTs) <= String(cutoff)) continue;
                console.log(`[POLL] conv=${convId}: found response via timestamp__gte (${text.length} chars, page ${page})`);
                return { status: 'completed', response: text, sandbox_id: sandboxId };
              }
            }
          }
          if (!data.next_page_id) break;
          pageUrl = `/api/v1/conversation/${convId}/events/search?limit=100&page_id=${encodeURIComponent(data.next_page_id)}`;
        }
      }
    } catch (e) {
      console.log(`[POLL] conv=${convId}: events/search failed: ${e.message}`);
    }
    console.log(`[POLL] conv=${convId}: completed but no response found (cutoff=${cutoff}, updated_at=${conv.updated_at})`);
    return { status: 'completed', response: null, sandbox_id: sandboxId };
  }

  if (['failed', 'error', 'stopped'].includes(execStatus)) {
    console.log(`[POLL] conv=${convId}: status=${execStatus} error=${(conv.error_message||conv.error||'').slice(0,80)}`);
    return { status: 'failed', error: conv.error_message || conv.error || execStatus, sandbox_id: sandboxId };
  }

  console.log(`[POLL] conv=${convId}: status=${execStatus||'pending'} (unhandled — treating as pending)`);
  return { status: execStatus || 'pending', sandbox_id: sandboxId };
}

async function fetchResponse(env, convId, state) {
  // Paginate events/search to handle 100+ events.
  // events/search does NOT support offset (returns 422), max limit=100.
  //
  // Uses _last_response_ts as cutoff. Only MessageEvents with timestamp
  // STRICTLY AFTER _last_response_ts are considered new. This avoids the
  // pagination-stuck-at-100-events issue (fetchResponse fetches ALL pages
  // from the beginning) and doesn't depend on _last_event_ts staying unstuck.
  //
  // Without this, fetchResponse returns the previous turn's MessageEvent instead
  // of waiting for the current turn to finish.
  try {
    // Use _last_response_ts as cutoff. Only MessageEvents with timestamp
    // STRICTLY AFTER _last_response_ts are considered new. This avoids the
    // pagination-stuck-at-100-events issue (fetchResponse fetches ALL pages),
    // and doesn't depend on _last_event_ts staying un-stuck.
    const cutoffTs = state._last_response_ts || '';
    console.log(`[FETCH] conv=${convId}: calling fetchResponse (cutoff=${cutoffTs}, _last_event_ts=${state._last_event_ts})`);
    // Start from _last_event_ts (latest processed event by processCloudEvents),
    // not from the beginning. This avoids fetching 100s of old events and hitting
    // the 20-page cap. processCloudEvents runs before this is called, so
    // _last_event_ts is already at the newest processed event.
    let minTs = state._last_event_ts || '';
    let bestText = null;  // newest MessageEvent text across all pages
    let bestTs = '';

    for (let page = 0; page < 20; page++) {
      const url = minTs
        ? `/api/v1/conversation/${convId}/events/search?limit=100&timestamp__gte=${encodeURIComponent(minTs)}`
        : `/api/v1/conversation/${convId}/events/search?limit=100`;
      const data = await cloudGet(env, url);
      const list = Array.isArray(data) ? data : (data.events || data.items || []);
      console.log(`[FETCH] conv=${convId}: page ${page} got ${list.length} events${minTs ? ` (cursor="${minTs}")` : ''}`);
      if (!list.length) { console.log(`[FETCH] conv=${convId}: page ${page} empty — breaking`); break; }

      // Check each event in this batch (reversed = most recent first)
      for (let i = list.length - 1; i >= 0; i--) {
        const evt = list[i];
        const kind = evt.kind || evt.type || evt.event || '';
        const source = evt.source || '';

        if (kind === 'MessageEvent' && source !== 'user') {
          // Skip old responses: only events timestamp > last_response_ts are new
          const msgTs = evt.timestamp || evt.created_at || '';
          const strMsgTs = String(msgTs);
          const strCutoff = String(cutoffTs);
          const isOld = cutoffTs && msgTs && strMsgTs <= strCutoff;
          console.log(`[FETCH] conv=${convId}: MessageEvent ts="${strMsgTs}" cutoff="${strCutoff}" cmp="${strMsgTs}" <= "${strCutoff}" → ${isOld}`);
          if (isOld) {
            console.log(`[FETCH] conv=${convId}: SKIPPING old MessageEvent at ts=${strMsgTs} (last_response=${cutoffTs})`);
            continue;
          }
          const msg = evt.llm_message || evt.message || evt.content || {};
          let text = '';
          if (typeof msg === 'string' && msg.trim()) {
            text = msg.trim();
          } else if (Array.isArray(msg)) {
            const parts = [];
            for (const block of msg) {
              if (block && typeof block === 'object') {
                const t = block.text || block.content || '';
                if (t && String(t).trim()) parts.push(String(t).trim());
              } else if (typeof block === 'string' && block.trim()) {
                parts.push(block.trim());
              }
            }
            if (parts.length) text = parts.join('\n');
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
          if (text) {
            // Don't return yet — keep scanning for newer events.
            // If this MessageEvent is newer than our best so far, track it.
            if (!bestTs || strMsgTs > bestTs) {
              bestText = text;
              bestTs = strMsgTs;
              console.log(`[FETCH] conv=${convId}: tracking MessageEvent (${text.length} chars, ts=${strMsgTs})`);
            }
            continue;
          }
        }

        // Case 2: FinishAction — agent finished with message (no MessageEvent emitted).
        // Format: kind="FinishAction" or ActionEvent with action/tool_name="finish".
        // FinishAction is always the terminal event — return it immediately.
        const isFinish =
          kind === 'FinishAction' ||
          (kind === 'ActionEvent' && (evt.action === 'finish' || evt.tool_name === 'finish' || evt.name === 'finish'));
        if (isFinish) {
          const text =
            (typeof evt.message === 'string' && evt.message.trim() ? evt.message.trim() : '') ||
            (evt.args?.outputs?.content || '') ||
            (evt.args?.outputs?.response || '') ||
            (evt.args?.outputs?.text || '') ||
            (evt.content || '') ||
            (evt.text || '') ||
            (evt.output || '');
          if (text) {
            console.log(`[FETCH] conv=${convId}: found FinishAction (${text.length} chars) after ${page} pages`);
            return text;
          }
          console.log(`[FETCH] conv=${convId}: FinishAction found but text is EMPTY (ts=${evt.timestamp}, page=${page})`);
        }
      }

      // Advance to next page using the last event's timestamp
      const lastTs = list[list.length - 1].timestamp || list[list.length - 1].created_at || '';
      if (!lastTs) break;
      const strLast = String(lastTs);
      if (minTs && strLast === String(minTs)) {
        // Bump by 1ms. CRITICAL: remove Z suffix — the Cloud API returns
        // timestamps WITHOUT Z (eg '2026-06-29T04:16:17.755274') and does
        // NOT filter by min_timestamp when the value has Z suffix, causing
        // the API to return the same page (infinite loop).
        const d = new Date(strLast.endsWith('Z') ? strLast : strLast + 'Z');
        if (!isNaN(d.getTime())) {
          const beforeStr = minTs;
          minTs = new Date(d.getTime() + 1).toISOString().replace('Z', '');
          console.log(`[FETCH/CLOUD] Bump: "${beforeStr}" → "${minTs}" (d=${d.toISOString()})`);
          continue;
        }
      }
      minTs = strLast;
    }
    // After scanning all pages, return the newest non-user MessageEvent (if any).
    // This avoids returning an early "I'll implement this..." thought from page 0
    // instead of the final response on a later page.
    if (bestText) {
      console.log(`[FETCH] conv=${convId}: returning newest MessageEvent (${bestText.length} chars, ts=${bestTs})`);
      return bestText;
    }
    console.log(`[FETCH] conv=${convId}: no MessageEvent after ${page} pages`);
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
  const t0 = Date.now();
  let totalEvents = 0;
  let newEvents = 0;
  let kindCounts = {};
  try {
    // Paginate through ALL pages (not just the first 100). events/search max
    // limit=100, no offset support — use min_timestamp cursor.
    let minTs = state._last_event_ts || '';
    for (let page = 0; page < 20; page++) {
      const url = minTs
        ? `/api/v1/conversation/${convId}/events/search?limit=100&timestamp__gte=${encodeURIComponent(minTs)}`
        : `/api/v1/conversation/${convId}/events/search?limit=100`;
      const data = await cloudGet(env, url);
      const list = Array.isArray(data) ? data : (data.events || data.items || []);
      if (!list.length) break;

      // We have events — state will be modified below.
      state._dirty = true;

      // Update _last_event_ts for the next page/next poll.
      const lastTs = list[list.length - 1].timestamp || list[list.length - 1].created_at || '';
      if (lastTs) {
        console.log(`[CLOUD] conv=${convId}: advancing _last_event_ts: ${state._last_event_ts} → ${String(lastTs)} (page ${page}, ${list.length} events)`);
        state._last_event_ts = String(lastTs);
      }

      // Process events on this page
      for (const evt of list) {
        const eid = String(evt.id || evt.event_id || '');
        const kind = evt.kind || evt.type || evt.event || '';
        const source = evt.source || '';
        const tool = evt.tool_name || evt.tool || evt.name || '';
        const ts = evt.timestamp || evt.created_at || now();

        totalEvents++;
        kindCounts[kind] = (kindCounts[kind] || 0) + 1;

        // Register dedup for MessageEvents too (so fetchResponse can skip old
        // ones when looking for the current turn's response). Without this, when
        // a new prompt is sent to an existing conversation, fetchResponse finds
        // the previous turn's MessageEvent and returns it — skipping the new one.
        if (kind === 'MessageEvent') {
          if (eid && seen.has(eid)) continue;  // skip already-seen
          if (eid) seen.add(eid);  // register for future dedup
          continue;  // don't process as UI event
        }

        // Track already-seen events by ID (registered AFTER MessageEvent skip)
        if (eid && seen.has(eid)) continue;
        if (eid) seen.add(eid);

        newEvents++;

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
          } else if (tool === 'finish' || tool === 'completed') {
            // Store finish message as potential response fallback (for cases
            // where no MessageEvent was emitted). Skip creating a subtask event.
            const finishMsg = action.message || action.content || '';
            if (finishMsg) state._finish_message = finishMsg;
            continue;
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

      // Advance pagination cursor using the ACTUAL last event's timestamp
      const lastEvtTs = list[list.length - 1].timestamp || list[list.length - 1].created_at || '';
      if (!lastEvtTs) break;
      const strLast = String(lastEvtTs);
      if (minTs && strLast === String(minTs)) {
        // CRITICAL: remove Z suffix — Cloud API doesn't filter by min_timestamp
        // when value has Z, returning the same page (infinite loop).
        const d = new Date(strLast.endsWith('Z') ? strLast : strLast + 'Z');
        if (!isNaN(d.getTime())) {
          const beforeStr = minTs;
          minTs = new Date(d.getTime() + 1).toISOString().replace('Z', '');
          console.log(`[CLOUD] Bump: "${beforeStr}" → "${minTs}" (d=${d.toISOString()})`);
          continue;
        }
      }
      minTs = strLast;
    }
  } catch (_) {}

  const kindSummary = Object.entries(kindCounts).map(([k,v]) => `${k}=${v}`).join(' ');
  console.log(`[CLOUD] conv=${convId}: processed ${totalEvents} events (${newEvents} new, ${totalEvents-newEvents} skipped) — ${kindSummary} (${Date.now()-t0}ms)`);
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
    // Find the last assistant MessageEvent or FinishAction
    let responseText = '';
    for (const evt of list) {
      const kind = evt.kind || evt.type || evt.event || '';
      const source = evt.source || '';
      if (source === 'user') continue;

      // Check for MessageEvent
      if (kind === 'MessageEvent') {
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

      // Check for FinishAction (no MessageEvent emitted)
      const isFinish =
        kind === 'FinishAction' ||
        (kind === 'ActionEvent' && (evt.action === 'finish' || evt.tool_name === 'finish' || evt.name === 'finish'));
      if (isFinish) {
        const text =
          (typeof evt.message === 'string' && evt.message.trim() ? evt.message.trim() : '') ||
          (evt.args?.outputs?.content || '') ||
          (evt.args?.outputs?.response || '') ||
          (evt.args?.outputs?.text || '') ||
          (evt.content || '') ||
          (evt.text || '') ||
          (evt.output || '');
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
    _last_response_ts: '',
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

  // Cron trigger: poll all active queues every 30s so batch processing
  // continues even when the Flutter app is closed on the user's device.
  async scheduled(controller, env, ctx) {
    console.log('[CRON-START] scheduled run firing');
    let list;
    try {
      list = await env.VIBECODE.list({ prefix: 'state:' });
      console.log(`[CRON] found ${list.keys.length} state keys`);
    } catch (e) {
      console.error(`[CRON] LIST ERROR: ${e.message}`);
      return;
    }
    let active = 0;
    for (const key of list.keys) {
      const repo = key.name.slice(6);
      let state;
      try {
        state = await readState(env, repo);
      } catch (e) {
        console.error(`[CRON] readState error for ${repo}: ${e.message}`);
        continue;
      }
      if (!state || !state.queue) continue;
      if (state.queue.position >= state.queue.total || state.queue.cancelled) continue;
      active++;
      console.log(`[CRON] ACTIVE repo=${repo} pos=${state.queue.position}/${state.queue.total} mode=${state.mode||'code'}`);
      try {
        const url = new URL(`https://localhost/api/chat?repo=${encodeURIComponent(repo)}&mode=${state.mode || 'code'}`);
        const req = new Request(url, { method: 'GET' });
        const resp = await route('GET', '/api/chat', url, req, env);
        const body = await resp.text();
        console.log(`[CRON] repo=${repo} status=${resp.status} bodyPrefix=${body.slice(0,100)}`);
      } catch (e) {
        console.error(`[CRON] repo=${repo} POLL ERROR: ${e.message} stack=${(e.stack||'').slice(0,200)}`);
      }
    }
    console.log(`[CRON-END] done — ${active} active queue(s) polled`);
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
      try { await env.VIBECODE.delete(`lsp:${repo}`); } catch (_) {}
      state._batch_skip = undefined;
      state._run_started_at = undefined;
      state._error_retry = 0;  // reset retry counter for next batch
      state._send_retry = 0;
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
      await writeState(env, repo, state);
    }
    return json({ ok: true, message: `Batch cancelled for ${repo}. Chat history preserved.` });
  }

  // Start a fresh conversation — clears current conv but keeps chat history
  if (path === '/api/chat/new-conversation' && method === 'POST') {
    const repo = url.searchParams.get('repo') || '';
    if (!repo) return error('repo is required', 400);
    const state = await readState(env, repo);
    if (state) {
      state.conversation_id = null;
      state._last_event_ts = "";
      state.sandbox_id = null;
      state.last_sent_position = -1;
      state.start_task_id = null;
      state._run_started_at = undefined;
      state._error_retry = 0;
      state._send_retry = 0;
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
      state._retry_at = undefined;
      // Cancel any running batch
      state.queue.cancelled = true;
      state._dirty = true;
      recordConvChange(state, 'You started a new conversation');
      try { await env.VIBECODE.delete(`cid:${repo}`); } catch (_) {}
      try { await env.VIBECODE.delete(`lsp:${repo}`); } catch (_) {}
      await writeState(env, repo, state);
    }
    return json({ ok: true, message: `New conversation started for ${repo}.` });
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
      // Also clean up repo-keyed tiny keys so next poll starts fresh
      // (cid restores old conversation_id, causing new messages to be
      //  sent to a stale conversation that may not respond).
      try { await env.VIBECODE.delete(`cid:${repo}`).catch(() => {}); } catch (_) {}
      try { await env.VIBECODE.delete(`lsp:${repo}`).catch(() => {}); } catch (_) {}
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
    // If all previous prompts finished OR were cancelled, start fresh (replace queue)
    if (state.queue.position >= state.queue.total || state.queue.cancelled) {
      state.queue.prompts = [];
      state.queue.modes = [];
      state.queue.position = 0;
      state.queue.done = 0;
      state.queue.cancelled = false;
      state.last_sent_position = -1;
      try { await env.VIBECODE.delete(`lsp:${repo}`); } catch (_) {}
      // Delete stale queue position tiny keys from the previous batch.
      // qpos/qdon have 86400s TTL and survive POST reset. Without this, the
      // next poll's qpos restore sees qpos=1 (from old completed batch) and
      // restores q.position to 1 — making hasPending=false and showing
      // "1/1 done" without ever sending the new message.
      if (state.conversation_id) {
        try { await env.VIBECODE.delete(`qpos:${state.conversation_id}`).catch(() => {}); } catch (_) {}
        try { await env.VIBECODE.delete(`qdon:${state.conversation_id}`).catch(() => {}); } catch (_) {}
      }
      // Delete cid tiny key — prevents stale conversation_id from being
      // restored, which causes send-follow-up to send to a completed
      // conversation (agent doesn't start), then after 3 retries a new
      // conversation is created and the prompt is sent AGAIN.
      try { await env.VIBECODE.delete(`cid:${repo}`).catch(() => {}); } catch (_) {}
      // Clear conversation_id — each new batch must start with a FRESH
      // conversation.
      state.conversation_id = null;
      recordConvChange(state, 'Starting new task');
      state._dirty = true;
      state._last_event_ts = "";
      state.sandbox_id = null;
      state._run_started_at = undefined;
      state._completed_position = undefined;
      state._error_retry = 0;  // reset retry counter for new batch
      state._send_retry = 0;
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
      if (state.conversation_id) {
        try { await env.VIBECODE.delete(`retry:${state.conversation_id}`).catch(() => {}); } catch (_) {}
      }
    }
    state.queue.prompts.push(prompt);
    state.queue.modes.push(mode);
    state.queue.total = state.queue.prompts.length;
    // Write to KV directly (not writeState) so we can detect failure and
    // return an error to the client — if the queue state wasn't persisted,
    // the message is lost forever (next poll reads old state from KV).
    // Trim first so JSON.stringify doesn't exceed CPU/memory limits.
    trimState(state);
    try {
      await env.VIBECODE.put(`state:${repo}`, JSON.stringify(state));
    } catch (e) {
      const errStr = String(e?.message || e);
      console.error(`[KV-PUT-1] state:${repo} FAILED: ${errStr}`);
      const status = errStr.includes('429') ? 429 : 500;
      const msg = status === 429
        ? 'KV rate limit exceeded — try again later'
        : `KV write failed: ${errStr.slice(0, 80)}`;
      return error(msg, status);
    }
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
      state.queue.cancelled = false;
      state.last_sent_position = -1;
      try { await env.VIBECODE.delete(`lsp:${repo}`); } catch (_) {}
      // Delete stale queue position tiny keys from the previous batch.
      // qpos/qdon have 86400s TTL and survive POST reset. Without this,
      // the next poll's qpos restore restores the OLD position and shows
      // "1/1 done" without ever sending the new batch.
      if (state.conversation_id) {
        try { await env.VIBECODE.delete(`qpos:${state.conversation_id}`).catch(() => {}); } catch (_) {}
        try { await env.VIBECODE.delete(`qdon:${state.conversation_id}`).catch(() => {}); } catch (_) {}
      }
      // Delete cid tiny key too — prevents stale conversation_id from
      // being restored by cid restore (line ~1596). Without this, the
      // next poll restores a COMPLETED conversation_id, send-follow-up
      // tries to send the new prompt to the old conversation, the Cloud
      // API silently accepts but the agent doesn't start. After 3 retries,
      // send-follow-up clears conversation_id and createConversation
      // creates a NEW conversation — sending the prompt TWICE (once to
      // the old conv, once to the new conv). This is the root cause of
      // "message sent to two conversations".
      try { await env.VIBECODE.delete(`cid:${repo}`).catch(() => {}); } catch (_) {}
      // Clear conversation_id — each new batch must start fresh.
      state.conversation_id = null;
      recordConvChange(state, `Starting ${prompts.length} new tasks`);
      state._dirty = true;
      state._last_event_ts = "";
      state.sandbox_id = null;
      state._run_started_at = undefined;
      state._completed_position = undefined;
      state._error_retry = 0;  // reset retry counter for new batch
      state._send_retry = 0;
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
      // Stale retry state from previous batch (same conversation_id) would cause
      // the poll handler to find an old MessageEvent and advance the queue
      // prematurely. Delete it so the retry starts fresh.
      if (state.conversation_id) {
        try { await env.VIBECODE.delete(`retry:${state.conversation_id}`).catch(() => {}); } catch (_) {}
      }
    }
    state.queue.prompts.push(...prompts);
    state.queue.modes.push(...Array(prompts.length).fill(mode));
    state.queue.total = state.queue.prompts.length;
    state.queue.cancelled = false;

    console.log(`[BATCH] repo=${repo}: queued ${prompts.length} prompts — pos=${state.queue.position}/${state.queue.total} mode=${mode}`);

    // Write to KV directly (not writeState) so we can detect failure and
    // return an error to the client — if the queue state wasn't persisted,
    // the message is lost forever (next poll reads old state from KV).
    // Trim first so JSON.stringify doesn't exceed CPU/memory limits.
    trimState(state);
    try {
      await env.VIBECODE.put(`state:${repo}`, JSON.stringify(state));
    } catch (e) {
      const errStr = String(e?.message || e);
      console.error(`[KV-PUT-2] state:${repo} FAILED: ${errStr}`);
      const status = errStr.includes('429') ? 429 : 500;
      const msg = status === 429
        ? 'KV rate limit exceeded — try again later'
        : `KV write failed: ${errStr.slice(0, 80)}`;
      return error(msg, status);
    }
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
      state._error_retry = 0;  // reset retry counter for next batch
      state._send_retry = 0;
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
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
    const tPoll = Date.now();

    // Restore last_sent_position from the tiny lsp KV key if writeState
    // failed after a successful sendMessage (see line 1622).
    const storedLsp = await env.VIBECODE.get(`lsp:${repo}`).catch(() => null);
    if (storedLsp !== null) {
      const lspVal = parseInt(storedLsp, 10);
      if (!isNaN(lspVal) && lspVal > state.last_sent_position && lspVal <= q.position) {
        state.last_sent_position = lspVal;
      }
    }

    // Restore _last_response_ts from tiny lrt key if the main state write
    // failed after a response was found (prevents re-consuming old events).
    if (state.conversation_id) {
      const storedLrt = await env.VIBECODE.get(`lrt:${state.conversation_id}`).catch(() => null);
      if (storedLrt && (!state._last_response_ts || storedLrt > state._last_response_ts)) {
        state._last_response_ts = storedLrt;
      }
      // If writeStateIfDirty failed after a response was found but before
      // the assistant message was persisted to KV, recover from the tiny
      // rspt key. Without this, the response is silently lost.
      const storedRspt = await env.VIBECODE.get(`rspt:${state.conversation_id}`).catch(() => null);
      if (storedRspt && state._last_response_ts) {
        // Check if this exact response text is already in state.messages
        // (loaded from KV). If the main state write propagated since the
        // last poll, the response is already there — skip recovery.
        let alreadyInMessages = false;
        if (state.messages) {
          for (const m of state.messages) {
            if (m.role === 'assistant' && m.content === storedRspt) {
              alreadyInMessages = true;
              break;
            }
          }
        }
        if (!alreadyInMessages) {
          // Remove stale heartbeat events before pushing the recovered
          // response — same reason as the fetchResponse/pollConversation
          // paths: without this, the user sees both "Working..." and the
          // response as separate entries.
          if (state.messages) {
            state.messages = state.messages.filter(m =>
              !(m.role === 'event' && typeof m.content === 'string' &&
                m.content.includes('[STATUS]') &&
                (m.content.includes('Working') || m.content.includes('working')))
            );
          }
          state.messages.push({ id: nextMsgId(state), role: 'assistant', content: storedRspt, timestamp: now() });
          state._dirty = true;
          // Advance queue position — ONLY when we actually pushed the response.
          // If alreadyInMessages is true, the main state already has the correct
          // position (written by a previous poll). Advancing again would skip the
          // next prompt in the queue (HIGH severity bug).
          if (q.position < q.total) {
            q.position++;
            q.done = Math.min(q.position, q.total);
            state._dirty = true;
            try { await env.VIBECODE.put(`qpos:${state.conversation_id}`, String(q.position), {expirationTtl: 86400}); } catch (_) {}
            try { await env.VIBECODE.put(`qdon:${state.conversation_id}`, String(q.done), {expirationTtl: 86400}); } catch (_) {}
          }
          // Persist the recovered response to KV. Without this, _dirty is
          // never flushed when hasPending=false (queue done) — all subsequent
          // poll phases are guarded by hasPending or !conversation_id. The
          // next request reads OLD KV state (without the assistant message),
          // and since rspt key is deleted below, recovery can't run again —
          // the response silently disappears on restart/reload.
          //
          // If writeState fails here (KV write limit), Flutter's local cache
          // still has the response from this poll's JSON — the next poll's
          // merge keeps it (Phase 2 adds _messages not in serverMsgs). But
          // without the KV write, a server restart exposes the same gap.
          // Best-effort is acceptable: the content-based dedup in Flutter
          // (dedup by role+content) catches any remaining edge case.
          await writeStateIfDirty(env, repo, state);
        }
        // Always try to delete rspt key (cleanup). If this fails, the next poll
        // finds alreadyInMessages=true and skips both push and advance.
        try { await env.VIBECODE.delete(`rspt:${state.conversation_id}`).catch(() => {}); } catch (_) {}
      }
    }

    // Restore q.position and q.done from tiny keys if writeStateIfDirty
    // failed after advancing the queue. Without this, hasPending stays true
    // and Flutter shows "0/1 done" regression + may re-send the same prompt.
    if (state.conversation_id) {
      const storedQpos = await env.VIBECODE.get(`qpos:${state.conversation_id}`).catch(() => null);
      if (storedQpos !== null) {
        const qposVal = parseInt(storedQpos, 10);
        if (!isNaN(qposVal) && qposVal > q.position) {
          q.position = qposVal;
          state._dirty = true;
        }
      }
      const storedQdon = await env.VIBECODE.get(`qdon:${state.conversation_id}`).catch(() => null);
      if (storedQdon !== null) {
        const qdonVal = parseInt(storedQdon, 10);
        if (!isNaN(qdonVal) && qdonVal > q.done) {
          q.done = qdonVal;
          state._dirty = true;
        }
      }
    }

    // Restore conversation_id from tiny cid key if main state write failed.
    // Without this, createConversation fires again with the same prompt
    // (wasted Cloud API quota and duplicate agent work).
    if (!state.conversation_id) {
      const storedCid = await env.VIBECODE.get(`cid:${repo}`).catch(() => null);
      if (storedCid) {
        state.conversation_id = storedCid;
        state._dirty = true;
      }
    }

    // Migration: old code set q.cancelled=true on conv failure, locking the
    // queue. If cancelled but has pending work, clear stale flag and retry.
    let hasPending = q.position < q.total && !q.cancelled;
    if (q.cancelled && q.position < q.total) {
      q.cancelled = false;
      hasPending = true;
    }

    // Queue naturally completed — reset to clean idle state so the app
    // doesn't show stale "1/1 done" after the task finishes.
    if (!hasPending && q.total > 0 && !state.conversation_id) {
      console.log(`[POLL] repo=${repo}: QUEUE DONE — resetting state (was ${q.total} prompts, all completed)`);
      q.position = 0;
      q.total = 0;
      q.done = 0;
      q.prompts = [];
      q.modes = [];
      q.cancelled = false;
      state._batch_skip = undefined;
      // Reset timer too; next task will set its own.
      state._run_started_at = undefined;
      state._error_retry = 0;  // reset retry counter for next batch
      state._send_retry = 0;
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
      state.last_sent_position = -1;
      state._dirty = true;  // persist all the reset changes above
      // Persist so next poll sees clean state.
      await writeStateIfDirty(env, repo, state);
      // Delete lsp key since batch is done; prevents stale values from
      // corrupting last_sent_position on the next batch.
      try { await env.VIBECODE.delete(`lsp:${repo}`); } catch (_) {}
      // Delete cid too — prevents stale conversation restore on next batch.
      try { await env.VIBECODE.delete(`cid:${repo}`); } catch (_) {}
    }
    let convStatus = 'idle';

    // --- Phase: resolve start_task to conversation_id (stateful retry across polls) ---
    if (!state.conversation_id && state.start_task_id) {
      convStatus = 'starting';
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
          recordConvChange(state, 'Agent connected');
          state._dirty = true;
          state._last_event_ts = '';  // reset event pagination for new conversation
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
      await writeStateIfDirty(env, repo, state);
    }

    // Flush deferred follow-up messages from the PREVIOUS poll's SEND-FOLLOWUP.
    // These were stored in _pending_followup_msgs (not in state.messages) so the
    // previous poll response showed only the assistant — not the next prompt's
    // user message. They become visible in THIS poll so the UI shows one-by-one.
    if (state._pending_followup_msgs && state._pending_followup_msgs.length > 0) {
      console.log(`[POLL] repo=${repo}: FLUSH_DEFERRED flushing ${state._pending_followup_msgs.length} msgs`);
      for (const msg of state._pending_followup_msgs) {
        state.messages.push(msg);
      }
      state._pending_followup_msgs = [];
      state._dirty = true;
    }

    // --- Phase: create conversation if queue has work ---
    if (hasPending && !state.conversation_id && !state.start_task_id) {
      // Don't retry createConversation more often than every 30s.
      // Rate-limited (429) calls should not spike the API or burn crash budget.
      if (state._create_retry_at && Date.now() < state._create_retry_at) {
        convStatus = 'pending';
      } else {
        const prompt = q.prompts[q.position];
        const promptMode = q.modes[q.position] || mode;

        // Add user message to local state BEFORE createConversation.
        // If createConversation throws (line ~1766), the catch skip path
        // advances the queue without ever reaching line 1761 (which was
        // inside the try block). The user's message silently disappears.
        state.messages.push({ id: nextMsgId(state), role: 'user', content: prompt, timestamp: now() });
        state.messages.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent is starting up... (0s)', kind: 'SystemEvent', timestamp: now() });
        state._dirty = true;

        try {
          const result = await createConversation(env, prompt, repo, state.branch, promptMode, state);
          if (result.conversation_id) {
            state.conversation_id = result.conversation_id;
            recordConvChange(state, 'Agent connected');
            state._dirty = true;
            state._last_event_ts = '';  // reset event pagination for new conversation
            if (result.sandbox_id) state.sandbox_id = result.sandbox_id;
            state.last_sent_position = q.position;  // sent via initial_message
            try { await env.VIBECODE.put(`lsp:${repo}`, String(q.position)); } catch (_) {}
            try { await env.VIBECODE.put(`cid:${repo}`, result.conversation_id, {expirationTtl: 86400}); } catch (_) {}
            convStatus = 'starting';
          } else if (result.start_task_id) {
            state.start_task_id = result.start_task_id;
            state._last_event_ts = '';  // reset event pagination for new conversation
            state.last_sent_position = q.position;  // will be sent when conv resolves
            try { await env.VIBECODE.put(`lsp:${repo}`, String(q.position)); } catch (_) {}
            convStatus = 'starting';
          }

          // Save LLM model info
          const cfg = await readConfig(env);
          state.llm_model = cfg.model || '';
          state.configured_model = cfg.model || '';

          // Reset elapsed timer for this new conversation
          state._run_started_at = now();

          // User message + start-up status were already pushed at line ~1739
          // (before createConversation) so they persist even if the API call
          // throws. No need to push them again here.

          await writeStateIfDirty(env, repo, state);
        } catch (e) {
          console.error(`Create conv error: ${e.message}`);

          // --- Rate limit (429): back off 60s, DON'T increment crash counter ---
          if (String(e.message).includes('429') || String(e.message).includes('rate')) {
            state._create_retry_at = Date.now() + 60000;
            console.log(`[POLL] repo=${repo}: createConversation rate limited — retrying after 60s`);
          } else {
            // Don't cancel the queue — let the next poll retry.
            // Track failures — if they exceed maxCrash, skip prompt.
            // maxCrash is set high (20) because each failure has 30s
            // backoff AND the crash key has 120s TTL — within that
            // window at most 4-5 retries happen. Setting it low (3)
            // would skip prompts prematurely when the Cloud API is
            // temporarily overloaded (the user sees "1/1 done" with
            // no response, which is confusing).
            const maxCrash = 20;
            const crashKey = `crash:${repo}:${q.position}`;
            let crashCount = 0;
            try {
              const raw = await env.VIBECODE.get(crashKey);
              if (raw) crashCount = parseInt(raw, 10) || 0;
            } catch (_) {}
            crashCount++;
            state._create_retry_at = Date.now() + 30000;
            if (crashCount >= maxCrash) {
              // Skip this prompt — move to next
              state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] Skipping prompt #${q.position + 1}: agent stopped responding.`, kind: 'ErrorEvent', timestamp: now() });
              state.messages.push({ id: nextMsgId(state), role: 'assistant', content: `[Skipped: agent failed to start]`, timestamp: now() });
              q.position++;
        state._dirty = true;
              q.done = Math.min(q.position, q.total);
        state._dirty = true;
              state.conversation_id = null;
      state._dirty = true;
              recordConvChange(state, `Agent unavailable — skipping task #${q.position}`);
              state._last_event_ts = "";
              state.sandbox_id = null;
              state.last_sent_position = -1;
              state._run_started_at = undefined;
              state._create_retry_at = undefined;
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
          }
          await writeStateIfDirty(env, repo, state);
        }
      }
    }

    // --- Phase: send follow-up message if queue advanced but not sent yet ---
    // Triggered when last_sent_position < q.position (new prompt in queue).
    // Uses a separate tiny KV key for last_sent_position so it survives main
    // state write failures — the state object is large (messages + 100s of
    // seen_event_ids), and KV failures on large writes are the #1 cause of
    // duplicate sendMessage (next poll reads last_sent_position=-1 from stale
    // state and fires again).
    if (hasPending && state.conversation_id && state.last_sent_position < q.position) {
      // Don't retry sendMessage more often than every 30s.
      // Add _send_retry_at delay to prevent 30s of rapid-fire retries
      // when Cloud API is returning 5xx or network is flaky.
      if (state._send_retry_at && Date.now() < state._send_retry_at) {
        convStatus = 'pending';
      } else {
        const prompt = q.prompts[q.position];
        const sendErr = await sendMessage(env, state.conversation_id, prompt, state.sandbox_id);
        if (sendErr) {
          console.error(`sendMessage follow-up error: ${sendErr}`);
          // 429 rate limit: keep conversation_id and retry next poll.
          // Clearing it causes a new conv attempt every poll (also 429).
          if (String(sendErr).includes('429') || String(sendErr).includes('rate')) {
            console.log(`[POLL] repo=${repo}: rate limited — keeping conv ${state.conversation_id} for retry`);
            state._send_retry = 0;  // reset on rate limit (transient)
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
            state._send_retry_at = Date.now() + 60000;
          } else {
            // Non-429 errors: retry up to 3 times before creating a new
            // conversation. Transient network blips shouldn't lose context.
            state._send_retry = (state._send_retry || 0) + 1;
            state._send_retry_at = Date.now() + 30000;
            console.log(`[POLL] repo=${repo}: sendMessage error (retry ${state._send_retry}/3, backoff 30s)`);
            if (state._send_retry >= 3) {
              state._send_retry = 0;
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
              state._send_retry_at = undefined;
              state.conversation_id = null;
      state._dirty = true;
              recordConvChange(state, 'Reconnecting to agent...');
              state._last_event_ts = "";
              state.sandbox_id = null;
            }
          }
          await writeStateIfDirty(env, repo, state);
          // Return early — don't fall through to polling block. Otherwise
          // fetchResponse finds old events and advances queue with stale data
          // (user's message was never sent).
          return buildStateResponse(state, q, hasPending, repo, mode, state.conversation_id ? 'pending' : 'idle');
        } else {
          state.last_sent_position = q.position;
          state._dirty = true;
          console.log(`[SEND-FOLLOWUP] repo=${repo}: sent prompt #${q.position} (${prompt.length} chars) → conv=${state.conversation_id.slice(0,12)}`);
          state._send_retry = 0;  // reset on successful send
      state._create_retry_at = undefined;
      state._send_retry_at = undefined;
          state._send_retry_at = undefined;
          // Defer user message + working event to NEXT poll so the user sees
          // the previous prompt's assistant response BEFORE the next prompt's
          // user message appears. Pushing to state.messages immediately would
          // include them in THIS poll's response — the user sees asst1+user2
          // together instead of sequentially.
          if (!state._pending_followup_msgs) state._pending_followup_msgs = [];
          state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'user', content: prompt, timestamp: now() });
          state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
          state._dirty = true;
          // Write last_sent_position to SEPARATE small KV key FIRST
          try { await env.VIBECODE.put(`lsp:${repo}`, String(q.position)); } catch (_) {}
          await writeStateIfDirty(env, repo, state);
          return buildStateResponse(state, q, hasPending, repo, mode, 'running');
        }
      }
    }

    const skipFutureCancelled = (q) => {
      while (state._batch_skip && state._batch_skip[q.position]) {
        q.position++;
        state._dirty = true;
        q.done = Math.min(q.position, q.total);
        state._dirty = true;
      }
    };

    // --- Phase: poll Cloud API for agent status ---
    if (state.conversation_id && hasPending) {
      // Try to read the agent's response from events FIRST.
      // fetchResponse uses _last_response_ts as cutoff and skips old
      // MessageEvents, so it always returns the CURRENT turn's response
      // (if one exists). No need to guard on _last_event_ts — the cutoff
      // handles dedup correctly.
      let directResponse = await fetchResponse(env, state.conversation_id, state);

      // Process events for UI enrichment (tool calls, status changes).
      await processCloudEvents(env, state.conversation_id, state);

      // Fallback: if fetchResponse found no MessageEvent but the finish
      // tool has a message, use it as the response.
      if (!directResponse && state._finish_message) {
        directResponse = state._finish_message;
        delete state._finish_message;
      }

      if (directResponse) {
        // Agent message found via events — skip status API entirely.
        convStatus = 'completed';
        // Remove stale heartbeat events persisted from the running branch.
        // Without this, user sees both "Working..." and the response as
        // separate entries after reopen/refresh (the heartbeat was written
        // to KV by the running branch's writeStateIfDirty).
        state.messages = state.messages.filter(m =>
          !(m.role === 'event' && typeof m.content === 'string' &&
            m.content.includes('[STATUS]') &&
            (m.content.includes('Working') || m.content.includes('working')))
        );
        // Check the rspt KEY (persistent across polls), not state.messages
        // (loaded from stale KV). If fetchResponse returns the same text as
        // an already-written rspt key, the response was consumed by a previous
        // poll but the main state hasn't propagated yet (KV eventual consistency
        // delay up to 60s). Just advance the queue without pushing a duplicate.
        const rsptKey = `rspt:${state.conversation_id}`;
        const existingRspt = await env.VIBECODE.get(rsptKey).catch(() => null);
        if (existingRspt === directResponse) {
          // Response already consumed — advance queue without re-pushing
          q.position = Math.min(q.position + 1, q.total);
          q.done = Math.min(q.position, q.total);
          state._dirty = true;
          state._last_response_ts = new Date().toISOString();
          try { await env.VIBECODE.put(`lrt:${state.conversation_id}`, state._last_response_ts); } catch (_) {}
          try { await env.VIBECODE.put(`qpos:${state.conversation_id}`, String(q.position), {expirationTtl: 86400}); } catch (_) {}
          try { await env.VIBECODE.put(`qdon:${state.conversation_id}`, String(q.done), {expirationTtl: 86400}); } catch (_) {}
          await writeStateIfDirty(env, repo, state);
          return buildStateResponse(state, q, false, repo, mode, 'completed');
        }

        // Also check in-memory state.messages (not KV). The rspt recovery
        // at line ~1638 may have already pushed this response to state.messages
        // in the CURRENT poll (before fetchResponse was called). If so, the rspt
        // key was written but writeState may have failed before the "already
        // consumed" check above — and with KV eventual consistency, the key
        // might not be visible yet. Without this check, the response is pushed
        // AGAIN with a different local id, creating a duplicate in the Flutter
        // UI (dedup uses id:N, so id:N+1 and id:N+2 both survive).
        const alreadyInMessages = state.messages.some(m =>
          m.role === 'assistant' && m.content === directResponse
        );
        if (alreadyInMessages) {
          // Response was already pushed by rspt recovery — advance queue
          q.position = Math.min(q.position + 1, q.total);
          q.done = Math.min(q.position, q.total);
          state._dirty = true;
          state._last_response_ts = new Date().toISOString();
          try { await env.VIBECODE.put(`lrt:${state.conversation_id}`, state._last_response_ts); } catch (_) {}
          try { await env.VIBECODE.put(`qpos:${state.conversation_id}`, String(q.position), {expirationTtl: 86400}); } catch (_) {}
          try { await env.VIBECODE.put(`qdon:${state.conversation_id}`, String(q.done), {expirationTtl: 86400}); } catch (_) {}
          await writeStateIfDirty(env, repo, state);
          return buildStateResponse(state, q, false, repo, mode, 'completed');
        }

        // First time seeing this response — write rspt key BEFORE pushing
        // to state.messages. If the main state write fails below, the next
        // poll's rspt recovery re-pushes the response AND advances the queue
        // (see line ~1603). The rspt key check above also prevents the next
        // poll's fetchResponse from pushing a duplicate while the main state
        // is still propagating (KV eventual consistency).
        try { await env.VIBECODE.put(rsptKey, directResponse, {expirationTtl: 86400}); } catch (_) {}
        state.messages.push({ id: nextMsgId(state), role: 'assistant', content: directResponse, timestamp: now() });
        console.log(`[RESP] repo=${repo}: PUSH assistant msg (${directResponse.length} chars) via fetchResponse — pos=${q.position}/${q.total}`);
        state._dirty = true;
        state._last_response_ts = new Date().toISOString();
        // Persist to separate tiny key — survives main state write failures.
        try { await env.VIBECODE.put(`lrt:${state.conversation_id}`, state._last_response_ts); } catch (_) {}
        // rspt key was already written at line ~1973 (BEFORE state.messages
        // push) so the next poll can dedup even before the main state write
        // propagates. No need to write it again here.
        q.position++;
        state._dirty = true;
        q.done = Math.min(q.position, q.total);
        console.log(`[QUEUE] repo=${repo}: advanced → pos=${q.position}/${q.total} done=${q.done}`);
        state._dirty = true;
        // Persist queue position and done to tiny keys. If writeStateIfDirty
        // fails below, q.position and q.done regress to stale KV values on the
        // next poll — causing hasPending to be true again, Flutter to show
        // "0/1 done" after already showing "1/1 done", and potentially
        // re-sending the same prompt via send-follow-up (duplicate agent work).
        try { await env.VIBECODE.put(`qpos:${state.conversation_id}`, String(q.position), {expirationTtl: 86400}); } catch (_) {}
        try { await env.VIBECODE.put(`qdon:${state.conversation_id}`, String(q.done), {expirationTtl: 86400}); } catch (_) {}
        skipFutureCancelled(q);
        // Re-read q.total from KV: user may have queued more prompts while
        // this poll was processing. Without this, stillPending uses stale
        // total and follow-up prompts are silently lost.
        await syncQueueFromKv(env, repo, q);
        const stillPending = q.position < q.total && !q.cancelled;
        if (stillPending) {
          const nextPrompt = q.prompts[q.position];
          const sendErr = await sendMessage(env, state.conversation_id, nextPrompt, state.sandbox_id);
          if (sendErr) {
            console.error(`sendMessage follow-up error: ${sendErr}`);
          } else {
            state.last_sent_position = q.position;
          state._dirty = true;
            try { await env.VIBECODE.put(`lsp:${repo}`, String(q.position)); } catch (_) {}
            if (!state._pending_followup_msgs) state._pending_followup_msgs = [];
            state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'user', content: nextPrompt, timestamp: now() });
            state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
          state._dirty = true;
          }
        }
        await writeStateIfDirty(env, repo, state);
        return buildStateResponse(state, q, stillPending, repo, mode, stillPending ? 'running' : 'idle');
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
          // Mark response timestamp so fetchResponse/pollConversation
          // don't re-consume this response on the next poll.
          state._last_response_ts = new Date().toISOString();
          // Persist to separate tiny key — survives main state write failures.
          try { await env.VIBECODE.put(`lrt:${state.conversation_id}`, state._last_response_ts); } catch (_) {}
          // Push assistant response to state.messages (fetchResponse path
          // also does this at line ~1881). Without this, pollConversation
          // responses advance the queue but are never shown to the user.
          state.messages = state.messages.filter(m =>
            !(m.role === 'event' && typeof m.content === 'string' &&
              m.content.includes('[STATUS]') &&
              (m.content.includes('Working') || m.content.includes('working')))
          );
          // Skip push if rspt key already has this exact text (written by
          // the fetchResponse path in a previous poll, or by the rspt
          // recovery path). This prevents duplicates when KV is eventually
          // consistent (main state write hasn't propagated yet).
          const existingRspt = await env.VIBECODE.get(`rspt:${state.conversation_id}`).catch(() => null);
          if (existingRspt === responseText) {
            // Response already consumed by a previous poll
            q.position = Math.min(q.position + 1, q.total);
            q.done = Math.min(q.position, q.total);
            state._dirty = true;
            try { await env.VIBECODE.put(`qpos:${state.conversation_id}`, String(q.position), {expirationTtl: 86400}); } catch (_) {}
            try { await env.VIBECODE.put(`qdon:${state.conversation_id}`, String(q.done), {expirationTtl: 86400}); } catch (_) {}
            await writeStateIfDirty(env, repo, state);
            return buildStateResponse(state, q, false, repo, mode, 'completed');
          }
          state.messages.push({ id: nextMsgId(state), role: 'assistant', content: responseText, timestamp: now() });
          console.log(`[RESP] repo=${repo}: PUSH assistant msg (${responseText.length} chars) via pollConversation — pos=${q.position}/${q.total}`);
          state._dirty = true;
          // Advance queue
          q.position++;
        state._dirty = true;
          q.done = Math.min(q.position, q.total);
          console.log(`[QUEUE] repo=${repo}: advanced → pos=${q.position}/${q.total} done=${q.done}`);
        state._dirty = true;
          // Write rspt key AFTER push so the next poll can dedup (the same
          // pattern as the fetchResponse path at line ~1973).
          try { await env.VIBECODE.put(`rspt:${state.conversation_id}`, responseText, {expirationTtl: 86400}); } catch (_) {}
          // Persist queue position and done to tiny keys (same reason as
          // fetchResponse path — prevents "0/1 done" regression on write failure).
          try { await env.VIBECODE.put(`qpos:${state.conversation_id}`, String(q.position), {expirationTtl: 86400}); } catch (_) {}
          try { await env.VIBECODE.put(`qdon:${state.conversation_id}`, String(q.done), {expirationTtl: 86400}); } catch (_) {}
          skipFutureCancelled(q);
          // Re-read q.total from KV: user may have queued more prompts while
          // this poll was processing. Without this, stillPending uses stale
          // total and follow-up prompts are silently lost.
          await syncQueueFromKv(env, repo, q);
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
          state._dirty = true;
              try { await env.VIBECODE.put(`lsp:${repo}`, String(q.position)); } catch (_) {}
              if (!state._pending_followup_msgs) state._pending_followup_msgs = [];
              state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'user', content: nextPrompt, timestamp: now() });
              state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
          state._dirty = true;
            }
          }
          await writeStateIfDirty(env, repo, state);
          return buildStateResponse(state, q, stillPending);
        }

        // No response text found — retry across polls (stateful, non-blocking)
        // Retry state stored in SEPARATE KV key so it survives main state write failures.
        // Each poll does ONE attempt so we never block >30s on free tier.
        // Retry window extends up to ~5min as long as the app keeps polling.
        console.log(`[RETRY] conv=${state.conversation_id}: completed with no msg (pos=${q.position}, _completed_position=${state._completed_position}) — starting retry`);
        let retryResponse = null;
        let rState = { count: 0, started_at: 0 };
        try {
          const rRaw = await env.VIBECODE.get(`retry:${state.conversation_id}`);
          if (rRaw) rState = JSON.parse(rRaw);
        } catch (_) {}

        // Stale retry state detection: reset if this is a new prompt (position
        // mismatch) OR if the retry started more than 10min ago (same position
        // coincidentally matches across different batches for 1-prompt tasks).
        const isStale =
          state._completed_position !== q.position ||
          (rState.started_at > 0 && (Date.now() - rState.started_at) > 600000);  // 10min
        if (rState.count > 0 && isStale) {
          console.log(`[RETRY] conv=${state.conversation_id}: stale retry state (count=${rState.count}) for new prompt — resetting`);
          rState = { count: 0, started_at: 0 };
          try { await env.VIBECODE.delete(`retry:${state.conversation_id}`).catch(() => {}); } catch (_) {}
        }

        const retryCount = rState.count || 0;

        // If _completed_position matches the current queue slot, the retry
        // handler is already active for this prompt — fall through to the
        // retry logic below which handles timing/count/backoff.
        // NO retry key KV read here — Cloudflare KV is eventually consistent
        // and the key might not be visible yet, causing premature queue advance.
        if (state._completed_position === q.position) {
          console.log(`[RETRY] conv=${state.conversation_id}: _completed_position matched (pos=${q.position}) — continuing retry (count=${retryCount})`);
        }
        state._completed_position = q.position;

        // Time-based retry window: up to MAX_RETRY_SECONDS total (~2 hours).
        // Exponential backoff: 5s, 10s, 20s, 40s... capped at 120s between attempts.
        // Agents can run for 60+ minutes, so a fixed attempt count is too short.
        const MAX_RETRY_SECONDS = 7200;  // 2 hours
        const elapsed = rState.started_at ? (Date.now() - rState.started_at) / 1000 : 0;

        if (elapsed < MAX_RETRY_SECONDS) {
          // Backoff: start at 30s, double each attempt, cap at 120s
          const waitSec = Math.min(120, 30 * Math.pow(2, Math.min(retryCount, 2)));

          if (elapsed >= waitSec) {
            console.log(`[RETRY] conv=${state.conversation_id}: attempt ${retryCount} firing (elapsed=${elapsed.toFixed(1)}s, waitSec=${waitSec}s)`);
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
          // elapsed >= MAX_RETRY_SECONDS (~2 hours) — give up
          console.log(`[RETRY] conv=${state.conversation_id}: retry window exhausted (elapsed=${elapsed.toFixed(0)}s, retryCount=${retryCount}) — giving up`);
          rState = { count: 0, started_at: 0 };
          // Delete retry key so next poll doesn't restart the cycle
          try { await env.VIBECODE.delete(`retry:${state.conversation_id}`).catch(() => {}); } catch (_) {}
        }
        if (!rState.started_at && elapsed < MAX_RETRY_SECONDS) rState.started_at = Date.now();
        // Persist retry state to SEPARATE key (survives main state write failure)
        // Only write if we're still within the retry window
        if (elapsed < MAX_RETRY_SECONDS) {
          try { await env.VIBECODE.put(`retry:${state.conversation_id}`, JSON.stringify(rState)); } catch (_) {}
        }

        if (retryResponse) {
          console.log(`[RETRY] conv=${state.conversation_id}: response found (${retryResponse.length} chars) after ${retryCount} attempts`);
          // Clean up retry state
          try { await env.VIBECODE.delete(`retry:${state.conversation_id}`).catch(() => {}); } catch (_) {}
          state.messages.push({ id: nextMsgId(state), role: 'assistant', content: retryResponse, timestamp: now() });
          console.log(`[RESP] repo=${repo}: PUSH assistant msg (${retryResponse.length} chars) via RETRY — pos=${q.position}/${q.total}`);
          state._last_response_ts = new Date().toISOString();
          // Persist to separate tiny key — survives main state write failures.
          try { await env.VIBECODE.put(`lrt:${state.conversation_id}`, state._last_response_ts); } catch (_) {}

          // Advance queue
          q.position++;
        state._dirty = true;
          q.done = Math.min(q.position, q.total);
          console.log(`[QUEUE] repo=${repo}: advanced (retry) → pos=${q.position}/${q.total} done=${q.done}`);
        state._dirty = true;
          skipFutureCancelled(q);
          // Re-read q.total from KV: user may have queued more prompts while
          // this poll was processing. Without this, stillPending uses stale
          // total and follow-up prompts are silently lost.
          await syncQueueFromKv(env, repo, q);
          const stillPending = q.position < q.total && !q.cancelled;

          // If more prompts, send next one
          if (stillPending) {
            const nextPrompt = q.prompts[q.position];
            const sendErr = await sendMessage(env, state.conversation_id, nextPrompt, state.sandbox_id);
            if (sendErr) {
              console.error(`sendMessage error at pos ${q.position}: ${sendErr}`);
            } else {
              state.last_sent_position = q.position;
          state._dirty = true;
              try { await env.VIBECODE.put(`lsp:${repo}`, String(q.position)); } catch (_) {}
              if (!state._pending_followup_msgs) state._pending_followup_msgs = [];
              state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'user', content: nextPrompt, timestamp: now() });
              state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
          state._dirty = true;
            }
          }

          await writeStateIfDirty(env, repo, state);
          return buildStateResponse(state, q, stillPending, repo, mode, stillPending ? 'running' : 'idle');
        } else if (convStatus === 'pending') {
          // Still waiting for ZIP to generate — return current state, retry next poll
          // Write main state too so _completed_position is saved
          await writeStateIfDirty(env, repo, state);
          return buildStateResponse(state, q, true, repo, mode, 'pending');
        } else {
          // All retries exhausted — give up
          state.messages.push({ id: nextMsgId(state), role: 'event', content: '[ERROR] Task finished but no response text found', kind: 'ErrorEvent', timestamp: now() });
          console.log(`[QUEUE] repo=${repo}: advancing after retry exhaustion → error at pos=${q.position}`);

          // Advance queue
          q.position++;
        state._dirty = true;
          q.done = Math.min(q.position, q.total);
        state._dirty = true;
          skipFutureCancelled(q);
          // Re-read q.total from KV: user may have queued more prompts while
          // this poll was processing. Without this, stillPending uses stale
          // total and follow-up prompts are silently lost.
          await syncQueueFromKv(env, repo, q);
          const stillPending = q.position < q.total && !q.cancelled;

          if (stillPending) {
            const nextPrompt = q.prompts[q.position];
            const sendErr = await sendMessage(env, state.conversation_id, nextPrompt, state.sandbox_id);
            if (sendErr) {
              console.error(`sendMessage error at pos ${q.position}: ${sendErr}`);
            } else {
              state.last_sent_position = q.position;
          state._dirty = true;
              try { await env.VIBECODE.put(`lsp:${repo}`, String(q.position)); } catch (_) {}
              if (!state._pending_followup_msgs) state._pending_followup_msgs = [];
              state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'user', content: nextPrompt, timestamp: now() });
              state._pending_followup_msgs.push({ id: nextMsgId(state), role: 'event', content: '[STATUS] Agent working...', kind: 'SystemEvent', timestamp: now() });
          state._dirty = true;
            }
          }

          await writeStateIfDirty(env, repo, state);
          return buildStateResponse(state, q, stillPending, repo, mode, stillPending ? 'running' : 'idle');
        }
      } else if (pollResult.status === 'failed') {
        const errMsg = pollResult.error || 'unknown error';

        // Auto-retry: up to 5 times on the SAME conversation. Only create a
        // new conversation (re-send prompt) after all retries exhausted.
        state._error_retry = state._error_retry || 0;

        // Initialize cooldown timer on first entry too — no immediate retry.
        if (!state._retry_at) {
          state._retry_at = Date.now() + 30000;
        }

        // Already exhausted — create new conversation (re-send prompt).
        if (state._error_retry >= 5) {
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[STATUS] Agent failed — creating new conversation...`, kind: 'SystemEvent', timestamp: now() });
          state._error_retry = 0;
          state._retry_at = undefined;
          state.conversation_id = null;
      state._dirty = true;
          recordConvChange(state, 'Agent had trouble — restarting...');
          state._last_event_ts = "";
          state.sandbox_id = null;
          state.last_sent_position = -1;
          state.start_task_id = null;
          state._run_started_at = undefined;
          try { await env.VIBECODE.delete(`lsp:${repo}`); } catch (_) {}
          await writeStateIfDirty(env, repo, state);
          return buildStateResponse(state, q, true, repo, mode, 'starting');
        }

        // 30-second delay between retries (applies from the first retry too).
        if (state._retry_at && Date.now() < state._retry_at) {
          return buildStateResponse(state, q, true, repo, mode, convStatus);
        }

        // This retry fires now.
        state._error_retry++;
        state._retry_at = Date.now() + 30000;
        console.log(`[AUTO-RETRY] Agent failed (attempt ${state._error_retry}/5): ${errMsg.slice(0, 100)}`);
        state.messages.push({ id: nextMsgId(state), role: 'event', content: `[STATUS] Agent failed — retrying (${state._error_retry}/5)...`, kind: 'SystemEvent', timestamp: now() });
        // Send "continue" to the same conversation to nudge the agent.
        // Don't clear conversation_id, don't advance q.position.
        if (state.conversation_id) {
          const continueErr = await sendMessage(env, state.conversation_id, "continue", state.sandbox_id);
          if (continueErr) {
            console.log(`[AUTO-RETRY] sendMessage(continue) error: ${continueErr}`);
          }
        }
        await writeStateIfDirty(env, repo, state);
        return buildStateResponse(state, q, true, repo, mode, convStatus);
      } else if (pollResult.status === 'error') {
        // Dead conversation — clear state so next poll creates a new one.
        // No need to advance queue (next poll retries the same prompt).
        if (pollResult.error && state.messages) {
          state.messages.push({ id: nextMsgId(state), role: 'event', content: `[ERROR] ${pollResult.error.slice(0, 200)}`, kind: 'ErrorEvent', timestamp: now() });
          state._dirty = true;
        }
        state.conversation_id = null;
      state._dirty = true;
        recordConvChange(state, 'Agent disconnected — reconnecting...');
        state._last_event_ts = "";
        state.sandbox_id = null;
        state.last_sent_position = -1;
        state.start_task_id = null;
        state._run_started_at = undefined;
        try { await env.VIBECODE.delete(`lsp:${repo}`); } catch (_) {}
        await writeStateIfDirty(env, repo, state);
        return buildStateResponse(state, q, true, repo, mode, 'starting');
      } else if (pollResult.status === 'idle' || (pollResult.status === 'completed' && !pollResult.response)) {
        // Conversation is idle/completed but queue has work and no response.
        // This means either:
        // 1. send-message was never called
        // 2. send-message failed
        // 3. Agent stuck in idle (bug #14698)
        // → Try sending the current prompt AND force /run
        // Only send if NOT already sent (last_sent_position check prevents
        // duplicate when pollConversation returns 'idle' before the Cloud API
        // updates status to 'running' after the first sendMessage at line 1597).
        if (convStatus !== 'starting' && state.last_sent_position < q.position) {
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
        await writeStateIfDirty(env, repo, state);
        return buildStateResponse(state, q, hasPending, repo, mode, convStatus);
      } else {
        // Still running — show elapsed timer, updated in-memory every poll.
        // _run_started_at is persisted ONCE when first set; no heartbeat writes.
        const nowMs = Date.now();
        if (!state._run_started_at) {
          state._run_started_at = nowMs;
          state._dirty = true;
          await writeStateIfDirty(env, repo, state);  // persist the start timestamp once
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
          state._dirty = true;
        }
        // Persist events and seen_event_ids so the next poll doesn't re-process
        // the same tool events from processCloudEvents (called above). Without
        // this, state.messages accumulates duplicates on every poll cycle.
        await writeStateIfDirty(env, repo, state);
        return buildStateResponse(state, q, hasPending, repo, mode, convStatus);
      }
    }
    // No poll phase ran (no conversation_id or no pending work). Return current state.
    console.log(`[POLL] repo=${repo}: done — hasPending=${hasPending} convId=${(state.conversation_id||'').slice(0,12)} convStatus=${convStatus} (${Date.now()-tPoll}ms)`);
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