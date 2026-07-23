# CodexState

跟 [ClaudeState](../claudestate) 类似的监控面板，但架构不同：**纯 PHP + 本地 JSON 文件存储**，没有 Node.js 服务，状态数据由你自己的 Agent 脚本直接 POST 到 `api.php`。登录只需要通过你自己的 SSO（`auth_current_user()` + 用户名/角色检查），没有额外的验证步骤。

## 架构

```
你自己的 Agent / 监控脚本（本仓库不提供，需要你自己写）
    │
    └─ POST api.php  ─────────► 写入 data/state.json

浏览器 ── GET index.php ── 检查你自己的登录系统，通过后直接返回仪表盘
      └── 轮询 api.php?action=status（每 1.5s）─► 渲染红/黄/绿灯
```

`api.php` 目前没有对应的本地监控脚本——上一次部署这套系统的机器上没有装 Codex 相关的监控脚本，所以这里只能给你 `api.php` 的接口约定，你需要自己写一个脚本，定期（或事件驱动）调用它来上报状态。

## 部署步骤

### 1. 目录部署

把 `php/` 目录整个部署到你网站的 `/codexstate/` 路径下：

```bash
cp php/config.example.php php/config.php
# 编辑 config.php，填入域名、密钥、CODEXSTATE_AGENT_TOKEN、CODEXSTATE_ALLOWED_USERNAME 等
```

同 ClaudeState，`php/auth.php` 顶部需要一个外部登录网关提供 `auth_current_user()`。`CODEXSTATE_TOTP_SECRET` 需要你手动添加到自己的身份验证器 App 里（不会在界面上展示）——它只用于"批准/拒绝一个待处理操作"这个动作的二次确认，跟登录无关。

### 2. `api.php` 接口约定

你自己的 Agent 脚本需要按下面的约定调用 `api.php`：

**上报状态**（每次任务状态变化时调用）：
```
POST /codexstate/api.php
Content-Type: application/x-www-form-urlencoded
Header: X-Codexstate-Token: <CODEXSTATE_AGENT_TOKEN>

op=update
state=waiting|running|done
message=<可选，最长 160 字符的状态描述>
source=<可选，来源标识，最长 40 字符>
tokensRemaining=<可选，整数>
tokensUsed=<可选，整数>
contextWindow=<可选，整数>
rateLimits=<可选，JSON 字符串，见下方结构>
tokenUsage=<可选，JSON 字符串，见下方结构>
```

`rateLimits` JSON 结构：
```json
{
  "limitId": "string",
  "fiveHour": { "usedPercent": 0, "remainingPercent": 100, "windowMinutes": 300, "resetsAt": 0 },
  "weekly":   { "usedPercent": 0, "remainingPercent": 100, "windowMinutes": 10080, "resetsAt": 0 }
}
```

`tokenUsage` JSON 结构：
```json
{
  "total": { "inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": 0 },
  "last":  { "inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": 0 }
}
```

**查询待处理的批准/拒绝指令**（Agent 侧轮询，用于实现"远程审批"）：
```
GET /codexstate/api.php?action=command&token=<CODEXSTATE_AGENT_TOKEN>
```
拿到 `command` 后按 `route` 执行，执行完调用：
```
POST /codexstate/api.php
op=ack
commandId=<command.id>
outcome=ok|failed
result=<可选，执行结果描述，最长 160 字符>
```

**认证方式**：`token` 参数可以放在 POST body、query string，或 `X-Codexstate-Token` header 里，三选一，服务端用 `hash_equals()` 常量时间比较。

**面板自己查看状态**（浏览器侧，走完自己的登录系统即可，不是给 Agent 用的）：
```
GET /codexstate/api.php?action=status
```

**批准/拒绝一个待处理操作**（浏览器侧，需要 CSRF token + 批准时需要 TOTP）：
```
POST /codexstate/api.php
op=decision
csrf=<index.php 页面里嵌入的 CSRF token>
approvalId=<待处理操作的 id>
decision=accept|decline
totp=<仅 decision=accept 时需要，6 位动态验证码>
```

## 安全说明

`CODEXSTATE_AGENT_TOKEN` 是 Agent 脚本和 `api.php` 之间唯一的信任凭证——泄露了等于任何人都能伪造状态更新、甚至下发批准指令。用 `openssl rand -hex 32` 生成，不要复用其他用途的密钥。

## 已知的架构限制

跟 ClaudeState 不同，CodexState 是纯轮询（前端每 1.5s 请求一次 `api.php`），没有 SSE 推送。红灯的自动恢复逻辑本仓库暂未实现——如果需要，可以在 `api.php` 的 `state=waiting`（等待批准）分支里加一个基于 `updatedAt` 的超时判断。
