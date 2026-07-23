# ClaudeState Background Watcher
# Watches JSONL files for changes and pushes token data to dashboard
# Runs silently in background, started by Task Scheduler on Windows logon
# EDIT ME: point this at your own deployment

$ErrorActionPreference = 'SilentlyContinue'
$SERVER  = "https://YOUR-DOMAIN/claudestate/hook/token"
$LOGFILE = "$env:TEMP\cls_watcher.log"
$RATEFILE = "$env:TEMP\cls_watcher_last.txt"

function Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Add-Content $LOGFILE
}

function Invoke-UsageApi($token) {
    $h = @{ "Authorization" = "Bearer $token"; "anthropic-beta" = "oauth-2025-04-20" }
    Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Method GET -Headers $h -TimeoutSec 8
}

function Get-RateLimits {
    $creds_path  = "$env:USERPROFILE\.claude\.credentials.json"
    $token_path  = "$env:USERPROFILE\.claude\.cls_token"
    $token = $null

    if (Test-Path $creds_path) {
        try {
            $c = Get-Content $creds_path -Raw | ConvertFrom-Json
            if ($c.claudeAiOauth.accessToken) { $token = $c.claudeAiOauth.accessToken }
        } catch {}
    }

    if ($token) {
        try { return Invoke-UsageApi $token } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 401 -and (Test-Path $token_path)) {
                try { $token = (Get-Content $token_path -Raw).Trim(); return Invoke-UsageApi $token } catch {}
            }
        }
    } elseif (Test-Path $token_path) {
        try { $token = (Get-Content $token_path -Raw).Trim(); return Invoke-UsageApi $token } catch {}
    }
    return $null
}

function Push-TokenData($transcript) {
    # Rate limit: max once per 30s
    $now  = [int](Get-Date -UFormat %s)
    $last = 0
    if (Test-Path $RATEFILE) { try { $last = [int](Get-Content $RATEFILE) } catch {} }
    if (($now - $last) -lt 30) { return }
    $now | Out-File $RATEFILE -Encoding ascii

    $cutoff5h = (Get-Date).ToUniversalTime().AddHours(-5)
    $cutoff7d = (Get-Date).ToUniversalTime().AddDays(-7)

    # Context window from transcript
    $ctx_cr = 0; $ctx_cc = 0; $ctx_it = 0; $ctx_ot = 0
    try {
        Get-Content $transcript -Tail 200 -ErrorAction Stop | ForEach-Object {
            try {
                $e = $_ | ConvertFrom-Json
                if ($e.type -eq "assistant" -and $e.message.usage) {
                    $u = $e.message.usage
                    $ctx_cr = [int]($u.cache_read_input_tokens    ?? 0)
                    $ctx_cc = [int]($u.cache_creation_input_tokens ?? 0)
                    $ctx_it = [int]($u.input_tokens ?? 0)
                    $ctx_ot = [int]($u.output_tokens ?? 0)
                }
            } catch {}
        }
    } catch {}

    $ctx_used = $ctx_cr + $ctx_cc + $ctx_it
    if ($ctx_used -eq 0) { return }

    # 5h/7d windows
    $win5h_in = 0; $win5h_out = 0; $win7d_in = 0; $win7d_out = 0
    $project_dir = Split-Path $transcript -Parent
    Get-ChildItem $project_dir -Filter "*.jsonl" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LastWriteTimeUtc -lt $cutoff7d) { return }
        Get-Content $_.FullName | ForEach-Object {
            try {
                $e = $_ | ConvertFrom-Json
                if ($e.type -eq "assistant" -and $e.message.usage -and $e.timestamp) {
                    $u  = $e.message.usage
                    $cc = [int]($u.cache_creation_input_tokens ?? 0)
                    $it = [int]($u.input_tokens ?? 0)
                    $ot = [int]($u.output_tokens ?? 0)
                    $ts = [datetime]::Parse($e.timestamp).ToUniversalTime()
                    if ($ts -ge $cutoff5h) { $win5h_in += $cc + $it; $win5h_out += $ot }
                    if ($ts -ge $cutoff7d) { $win7d_in += $cc + $it; $win7d_out += $ot }
                }
            } catch {}
        }
    }

    # Official rate limits
    $rl = $null
    $usage = Get-RateLimits
    if ($usage -and ($usage.five_hour -or $usage.seven_day)) {
        $rl = @{
            five_hour = @{ used_percentage = [double]($usage.five_hour.utilization ?? 0); resets_at = $usage.five_hour.resets_at }
            seven_day = @{ used_percentage = [double]($usage.seven_day.utilization ?? 0); resets_at = $usage.seven_day.resets_at }
        }
    }

    # Find current session_id from transcript filename
    $session_id = [System.IO.Path]::GetFileNameWithoutExtension($transcript)

    $payload = @{
        session_id = $session_id
        usage      = @{ input_tokens = $ctx_used; output_tokens = $ctx_ot; cache_read_input_tokens = $ctx_cr; cache_creation_input_tokens = $ctx_cc; total_cost_usd = 0 }
        window5h   = @{ input_tokens = $win5h_in; output_tokens = $win5h_out }
        window7d   = @{ input_tokens = $win7d_in; output_tokens = $win7d_out }
    }
    if ($rl) { $payload.rate_limits = $rl }

    try {
        Invoke-RestMethod -Uri $SERVER -Method POST -Body ($payload | ConvertTo-Json -Depth 6) -ContentType "application/json" -TimeoutSec 10 | Out-Null
        Log "PUSH OK ctx=$ctx_used rl=$(if($rl){'yes'}else{'no'})"
    } catch { Log "PUSH ERROR: $_" }
}

Log "Watcher started (PID $PID)"

# Watch the .claude/projects directory for all JSONL changes
$watchPath = "$env:USERPROFILE\.claude\projects"
if (-not (Test-Path $watchPath)) { New-Item $watchPath -ItemType Directory -Force | Out-Null }

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path   = $watchPath
$watcher.Filter = "*.jsonl"
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
$watcher.EnableRaisingEvents = $true

Log "Watching: $watchPath"

while ($true) {
    $evt = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Changed, 5000)
    if (-not $evt.TimedOut) {
        $changed = Join-Path $watchPath $evt.Name
        if (Test-Path $changed) {
            Push-TokenData $changed
        }
    }
}
