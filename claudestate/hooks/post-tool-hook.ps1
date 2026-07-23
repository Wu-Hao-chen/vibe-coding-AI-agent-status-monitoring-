# PostToolUse hook: update context window + 5h/7d rolling windows, POST to ClaudeState
# EDIT ME: point this at your own deployment
$server = "https://YOUR-DOMAIN/claudestate/hook/token"

$raw = $input | Out-String
$log = "$env:TEMP\cls_hook_debug.log"
$logTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

try { $hook = $raw | ConvertFrom-Json } catch {
    "[${logTs}] ERROR: failed to parse stdin: $_" | Add-Content $log
    Write-Output "{}"; exit 0
}

$transcript = $hook.transcript_path
$session_id = $hook.session_id

if (-not $transcript -or -not (Test-Path $transcript)) {
    "[${logTs}] SKIP: no transcript ($transcript)" | Add-Content $log
    Write-Output "{}"; exit 0
}

# Only update every ~30 seconds
$state_file = "$env:TEMP\cls_last_token_post.txt"
$now = [int](Get-Date -UFormat %s)
$last = 0
if (Test-Path $state_file) { try { $last = [int](Get-Content $state_file) } catch {} }
if (($now - $last) -lt 30) {
    "[${logTs}] SKIP: rate limit ($($now-$last)s since last)" | Add-Content $log
    Write-Output "{}"; exit 0
}
$now | Out-File $state_file -Encoding ascii
"[${logTs}] RUN: session=$session_id" | Add-Content $log

$cutoff5h = (Get-Date).ToUniversalTime().AddHours(-5)
$cutoff7d = (Get-Date).ToUniversalTime().AddDays(-7)

# Context window: LAST assistant usage in current session
$ctx_cr = 0; $ctx_cc = 0; $ctx_it = 0; $ctx_ot = 0
Get-Content $transcript -Tail 200 | ForEach-Object {
    try {
        $entry = $_ | ConvertFrom-Json
        if ($entry.type -eq "assistant" -and $entry.message -and $entry.message.usage) {
            $u = $entry.message.usage
            $ctx_cr = if ($u.cache_read_input_tokens)    { [int]$u.cache_read_input_tokens }    else { 0 }
            $ctx_cc = if ($u.cache_creation_input_tokens){ [int]$u.cache_creation_input_tokens } else { 0 }
            $ctx_it = if ($u.input_tokens)               { [int]$u.input_tokens }               else { 0 }
            $ctx_ot = if ($u.output_tokens)              { [int]$u.output_tokens }              else { 0 }
        }
    } catch {}
}
$ctx_used = $ctx_cr + $ctx_cc + $ctx_it
if ($ctx_used -eq 0) { Write-Output "{}"; exit 0 }

# 5h/7d windows: scan all JSONL in the project directory
$project_dir = Split-Path $transcript -Parent
$win5h_in = 0; $win5h_out = 0; $win7d_in = 0; $win7d_out = 0

$files = Get-ChildItem $project_dir -Filter "*.jsonl" -ErrorAction SilentlyContinue
foreach ($file in $files) {
    if ($file.LastWriteTimeUtc -lt $cutoff7d) { continue }
    Get-Content $file.FullName | ForEach-Object {
        try {
            $entry = $_ | ConvertFrom-Json
            if ($entry.type -eq "assistant" -and $entry.message -and $entry.message.usage -and $entry.timestamp) {
                $u  = $entry.message.usage
                $cc = if ($u.cache_creation_input_tokens){ [int]$u.cache_creation_input_tokens } else { 0 }
                $it = if ($u.input_tokens)               { [int]$u.input_tokens }               else { 0 }
                $ot = if ($u.output_tokens)              { [int]$u.output_tokens }              else { 0 }
                $ts = [datetime]::Parse($entry.timestamp).ToUniversalTime()
                if ($ts -ge $cutoff5h) { $win5h_in += $cc + $it; $win5h_out += $ot }
                if ($ts -ge $cutoff7d) { $win7d_in += $cc + $it; $win7d_out += $ot }
            }
        } catch {}
    }
}

# Official rate limits via Claude credentials
$rate_limits = $null

function Invoke-UsageApi($token) {
    $headers = @{
        "Authorization"  = "Bearer $token"
        "anthropic-beta" = "oauth-2025-04-20"
        "User-Agent"     = "claude-code/2.1.181"
    }
    return Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
        -Method GET -Headers $headers -TimeoutSec 8
}

function Parse-UsageResponse($usage) {
    if ($usage.five_hour -or $usage.seven_day) {
        return @{
            five_hour = @{
                used_percentage = if ($usage.five_hour.utilization) { [double]$usage.five_hour.utilization } else { 0 }
                resets_at       = if ($usage.five_hour.resets_at)   { $usage.five_hour.resets_at } else { $null }
            }
            seven_day = @{
                used_percentage = if ($usage.seven_day.utilization) { [double]$usage.seven_day.utilization } else { 0 }
                resets_at       = if ($usage.seven_day.resets_at)   { $usage.seven_day.resets_at } else { $null }
            }
        }
    }
    return $null
}

# Try credentials.json first (created by `claude login`)
$creds_path = "$env:USERPROFILE\.claude\.credentials.json"
if (Test-Path $creds_path) {
    try {
        $creds = Get-Content $creds_path -Raw | ConvertFrom-Json
        $token = $null
        if ($creds.claudeAiOauth -and $creds.claudeAiOauth.accessToken) { $token = $creds.claudeAiOauth.accessToken }
        elseif ($creds.access_token) { $token = $creds.access_token }
        elseif ($creds.token)        { $token = $creds.token }

        if ($token) {
            try {
                $usage = Invoke-UsageApi $token
                $rate_limits = Parse-UsageResponse $usage
                if ($rate_limits) { "[${logTs}] API OK: 5h=$($rate_limits.five_hour.used_percentage)% 7d=$($rate_limits.seven_day.used_percentage)%" | Add-Content $log }
            } catch {
                $sc = $_.Exception.Response.StatusCode.value__
                if ($sc -eq 401) {
                    "[${logTs}] PRIMARY TOKEN EXPIRED: trying fallback" | Add-Content $log
                    # Optional fallback token file, if you maintain one yourself
                    $tokenFile = "$env:USERPROFILE\.claude\.cls_token"
                    if (Test-Path $tokenFile) {
                        try {
                            $fallback = (Get-Content $tokenFile -Raw).Trim()
                            if ($fallback) {
                                $usage = Invoke-UsageApi $fallback
                                $rate_limits = Parse-UsageResponse $usage
                                if ($rate_limits) { "[${logTs}] FALLBACK OK: 5h=$($rate_limits.five_hour.used_percentage)% 7d=$($rate_limits.seven_day.used_percentage)%" | Add-Content $log }
                            }
                        } catch { "[${logTs}] FALLBACK ERROR: $_" | Add-Content $log }
                    }
                } elseif ($sc -eq 429) {
                    "[${logTs}] API RATE LIMITED" | Add-Content $log
                } else {
                    "[${logTs}] API ERROR ($sc): $_" | Add-Content $log
                }
            }
        } else {
            "[${logTs}] NO TOKEN in credentials" | Add-Content $log
        }
    } catch { "[${logTs}] CREDS ERROR: $_" | Add-Content $log }
}

# Build and POST payload
$payload = @{
    session_id = $session_id
    usage = @{
        input_tokens                = $ctx_used
        output_tokens               = $ctx_ot
        cache_read_input_tokens     = $ctx_cr
        cache_creation_input_tokens = $ctx_cc
        total_cost_usd              = 0
    }
    window5h = @{ input_tokens = $win5h_in; output_tokens = $win5h_out }
    window7d = @{ input_tokens = $win7d_in; output_tokens = $win7d_out }
}
if ($rate_limits) { $payload.rate_limits = $rate_limits }

$json = $payload | ConvertTo-Json -Depth 6

try {
    Invoke-RestMethod -Uri $server -Method POST -Body $json -ContentType "application/json" -TimeoutSec 10 | Out-Null
    "[${logTs}] POST OK: ctx=${ctx_used} rl=$(if($rate_limits){'yes'}else{'no'})" | Add-Content $log
} catch {
    "[${logTs}] POST ERROR: $_" | Add-Content $log
}

Write-Output "{}"
