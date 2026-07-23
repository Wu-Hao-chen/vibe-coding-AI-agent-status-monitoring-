# ClaudeState

Claude Code 实时活动监控面板：显示当前工具调用状态（红/黄/绿灯）、Token 用量、官方速率限制百分比，并支持远程审批权限请求（TOTP 二次确认）。

## 架构

```
Claude Code (交互式终端 CLI)
    │
    ├─ PreToolUse Hook ──────────────► POST /hook/pretool  ─► 状态变黄（工具执行中）
    ├─ PostToolUse Hook ─────────────► POST /hook/posttool
    ├─ PermissionRequest Hook ───────► POST /hook/permission ─► 面板显示红灯 + 审批弹窗
    │                                      └─ 批准需输入 TOTP 动态码
    ├─ Stop Hook ────────────────────► POST /hook/stop ─► 状态变绿
    └─ StatusLine（仅交互式 CLI 有效）─► hooks/statusline.ps1 ─► 官方 5h/7d 速率限制

浏览器 ── GET /claudestate/ ── PHP 网关：检查你自己的登录系统 → 设置一个签名 cookie → 直接返回仪表盘
      └── SSE /claudestate/events ── Node.js 用这个签名 cookie 验证请求，实时推送状态
```

## 目录结构

| 路径 | 说明 |
|------|------|
| `server.js` | Node.js 后端：接收 hook、SSE 推送、TOTP 审批 |
| `public/index.html` | 仪表盘前端 |
| `php/` | 登录网关：检查你自己的 SSO，通过后签发一个 Node 端能验证的 cookie |
| `hooks/` | 需要拷贝到你自己电脑 `~/.claude/` 目录下的本地 hook 脚本 |
| `.env.example` | Node 服务需要的环境变量模板 |

## 部署步骤

### 1. 服务端（Node.js）

```bash
cd claudestate
npm install
cp .env.example .env   # 填入你自己的 CLS_COOKIE_KEY / UPLOAD_SECRET
node server.js         # 或用 systemd / pm2 常驻
```

用 nginx（或其他反向代理）把 `/claudestate/events`、`/claudestate/hook/*`、`/claudestate/api/*`、`/claudestate/decision/*` 代理到这个 Node 服务的端口（默认 3456）。

### 2. PHP 登录网关

把 `php/` 目录部署到你网站的 `/claudestate/` 路径下：

```bash
cp php/config.example.php php/config.php
# 编辑 config.php，填入你自己的域名、密钥等
```

`php/auth.php` 顶部有一行：

```php
require_once '/path/to/your/auth-gateway/app.php';
```

这里假设你已经有一个更上层的登录系统，提供 `auth_current_user(): ?array`（至少返回 `['id' => int, 'role' => string]`）。本仓库不含这部分——可以是你自己的 SSO、一个简单的密码墙，怎么实现都行，只要接口对得上。**登录通过后就直接看到仪表盘，没有额外的验证步骤**——如果你想加一层（手机验证码、TOTP 等），可以在 `php/index.php` 里 `cls_set_trusted($user)` 之前插入你自己的检查逻辑。

### 3. 本地 Hook 脚本

在你自己电脑上：

```powershell
irm https://YOUR-DOMAIN/claudestate/install/install.ps1 | iex
```

或手动把 `hooks/` 下的 `.ps1` 文件拷贝到 `%USERPROFILE%\.claude\`，并在 `settings.json` 里配置对应的 hooks（`install.ps1` 会自动做这件事，见其源码）。

**重要**：`hooks/*.ps1` 里都有一行 `EDIT ME`，把 `YOUR-DOMAIN` 换成你自己部署的域名。

### 4. 官方速率限制数据（可选，但推荐）

`statusline.ps1` 拿到的 5h/7d 官方速率限制百分比，只有在**真实的交互式 `claude` 终端 CLI**（不是通过 IDE 插件 / SDK / 托管环境跑的那种）运行时才会被 Claude Code 自动计算并传入 —— 这是最准确的数据来源，不需要任何 token 或密钥。

如果没有条件跑交互式 CLI，`post-tool-hook.ps1` / `stop-hook.ps1` 会尝试读取 `~/.claude/.credentials.json`（`claude login` 生成）里的 OAuth token 调用官方用量接口作为备选；如果两者都没有，面板仍会显示基于本地 `.jsonl` 会话记录估算的用量（不如官方数据精确，但不需要任何凭证）。

## 已知的架构限制

- **单一全局状态**：Node 服务只维护一份 state，不区分是哪个 Claude Code 窗口/会话发来的 hook。如果你同时开着多个窗口，面板显示的是"最后一个发送 hook 的窗口"的状态，不一定是你正在看的那个窗口。
- **红灯（等待权限批准）不会被自动清除**：这是有意为之——批准/拒绝有自己独立的等待逻辑和超时机制，不应该被"长时间无活动自动恢复"之类的看门狗提前打断。只有黄灯（工具执行中）会在 5 分钟无新活动后自动恢复为绿灯。
