const express = require('express');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = process.env.PORT || 3457;

const UPLOAD_SECRET = process.env.UPLOAD_SECRET;
if (!UPLOAD_SECRET) throw new Error('UPLOAD_SECRET env var is required');

// ─────────────────────────────────────────────────────────────────────────
// SECURITY NOTE: as shipped, nothing below this line authenticates who's
// calling /events or /decision/:id — the original private deployment this
// was extracted from had a phone/SMS + TOTP-approval + signed-cookie layer
// here, all removed for this public template because it was too specific to
// generalize (and too easy to misconfigure by copy-pasting someone else's
// secrets). If you expose this publicly, decide your own risk tolerance and
// add your own gate — e.g. re-check whatever your PHP login layer's
// auth_current_user() considers valid, put this whole app behind a VPN/IP
// allowlist, or reintroduce a signed-cookie handshake if you need
// cross-process verification between this Node service and the PHP layer.
// ─────────────────────────────────────────────────────────────────────────

// ── Express ───────────────────────────────────────────────────────────────────
app.use(express.json({ limit: '10mb' }));

// ── SSE + State ───────────────────────────────────────────────────────────────
const sseClients = new Set();
const pendingRequests = new Map();

let state = {
  status: 'green',
  currentTool: null,
  permission: null,
  sessionId: null,
  lastActivity: null,
  activityLog: [],
  hermesOnline: false,
};

function addActivity(type, message, detail) {
  state.activityLog.unshift({ type, message, detail: detail || null, time: Date.now() });
  if (state.activityLog.length > 30) state.activityLog.pop();
}

function broadcast(ev, data) {
  const msg = `event: ${ev}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const c of sseClients) { try { c.write(msg); } catch (_) {} }
}

// ── Watchdog: self-heal a stuck "yellow" ─────────────────────────────────────
// Only applies to 'yellow' — that's the state that can get stuck with no
// natural follow-up (missed turn-end, a background task looping forever).
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

// SSE — no auth check, see the security note above
app.get('/events', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();
  sseClients.add(res);
  res.write(`event: state\ndata: ${JSON.stringify(state)}\n\n`);
  const hb = setInterval(() => { try { res.write(': ping\n\n'); } catch (_) { clearInterval(hb); } }, 15000);
  req.on('close', () => { sseClients.delete(res); clearInterval(hb); });
});

// ── Hook: Hermes process watcher ──────────────────────────────────────────────
app.post('/hook/hermes-online', (req, res) => {
  state.hermesOnline = true;
  if (state.status !== 'red') state.status = 'green';
  addActivity('online', 'Hermes 已启动');
  broadcast('state', state);
  res.json({});
});

app.post('/hook/hermes-offline', (req, res) => {
  state.hermesOnline = false;
  state.status = 'green';
  state.currentTool = null;
  state.permission = null;
  addActivity('offline', 'Hermes 已关闭');
  broadcast('state', state);
  res.json({});
});

// ── Hook: PermissionRequest ───────────────────────────────────────────────────
app.post('/hook/permission', async (req, res) => {
  const body = req.body;
  const id = `p_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  state.status = 'red';
  state.sessionId = body.session_id || state.sessionId;
  state.lastActivity = Date.now();
  state.permission = {
    id,
    tool_name: body.tool_name || body.toolName || '未知工具',
    tool_input: body.tool_input || body.toolInput || {},
    permission_suggestions: body.permission_suggestions || [],
    timestamp: Date.now()
  };
  addActivity('permission', `权限请求: ${state.permission.tool_name}`, state.permission.tool_input);
  broadcast('state', state);

  const decision = await new Promise(resolve => {
    pendingRequests.set(id, resolve);
    setTimeout(() => { if (pendingRequests.has(id)) { pendingRequests.delete(id); resolve('deny'); } }, 300_000);
  });

  // Approved → the tool is about to run (PreToolUse/PostToolUse will follow), so yellow is right.
  // Denied → nothing is going to execute; don't claim we're busy. If the model keeps working
  // afterward, the next PreToolUse will correctly flip this back to yellow on its own.
  state.status = decision === 'approve' ? 'yellow' : 'green';
  state.permission = null;
  addActivity(decision === 'approve' ? 'approved' : 'denied',
    `${decision === 'approve' ? '✅ 已批准' : '❌ 已拒绝'}: ${body.tool_name || '工具'}`);
  broadcast('state', state);

  res.json(decision === 'approve'
    ? { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow' } } }
    : { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'deny', message: '已通过 Hermes 面板拒绝' } } }
  );
});

// ── Hook: PreToolCall ─────────────────────────────────────────────────────────
app.post('/hook/pretool', (req, res) => {
  const body = req.body;
  state.status = 'yellow';
  state.currentTool = body.tool_name || body.toolName || '执行中';
  state.sessionId = body.session_id || state.sessionId;
  state.lastActivity = Date.now();
  addActivity('tool', `工具: ${state.currentTool}`, body.tool_input);
  broadcast('state', state);
  res.json({});
});

// ── Hook: PostToolCall ────────────────────────────────────────────────────────
app.post('/hook/posttool', (req, res) => {
  const body = req.body;
  state.status = 'yellow';
  state.currentTool = null;
  state.sessionId = body.session_id || state.sessionId;
  state.lastActivity = Date.now();
  broadcast('state', state);
  res.json({});
});

// ── Hook: TurnStart (log-detected: agent.turn_context: conversation turn) ─────
app.post('/hook/turn-start', (req, res) => {
  state.status = 'yellow';
  state.lastActivity = Date.now();
  addActivity('tool', '对话处理中');
  broadcast('state', state);
  res.json({});
});

// ── Hook: TurnEnd (log-detected: agent.conversation_loop: Turn ended) ─────────
app.post('/hook/turn-end', (req, res) => {
  if (state.status === 'yellow') {
    state.status = 'green';
    state.currentTool = null;
    addActivity('stop', '任务已完成');
    broadcast('state', state);
  }
  res.json({});
});

// ── Hook: Stop ────────────────────────────────────────────────────────────────
app.post('/hook/stop', (req, res) => {
  const body = req.body;
  state.status = 'green';
  state.currentTool = null;
  state.permission = null;
  state.sessionId = body.session_id || state.sessionId;
  state.lastActivity = Date.now();
  addActivity('stop', '对话任务已完成');
  broadcast('state', state);
  res.json({});
});

// ── Decision — no auth check, see the security note above ──────────────────
app.post('/decision/:id', (req, res) => {
  const { id } = req.params;
  const { action } = req.body;
  if (!pendingRequests.has(id)) return res.status(404).json({ error: '请求不存在或已超时' });
  const resolve = pendingRequests.get(id);
  pendingRequests.delete(id);
  resolve(action === 'approve' ? 'approve' : 'deny');
  res.json({ ok: true, action });
});

app.get('/api/state', (req, res) => res.json(state));

// ── Upload HTML ───────────────────────────────────────────────────────────────
app.post('/admin/upload-html', (req, res) => {
  if ((req.headers['x-upload-secret'] || '') !== UPLOAD_SECRET)
    return res.status(403).json({ error: 'forbidden' });
  const { html } = req.body;
  if (!html) return res.status(400).json({ error: 'missing html' });
  try {
    fs.writeFileSync(path.join(__dirname, 'public', 'index.html'), html, 'utf8');
    res.json({ ok: true, size: html.length });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.listen(PORT, () => console.log(`✅ hermesstate running on http://0.0.0.0:${PORT}`));

// ── Internal state (localhost only, no auth) ──────────────────────────────────
app.get('/internal/state', (req, res) => {
  const ip = req.socket.remoteAddress || '';
  if (ip !== '127.0.0.1' && ip !== '::1' && ip !== '::ffff:127.0.0.1') {
    return res.status(403).end();
  }
  res.json({ status: state.status });
});
