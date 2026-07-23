# HermesState

跟 [ClaudeState](../claudestate) 同构的监控面板，用于监控一个叫 "Hermes" 的桌面 AI Agent（进程名 `Hermes.exe`）的在线状态和活动情况：红/黄/绿灯 + Token 用量 + 远程审批权限请求。

## 安全模型

**本项目不包含内置的身份验证或权限控制。** 面板前面唯一的门槛是 `php/index.php` 对 `auth_current_user()` 返回值的检查，`server.js` 暴露的 `/events`、`/decision/:id`、`/api/state` 均不做身份校验。设计取舍与风险说明详见 [../claudestate/README.md](../claudestate/README.md) 的"安全模型"一节——两个项目完全一致。

## 架构

```
Hermes.exe（桌面应用）
    │
    ├─ hooks/hermes-monitor.ps1 ──────► 每 5s 轮询进程是否在跑
    │       │                            └─ POST /hook/hermes-online / hermes-offline
    │       └─ 拉起 hermes-log-monitor.ps1
    │
    └─ hooks/hermes-log-monitor.ps1 ──► tail 本地 agent.log
            │                            匹配到"对话轮次开始/结束"的日志行时：
            └─ POST /hook/turn-start / turn-end ─► 驱动黄/绿灯

浏览器 ── GET /hermesstate/ ── PHP 网关：检查登录状态 → 返回面板页面
      └── SSE /hermesstate/events ── Node.js 实时推送状态
```

与 ClaudeState 不同，HermesState 没有官方 hook 机制可用，因此状态采集依赖两个独立运行的本地脚本：一个轮询进程是否存活，另一个持续 tail 日志文件、用正则匹配特定的日志行来推断对话轮次的起止。这种"外部观察"式的集成天然比原生 hook 更脆弱，具体限制见下方"日志解析的已知限制"一节。

### 状态对象

```js
{
  status: 'green' | 'yellow' | 'red',
  currentTool: string | null,
  permission: { id, tool_name, tool_input, timestamp } | null,  // status 为 red 时非空
  sessionId: string | null,
  lastActivity: number,
  activityLog: Array<{ type, message, detail, time }>,  // 最近 30 条活动
  hermesOnline: boolean,   // 进程当前是否在跑，由 hermes-monitor.ps1 上报
}
```

不做持久化——Node 服务重启后状态从空闲重新开始。

### 接口一览

| 方法 + 路径 | 用途 | 调用方 |
|---|---|---|
| `GET /events` | SSE 状态流 | 浏览器 |
| `POST /hook/hermes-online` `/hermes-offline` | 上报进程是否存活 | `hermes-monitor.ps1` |
| `POST /hook/turn-start` `/turn-end` | 驱动黄/绿灯 | `hermes-log-monitor.ps1` |
| `POST /hook/pretool` `/posttool` `/stop` | 同 ClaudeState，用于扩展成原生 hook 集成时预留 | — |
| `POST /hook/permission` | 驱动红灯，阻塞至有决定或超时 | 需自行接入的信号源，见下 |
| `POST /decision/:id` | 批准或拒绝一个待处理的权限请求 | 浏览器 |
| `GET /api/state` | 一次性获取当前完整状态 | 任意 |
| `GET /internal/state` | 仅返回 `status` 字段，限制只有 `127.0.0.1` 可访问 | 同机部署的聚合面板等内部用途 |
| `POST /admin/upload-html` | 远程覆盖 `public/index.html`，需 `UPLOAD_SECRET` | 部署脚本 |

## 目录结构

同 [ClaudeState](../claudestate)：`server.js`（Node 后端）、`public/index.html`（面板前端）、`php/`（登录网关）、`hooks/`（本地监控脚本）、`.env.example`。

## 部署步骤

### 1. 服务端（Node.js）+ 2. PHP 登录网关

跟 ClaudeState 完全一样，参见 [../claudestate/README.md](../claudestate/README.md) 的对应章节，把 `claudestate` 换成 `hermesstate`、`CLS_*` 换成 `HMS_*` 即可。

### 3. 本地监控脚本

1. 把 `hooks/hermes-monitor.ps1` 和 `hooks/hermes-log-monitor.ps1` 拷贝到运行 Hermes 的电脑上（比如 `%LOCALAPPDATA%\hermes\hooks\`）。
2. 编辑两个脚本顶部的 `$SERVER` 变量，指向你自己部署的域名。
3. 用 `hooks/hermes-monitor.vbs`（配合 Windows "启动"文件夹，`Win+R` → `shell:startup`）让 `hermes-monitor.ps1` 开机自动静默运行，它会在启动时一并拉起 `hermes-log-monitor.ps1`。**这个 `.vbs` 文件必须保存为无 BOM 的编码**——带 BOM 会导致 VBScript 报 `Invalid character` 直接失败，且失败得很安静，容易长期不被发现。

### 日志解析的已知限制

`hermes-log-monitor.ps1` 里的 `$LOG_PATH` 和两条正则（匹配"对话轮次开始/结束"的日志行）是针对某一个特定版本的 Hermes 写的。这带来两个实际限制：

- **换一个 Agent，或 Hermes 版本更新后日志格式变化**：正则大概率需要对着实际日志重新调整，本仓库不保证在你的环境里开箱即用。
- **红灯（等待权限批准）在实践中很难通过 tail 日志可靠检测**：大多数日志只记录批准/拒绝的最终结果，而不是"弹窗刚出现、正在等待确认"这一刻。如果目标 Agent 有更直接的信号（例如一个专门的窗口标题，或一个独立的状态文件），可以在 `hermes-log-monitor.ps1` 里针对该信号自行实现红灯检测。

## 已知限制

和 ClaudeState 一致：单一全局状态（不区分多进程/多实例）；黄灯 5 分钟无活动自动恢复绿灯，红灯不会被自动清除（生命周期交由等待批准这一动作本身的超时机制决定）。
