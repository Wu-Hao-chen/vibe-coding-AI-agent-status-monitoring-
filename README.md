# state-dashboards

三个独立的 AI Agent 活动监控面板，各自监控一个不同的 Agent，用红/黄/绿灯 + Token 用量 + 远程审批展示"它现在在干嘛"。

| 项目 | 监控对象 | 后端 | 客户端集成 |
|------|---------|------|-----------|
| [`claudestate/`](claudestate) | Claude Code | Node.js + Express（SSE 实时推送） | Claude Code 原生 hook 机制 |
| [`hermesstate/`](hermesstate) | Hermes（桌面 Agent） | Node.js + Express（SSE 实时推送） | PowerShell 脚本轮询进程 + tail 日志 |
| [`codexstate/`](codexstate) | 你自己的 Agent | 纯 PHP + JSON 文件（前端轮询） | 你自己实现，按文档里的接口约定调用 |

每个子目录都有自己的 README，包含完整部署步骤。

## 通用架构

三者都遵循同一套模式：

1. **Node/PHP 后端**接收本地脚本 POST 上来的状态，维护一个内存/文件里的当前状态对象。
2. **前端仪表盘**（SSE 推送或轮询）实时展示红/黄/绿灯 + 用量数据。
3. **PHP 登录网关**挡在仪表盘前面：要求先登录你自己的上层账号系统（`role === 'super_admin'`），通过后直接进仪表盘。
4. ClaudeState / HermesState 额外用一个 HMAC 签名的 cookie，让 PHP（登录网关）和 Node（实时推送）这两个独立进程之间互相验证身份。

## 这不是一个开箱即用的产品

这是从一套真实私有部署里拆出来、去掉了所有真实密钥/域名/个人信息的参考实现，不是一个"装好就能跑"的成品：

- 需要你自己有一个提供 `auth_current_user()` 的登录网关（本仓库不含）。
- `hermesstate` 的日志正则是针对特定版本 Hermes 写的，换个 Agent 大概率需要自己重写这部分。
- `codexstate` 需要你自己写 Agent 侧的上报脚本。

如果你想加更强的身份验证（手机验证码、TOTP、passkey 等），三个 `php/index.php` 里"登录检查通过后"的那一小段就是插入点。

如果你只是想抄一部分思路（比如 Claude Code 的 hook 集成方式，或者"红黄绿灯 + SSE"这套前端模式），单独看某个子目录即可，不需要整套部署。

## 安全注意事项

- **不要把真实的 `config.php` / `.env` 提交到公开仓库**——`.gitignore` 已经排除了它们，只保留 `.example` 模板。
- `CLS_COOKIE_KEY` / `HMS_COOKIE_KEY` 都是签名密钥，一旦泄露，任何人都能伪造一个"已登录"的身份，务必只保存在你自己的服务器上。
- `CODEXSTATE_AGENT_TOKEN` 泄露的后果是任何人都能伪造状态更新甚至下发批准指令，同样要妥善保管。
