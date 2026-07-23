const express = require('express');
const path = require('path');
const fs_main = require('fs');

const app = express();
const PORT = process.env.PORT || 3456;

// ─────────────────────────────────────────────────────────────────────────
// SECURITY NOTE: as shipped, nothing below this line authenticates who's
// calling /events or /decision/:id — the original private deployment this
// was extracted from had a phone/SMS + TOTP-approval + signed-cookie layer
// here, all removed for this public template because it was too specific to
// generalize (and too easy to misconfigure by copy-pasting someone else's
// secrets). If you expose this publicly, decide your own risk tolerance and
// add your own gate — e.g. re-check whatever your PHP login layer's
// auth_current_user() considers valid, put this whole app behind a VPN/IP
// allowlist, or reintroduce a signed-cookie handshake like the one described
// in claudestate/README.md's history if you need cross-process verification
// between this Node service and the PHP layer.
// ─────────────────────────────────────────────────────────────────────────

app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, 'public')));

// SSE clients
const sseClients = new Set();

// Pending permission requests: id -> resolve function
const pendingRequests = new Map();

// ── State persistence ────────────────────────────────────────────────────────
const STATE_FILE = path.join(__dirname, '.state_cache.json');
function loadPersistedState() {
  try {
    const raw = fs_main.readFileSync(STATE_FILE, 'utf8');
    const saved = JSON.parse(raw);
    // Discard stale rateLimits: if 5h window already reset, data is meaningless
    let rateLimits = saved.rateLimits || null;
    if (rateLimits && rateLimits.five_hour && rateLimits.five_hour.resets_at) {
      if (new Date(rateLimits.five_hour.resets_at) < new Date()) rateLimits = null;
    }
    return {
      tokenUsage: saved.tokenUsage || null,
      window5h:   saved.window5h   || null,
      window7d:   saved.window7d   || null,
      rateLimits,
    };
  } catch (_) { return {}; }
}
function persistState() {
  try {
    fs_main.writeFileSync(STATE_FILE, JSON.stringify({
      tokenUsage: state.tokenUsage,
      window5h:   state.window5h,
      window7d:   state.window7d,
      rateLimits: state.rateLimits,
    }), 'utf8');
  } catch (_) {}
}
const _persisted = loadPersistedState();

// State
let state = {
  status: 'green',       // green | yellow | red
  currentTool: null,     // tool name when yellow
  permission: null,      // permission request when red
  tokenUsage: _persisted.tokenUsage || {
    input_tokens: 0,
    output_tokens: 0,
    cache_read_input_tokens: 0,
    cache_creation_input_tokens: 0,
    total_cost_usd: 0
  },
  sessionId: null,
  lastActivity: null,
  activityLog: [],       // last 20 events
  totalToolCalls: 0,
  totalPermissions: 0,
  window5h: _persisted.window5h || { input_tokens: 0, output_tokens: 0 },
  window7d: _persisted.window7d || { input_tokens: 0, output_tokens: 0 },
  rateLimits: _persisted.rateLimits || null
};

function addActivity(type, message, detail) {
  const entry = { type, message, detail, time: Date.now() };
  state.activityLog.unshift(entry);
  if (state.activityLog.length > 20) state.activityLog.pop();
}

function broadcast(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const client of sseClients) {
    try { client.write(msg); } catch (_) {}
  }
}

// ── Watchdog: self-heal a stuck "yellow" ─────────────────────────────────────
// Only applies to 'yellow' — that's the state that can get stuck with no
// natural follow-up (missed Stop hook, a background task looping forever).
// 'red' is deliberately NEVER touched here: it's a pending permission request
// awaiting a real human decision, and it already has its own long timeout
// (see /hook/permission's pendingRequests promise) that resolves it properly —
// this watchdog must not race ahead of that and flip it green while someone
// is still mid-decision.
const STUCK_TIMEOUT_MS = 5 * 60 * 1000;
setInterval(() => {
  if (state.status === 'yellow' && state.lastActivity &&
      Date.now() - state.lastActivity > STUCK_TIMEOUT_MS) {
    state.status = 'green';
    state.currentTool = null;
    addActivity('stop', '长时间无活动，自动恢复为空闲状态');
    broadcast('state', state);
  }
}, 30_000);


// ── SSE stream — no auth check, see the security note above ─────────────────
app.get('/events', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.flushHeaders();

  sseClients.add(res);
  // Send current state immediately on connect
  res.write(`event: state\ndata: ${JSON.stringify(state)}\n\n`);

  const heartbeat = setInterval(() => {
    try { res.write(': ping\n\n'); } catch (_) { clearInterval(heartbeat); }
  }, 15000);

  req.on('close', () => {
    sseClients.delete(res);
    clearInterval(heartbeat);
  });
});

// ── Hook: PermissionRequest (BLOCKING – holds HTTP until user decides) ──────
app.post('/hook/permission', async (req, res) => {
  const body = req.body;
  const id = `p_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

  console.log('[PermissionRequest]', JSON.stringify(body, null, 2));

  state.status = 'red';
  state.sessionId = body.session_id || state.sessionId;
  state.lastActivity = Date.now();
  state.totalPermissions++;
  state.permission = {
    id,
    tool_name: body.tool_name || body.toolName || '未知工具',
    tool_input: body.tool_input || body.toolInput || {},
    permission_suggestions: body.permission_suggestions || [],
    timestamp: Date.now()
  };
  addActivity('permission', `权限请求: ${state.permission.tool_name}`, body.tool_input);
  broadcast('state', state);

  // Block until user decides (or 5-minute timeout → deny)
  const decision = await new Promise((resolve) => {
    pendingRequests.set(id, resolve);
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        resolve('deny');
      }
    }, 300_000);
  });

  // Approved → the tool is about to run (PreToolUse/PostToolUse will follow), so yellow is right.
  // Denied → nothing is going to execute; don't claim we're busy. If the model keeps working
  // afterward, the next PreToolUse will correctly flip this back to yellow on its own.
  state.status = decision === 'approve' ? 'yellow' : 'green';
  state.permission = null;
  addActivity(decision === 'approve' ? 'approved' : 'denied',
    `${decision === 'approve' ? '✅ 已批准' : '❌ 已拒绝'}: ${body.tool_name}`);
  broadcast('state', state);

  if (decision === 'approve') {
    res.json({
      hookSpecificOutput: {
        hookEventName: 'PermissionRequest',
        decision: { behavior: 'allow' }
      }
    });
  } else {
    res.json({
      hookSpecificOutput: {
        hookEventName: 'PermissionRequest',
        decision: { behavior: 'deny', message: '已通过 Web 面板拒绝' }
      }
    });
  }
});

// ── Hook: PreToolUse ────────────────────────────────────────────────────────
app.post('/hook/pretool', (req, res) => {
  const body = req.body;
  console.log('[PreToolUse] FULL:', JSON.stringify(body).slice(0, 800));

  state.status = 'yellow';
  state.currentTool = body.tool_name || body.toolName || '执行中';
  state.sessionId = body.session_id || state.sessionId;
  state.lastActivity = Date.now();
  state.totalToolCalls++;
  addActivity('tool', `工具调用: ${state.currentTool}`, body.tool_input);
  broadcast('state', state);

  res.json({});
});

// ── Hook: PostToolUse ───────────────────────────────────────────────────────
app.post('/hook/posttool', (req, res) => {
  const body = req.body;
  console.log('[PostToolUse]', body.tool_name, JSON.stringify(body).slice(0, 200));

  state.status = 'yellow';
  state.currentTool = null;
  state.sessionId = body.session_id || state.sessionId;
  state.lastActivity = Date.now();

  // Capture token usage if present (some Claude Code versions include it here)
  const u = body.usage || body.token_usage || null;
  if (u && (u.input_tokens || u.inputTokens)) {
    state.tokenUsage = {
      input_tokens:               u.input_tokens || u.inputTokens || 0,
      output_tokens:              u.output_tokens || u.outputTokens || 0,
      cache_read_input_tokens:    u.cache_read_input_tokens || u.cacheReadInputTokens || 0,
      cache_creation_input_tokens:u.cache_creation_input_tokens || u.cacheCreationInputTokens || 0,
      total_cost_usd:             u.total_cost_usd || u.totalCostUsd || 0
    };
  }

  broadcast('state', state);
  res.json({});
});

// ── Hook: Stop / SubagentStop ───────────────────────────────────────────────
app.post('/hook/stop', (req, res) => {
  const body = req.body;
  console.log('[Stop] FULL BODY:', JSON.stringify(body));

  state.status = 'green';
  state.currentTool = null;
  state.permission = null;
  state.sessionId = body.session_id || state.sessionId;
  state.lastActivity = Date.now();

  // Capture token usage - try every known field name
  const u = body.usage || body.token_usage || body.tokens || null;
  if (u && (u.input_tokens || u.inputTokens)) {
    state.tokenUsage = {
      input_tokens:               u.input_tokens || u.inputTokens || 0,
      output_tokens:              u.output_tokens || u.outputTokens || 0,
      cache_read_input_tokens:    u.cache_read_input_tokens || u.cacheReadInputTokens || 0,
      cache_creation_input_tokens:u.cache_creation_input_tokens || u.cacheCreationInputTokens || 0,
      total_cost_usd:             u.total_cost_usd || u.totalCostUsd || body.total_cost || 0
    };
  } else if (body.total_cost !== undefined) {
    state.tokenUsage.total_cost_usd = body.total_cost;
  }
  if (body.window5h) state.window5h = body.window5h;
  if (body.window7d) state.window7d = body.window7d;

  addActivity('stop', '对话任务完成');
  broadcast('state', state);

  res.json({});
});

// ── Token-only update (from stop-hook.ps1, doesn't change status) ──────────
app.post('/hook/token', (req, res) => {
  const body = req.body;
  const u = body.usage || {};
  if (u.input_tokens) {
    state.tokenUsage = {
      input_tokens:               u.input_tokens || 0,
      output_tokens:              u.output_tokens || 0,
      cache_read_input_tokens:    u.cache_read_input_tokens || 0,
      cache_creation_input_tokens:u.cache_creation_input_tokens || 0,
      total_cost_usd:             u.total_cost_usd || 0
    };
  }
  if (body.window5h) state.window5h = body.window5h;
  if (body.window7d) state.window7d = body.window7d;
  if (body.rate_limits) state.rateLimits = body.rate_limits;
  if (body.session_id) state.sessionId = body.session_id;
  persistState();
  broadcast('state', state);
  res.json({});
});

// ── User decision endpoint — no auth check, see the security note above ────
app.post('/decision/:id', (req, res) => {
  const { id } = req.params;
  const { action } = req.body;

  if (!pendingRequests.has(id)) {
    return res.status(404).json({ error: '请求不存在或已超时' });
  }

  const resolve = pendingRequests.get(id);
  pendingRequests.delete(id);
  resolve(action === 'approve' ? 'approve' : 'deny');

  res.json({ ok: true, action });
});

// ── Health / state API ──────────────────────────────────────────────────────
app.get('/api/state', (req, res) => res.json(state));

// ── Admin: upload new index.html via POST (secret-protected) ─────────────
const fs = require('fs');
const UPLOAD_SECRET = process.env.UPLOAD_SECRET;
if (!UPLOAD_SECRET) throw new Error('UPLOAD_SECRET env var is required');
app.post('/admin/upload-html', (req, res) => {
  const auth = req.headers['x-upload-secret'] || '';
  if (auth !== UPLOAD_SECRET) return res.status(403).json({ error: 'forbidden' });
  const { html } = req.body;
  if (!html || typeof html !== 'string') return res.status(400).json({ error: 'missing html' });
  const dest = path.join(__dirname, 'public', 'index.html');
  try {
    fs.writeFileSync(dest, html, 'utf8');
    console.log('[Admin] index.html updated, size:', html.length);
    res.json({ ok: true, size: html.length });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`✅ claudestate running on http://0.0.0.0:${PORT}`);
  console.log(`   Hook endpoints:`);
  console.log(`     POST /hook/permission`);
  console.log(`     POST /hook/pretool`);
  console.log(`     POST /hook/posttool`);
  console.log(`     POST /hook/stop`);
});
