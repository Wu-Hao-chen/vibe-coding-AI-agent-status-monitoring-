# ClaudeState Installer
# Run with: irm https://YOUR-DOMAIN/claudestate/install/install.ps1 | iex
#
# EDIT ME: set this to wherever you've deployed the server component (see ../server/).

$ErrorActionPreference = 'Stop'
$DOMAIN = "YOUR-DOMAIN"
$BASE = "https://$DOMAIN/claudestate/install"
$CLAUDE_DIR = "$env:USERPROFILE\.claude"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    !! $msg" -ForegroundColor Yellow }

Write-Host @"

  ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗███████╗████████╗ █████╗ ████████╗███████╗
 ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔══██╗╚══██╔══╝██╔════╝
 ██║     ██║     ███████║██║   ██║██║  ██║█████╗  ███████╗   ██║   ███████║   ██║   █████╗
 ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ╚════██║   ██║   ██╔══██║   ██║   ██╔══╝
 ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗███████║   ██║   ██║  ██║   ██║   ███████╗
  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚══════╝
                                                                     Installer v1.0
"@ -ForegroundColor Magenta

# ── 1. Check Claude Code ──────────────────────────────────────────────────────
Write-Step "检查 Claude Code 是否已安装"
try {
    $ver = (claude --version 2>&1)
    Write-OK "Claude Code $ver"
} catch {
    Write-Host "  未找到 claude 命令。请先安装 Claude Code: https://claude.ai/download" -ForegroundColor Red
    exit 1
}

# ── 2. Create .claude directory ───────────────────────────────────────────────
Write-Step "创建配置目录"
if (-not (Test-Path $CLAUDE_DIR)) { New-Item -ItemType Directory -Path $CLAUDE_DIR -Force | Out-Null }
Write-OK $CLAUDE_DIR

# ── 3. Download hook scripts ──────────────────────────────────────────────────
Write-Step "下载 Hook 脚本"
$hooks = @("post-tool-hook.ps1", "stop-hook.ps1", "statusline.ps1")
foreach ($f in $hooks) {
    $dest = "$CLAUDE_DIR\$f"
    try {
        Invoke-WebRequest -Uri "$BASE/$f" -OutFile $dest -UseBasicParsing
        Write-OK $f
    } catch {
        Write-Host "  下载失败: $f ($_)" -ForegroundColor Red
        exit 1
    }
}

# ── 4. Merge settings.json ────────────────────────────────────────────────────
Write-Step "配置 Claude Code Hooks (settings.json)"
$settingsPath = "$CLAUDE_DIR\settings.json"

$hookConfig = @{
    hooks = @{
        PreToolUse = @(@{
            hooks = @(@{ type = "http"; url = "https://$DOMAIN/claudestate/hook/pretool"; timeout = 10 })
        })
        PostToolUse = @(@{
            hooks = @(
                @{ type = "http"; url = "https://$DOMAIN/claudestate/hook/posttool"; timeout = 10 },
                @{ type = "command"; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$CLAUDE_DIR\post-tool-hook.ps1`"" }
            )
        })
        Stop = @(@{
            hooks = @(
                @{ type = "http"; url = "https://$DOMAIN/claudestate/hook/stop"; timeout = 10 },
                @{ type = "command"; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$CLAUDE_DIR\stop-hook.ps1`"" }
            )
        })
        SubagentStop = @(@{
            hooks = @(
                @{ type = "http"; url = "https://$DOMAIN/claudestate/hook/stop"; timeout = 10 },
                @{ type = "command"; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$CLAUDE_DIR\stop-hook.ps1`"" }
            )
        })
        PermissionRequest = @(@{
            hooks = @(@{ type = "http"; url = "https://$DOMAIN/claudestate/hook/permission"; timeout = 310 })
        })
    }
    statusLine = @{ type = "command"; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$CLAUDE_DIR\statusline.ps1`"" }
}

if (Test-Path $settingsPath) {
    # Backup existing settings
    Copy-Item $settingsPath "$settingsPath.bak" -Force
    Write-OK "原 settings.json 已备份至 settings.json.bak"

    # Merge: keep existing keys, add/overwrite hooks and statusLine
    $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $existing.hooks = $hookConfig.hooks
    $existing.statusLine = $hookConfig.statusLine
    $existing | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
} else {
    $hookConfig | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
}
Write-OK "settings.json 已配置"

# ── 5. Token setup ────────────────────────────────────────────────────────────
Write-Step "Claude 认证"

$authOk = $false
try {
    $status = claude auth status --json 2>&1 | ConvertFrom-Json
    if ($status.loggedIn) {
        Write-OK "已登录: $($status.email)"
        $authOk = $true
    }
} catch {}

if (-not $authOk) {
    Write-Warn "未检测到登录状态，请运行以下命令登录："
    Write-Host "    claude login" -ForegroundColor White
    Write-Host "    claude setup-token   # 推荐：生成长期 token" -ForegroundColor White
}

# Optional: save fallback token
Write-Host ""
Write-Host "  如果你有长期 OAuth Token（sk-ant-oat01-...），可以现在输入" -ForegroundColor Gray
Write-Host "  留空则跳过（可以之后手动写入 $CLAUDE_DIR\.cls_token）" -ForegroundColor Gray
$tokenInput = Read-Host "  Token (回车跳过)"
if ($tokenInput.Trim() -ne "") {
    $tokenInput.Trim() | Set-Content "$CLAUDE_DIR\.cls_token" -Encoding ascii -NoNewline
    Write-OK "Token 已保存到 .cls_token"
} else {
    Write-Warn "已跳过，官方用量数据需要 token 才能显示"
}

# ── 6. Done ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ✅ 安装完成！" -ForegroundColor Green
Write-Host ""
Write-Host "  面板地址：https://$DOMAIN/claudestate/" -ForegroundColor Cyan
Write-Host "  重启 Claude Code 后 Hook 生效。" -ForegroundColor Gray
Write-Host ""
