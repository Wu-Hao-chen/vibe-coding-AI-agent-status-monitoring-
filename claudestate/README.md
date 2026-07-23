# ClaudeState

Claude Code 实时活动监控面板：以红/黄/绿灯展示当前工具调用状态、Token 用量与官方速率限制百分比，并支持在网页上远程审批权限请求。

## 安全模型

**本项目不包含内置的身份验证或权限控制。** 面板前面唯一的门槛是 `php/index.php` 对 `auth_current_user()` 返回值的检查——返回一个用户即视为已登录并直接放行，不做角色或权限判断。`server.js` 暴露的 `/events`（实时状态流）与 `/decision/:id`（批准/拒绝权限请求）两个接口本身不做任何身份校验。

这是有意的设计取舍：本仓库是从一套私有部署中提炼、脱敏后发布的参考实现，原部署使用的额外访问控制机制与其具体运行环境高度绑定，无法安全地迁移进一份通用模板。**在公开部署前，请自行评估这一风险，并在 `auth_current_user()` 或 `php/auth.php` 中加入你需要的访问控制**（角色/权限判断、二次验证、IP 白名单，或将服务置于 VPN 之后）。代码中对应位置均留有注释标注。

## 架构

```
Claude Code (交互式终端 CLI)
    │
    ├─ PreToolUse Hook ──────────────► POST /hook/pretool  ─► 状态变黄（工具执行中）
    ├─ PostToolUse Hook ─────────────► POST /hook/posttool
    ├─ PermissionRequest Hook ───────► POST /hook/permission ─► 面板显示红灯 + 审批弹窗
    ├─ Stop Hook ────────────────────► POST /hook/stop ─► 状态变绿
    └─ StatusLine（仅交互式 CLI 有效）─► hooks/statusline.ps1 ─► 官方 5h/7d 速率限制

浏览器 ── GET /claudestate/ ── PHP 网关：检查登录状态 → 返回面板页面
      └── SSE /claudestate/events ── Node.js 实时推送状态
```

### 状态对象

Node 服务在内存中维护一份状态，通过 SSE 广播给所有连接的客户端：

```js
{
  status: 'green' | 'yellow' | 'red',
  currentTool: string | null,        // 当前执行的工具名
  permission: {                       // status 为 red 时非空
    id, tool_name, tool_input, timestamp
  } | null,
  sessionId: string | null,
  lastActivity: number,               // 上次收到 hook 的时间戳（ms）
  activityLog: Array<{ type, message, detail, time }>,  // 最近 20 条活动
  totalToolCalls: number,
  totalPermissions: number,
  tokenUsage: { input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, total_cost_usd },
  window5h: { input_tokens, output_tokens },
  window7d: { input_tokens, output_tokens },
  rateLimits: { five_hour, seven_day } | null
}
```

`.state_cache.json` 会持久化其中的用量数据（`tokenUsage`、`window5h`、`window7d`、`rateLimits`），Node 服务重启后自动恢复；红绿灯状态、当前工具、活动记录不做持久化，重启后从空闲（绿灯）状态重新开始，这是有意的——重启前的"正在执行中"状态在重启后已经不再可信。

### 接口一览

| 方法 + 路径 | 用途 | 调用方 |
|---|---|---|
| `GET /events` | SSE 状态流 | 浏览器 |
| `POST /hook/pretool` `/posttool` `/stop` | 驱动黄/绿灯 | Claude Code hook |
| `POST /hook/permission` | 驱动红灯，阻塞至有决定或超时 | Claude Code hook |
| `POST /hook/token` | 上报 Token 用量 / 官方速率限制 | 本地 PowerShell 脚本 |
| `POST /decision/:id` | 批准或拒绝一个待处理的权限请求 | 浏览器 |
| `GET /api/state` | 一次性获取当前完整状态 | 任意 |
| `POST /admin/upload-html` | 远程覆盖 `public/index.html`，需 `UPLOAD_SECRET` | 部署脚本 |

`/hook/permission` 会阻塞该次 HTTP 请求最多 5 分钟，直到浏览器调用 `/decision/:id` 做出决定，或超时后自动按"拒绝"处理——这也是 Claude Code hook 本身的等待窗口，与面板的实现细节无关。

## 目录结构

| 路径 | 说明 |
|------|------|
| `server.js` | Node.js 后端：接收 hook、SSE 推送、处理批准/拒绝 |
| `public/index.html` | 面板前端 |
| `php/` | 登录网关：检查登录状态，通过后返回面板页面 |
| `hooks/` | 需要安装到运行 Claude Code 的机器上的本地脚本 |
| `.env.example` | Node 服务需要的环境变量模板 |

## 部署步骤

### 1. 服务端（Node.js）

```bash
cd claudestate
npm install
cp .env.example .env   # 填入你自己的 UPLOAD_SECRET
node server.js         # 或用 systemd / pm2 常驻
```

用 nginx（或其他反向代理）把 `/claudestate/events`、`/claudestate/hook/*`、`/claudestate/api/*`、`/claudestate/decision/*` 代理到这个 Node 服务的端口（默认 3456）。

### 2. PHP 登录网关

把 `php/` 目录部署到你网站的 `/claudestate/` 路径下：

```bash
cp php/config.example.php php/config.php
# 编辑 config.php，填入你自己的域名等
```

`php/auth.php` 顶部有一行：

```php
require_once '/path/to/your/auth-gateway/app.php';
```

这里假设你已经有一个更上层的登录系统，提供 `auth_current_user(): ?array`（返回数组表示已登录，`null` 表示未登录）。本仓库不含这部分实现，具体如何认证由你决定——见上方"安全模型"一节。

### 3. 本地 Hook 脚本

在运行 Claude Code 的电脑上：

```powershell
irm https://YOUR-DOMAIN/claudestate/install/install.ps1 | iex
```

或手动把 `hooks/` 下的 `.ps1` 文件拷贝到 `%USERPROFILE%\.claude\`，并在 `settings.json` 里配置对应的 hooks（`install.ps1` 会自动完成这一步，具体配置内容见其源码）。

**注意**：`hooks/*.ps1` 里都有一行 `EDIT ME`，需要把 `YOUR-DOMAIN` 换成你自己部署的域名。

### 4. 官方速率限制数据（可选，但推荐）

`statusline.ps1` 拿到的 5h/7d 官方速率限制百分比，只有在**真实的交互式 `claude` 终端 CLI**（而非通过 IDE 插件 / SDK / 托管环境运行）中，才会被 Claude Code 自动计算并传入——这是最准确的数据来源，不需要任何 token 或密钥。

如果没有条件运行交互式 CLI，`post-tool-hook.ps1` / `stop-hook.ps1` 会尝试读取 `~/.claude/.credentials.json`（`claude login` 生成）中的 OAuth token 调用官方用量接口作为备选；两者都不可用时，面板仍会基于本地 `.jsonl` 会话记录估算用量（精确度不如官方数据，但不依赖任何凭证）。

## 已知限制

- **单一全局状态**：Node 服务只维护一份状态，不区分具体是哪个 Claude Code 窗口/会话上报的。如果同时开着多个窗口，面板显示的是"最后一次上报"的状态，未必是你正在查看的那一个。
- **红灯（等待权限批准）不会被自动清除**：这是有意为之——它的生命周期由权限请求本身的等待/超时机制决定，不应被"长时间无活动自动恢复"的看门狗提前打断。只有黄灯（工具执行中）会在 5 分钟无新活动后自动恢复为绿灯。
