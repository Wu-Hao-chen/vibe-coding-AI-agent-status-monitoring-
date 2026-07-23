# HermesState

跟 [ClaudeState](../claudestate) 同构的监控面板，用于监控一个叫 "Hermes" 的桌面 AI Agent（进程名 `Hermes.exe`）的在线状态和活动情况。红/黄/绿灯 + Token 用量 + 远程审批权限请求（TOTP 二次确认）。

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

浏览器 ── GET /hermesstate/ ── PHP 网关：检查你自己的登录系统 → 设置一个签名 cookie → 直接返回仪表盘
      └── SSE /hermesstate/events ── Node.js 用这个签名 cookie 验证请求，实时推送状态
```

## 目录结构

同 [ClaudeState](../claudestate)：`server.js`（Node 后端）、`public/index.html`（仪表盘前端）、`php/`（登录网关）、`hooks/`（本地监控脚本）、`.env.example`。

## 部署步骤

### 1. 服务端（Node.js）+ 2. PHP 登录网关

跟 ClaudeState 完全一样，参见 [../claudestate/README.md](../claudestate/README.md) 的对应章节，把 `claudestate` 换成 `hermesstate`、`CLS_*` 换成 `HMS_*` 即可。登录通过你自己的 SSO 后直接进仪表盘，没有额外的验证步骤。

### 3. 本地监控脚本

这部分和 ClaudeState 不同——Hermes 不是 Claude Code，没有官方 hook 机制，监控靠**轮询进程 + tail 日志文件**实现：

1. 把 `hooks/hermes-monitor.ps1` 和 `hooks/hermes-log-monitor.ps1` 拷贝到你自己电脑上（比如 `%LOCALAPPDATA%\hermes\hooks\`）。
2. 编辑两个脚本顶部的 `$SERVER` 变量，指向你自己部署的域名。
3. `hermes-log-monitor.ps1` 里的 `$LOG_PATH` 和两个正则（匹配"对话轮次开始/结束"的日志行）是针对某个特定版本的 Hermes 写的——**如果你监控的是别的 Agent，或 Hermes 版本更新后日志格式变了，这两个正则大概率需要重新对着实际日志调整**，本仓库不保证在你的环境里开箱即用。
4. 用 `hooks/hermes-monitor.vbs`（配合 Windows "启动"文件夹，`Win+R` → `shell:startup`）让它开机自动静默运行。**这个 `.vbs` 文件必须保存为无 BOM 的编码**——带 BOM 会导致 VBScript 报 `Invalid character` 直接失败，且失败得很安静，容易长期不被发现。

### 红灯的已知限制

跟 ClaudeState 不同的是：Hermes 的"等待权限批准"（红灯）在实践中很难通过 tail 日志可靠检测——大多数日志只记录批准/拒绝的**最终结果**，而不是"弹窗刚出现、正在等你确认"这一刻。如果你的 Agent 有更直接的信号（比如一个专门的窗口标题、一个独立的状态文件），红灯检测会更准确，需要你自己在 `hermes-log-monitor.ps1` 里加对应逻辑。

## 已知的架构限制

和 ClaudeState 一致：单一全局状态（不区分多进程/多实例）；黄灯 5 分钟无活动自动恢复绿灯，红灯不会被自动清除（交给它自己的等待/超时逻辑）。
