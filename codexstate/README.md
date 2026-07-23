# CodexState

跟 [ClaudeState](../claudestate) 类似的监控面板，但架构不同：**纯 PHP + 本地 JSON 文件存储**，没有 Node.js 服务，状态数据由你自己的 Agent 脚本直接 POST 到 `api.php`。

## ⚠️ 关于验证/权限控制

**这套代码没有内置的身份验证或权限控制。** 原始部署里有手机验证、TOTP 二次确认、硬编码用户名白名单，这些都跟原来那台服务器强绑定，已经全部拿掉。现在只剩 `cs_user()` 检查你自己的 `auth_current_user()` 有没有返回登录用户——**返回了就直接放行，不检查角色/用户名/权限**。

`api.php` 里"批准/拒绝一个待处理操作"（`op=decision`）只保留了 CSRF 保护，**没有二次确认**——原来这里要求输入 TOTP 动态码，已经删掉。`CODEXSTATE_AGENT_TOKEN` 仍然保护着 Agent 侧的状态上报接口，这个没删（泄露的后果不一样，见下方安全说明）。

部署前请自己评估风险，并在 `auth_current_user()` / `php/auth.php` 里加上你需要的验证方式（角色检查、二次确认、IP 白名单等）。

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
# 编辑 config.php，填入域名、密钥、CODEXSTATE_AGENT_TOKEN 等
```

同 ClaudeState，`php/auth.php` 顶部需要一个外部登录网关提供 `auth_current_user()`。

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

**批准/拒绝一个待处理操作**（浏览器侧，只需要 CSRF token）：
```
POST /codexstate/api.php
op=decision
csrf=<index.php 页面里嵌入的 CSRF token>
approvalId=<待处理操作的 id>
decision=accept|decline
```

## 安全说明

`CODEXSTATE_AGENT_TOKEN` 是 Agent 脚本和 `api.php` 之间唯一的信任凭证——泄露了等于任何人都能伪造状态更新、甚至下发批准指令。用 `openssl rand -hex 32` 生成，不要复用其他用途的密钥。这个是本仓库唯一保留的凭证机制，因为它保护的是"谁能代表你的 Agent 说话"这个跟具体部署强相关的动作，跟被删掉的那些"用户登录后还要不要再验证一次"的环节不是一回事。

## 已知的架构限制

跟 ClaudeState 不同，CodexState 是纯轮询（前端每 1.5s 请求一次 `api.php`），没有 SSE 推送。红灯的自动恢复逻辑本仓库暂未实现——如果需要，可以在 `api.php` 的 `state=waiting`（等待批准）分支里加一个基于 `updatedAt` 的超时判断。
