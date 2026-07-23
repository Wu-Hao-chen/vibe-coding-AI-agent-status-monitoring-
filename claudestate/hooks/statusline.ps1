# Claude Code statusLine hook: forward rate_limits + context to ClaudeState
# EDIT ME: point this at your own deployment
$server = "https://YOUR-DOMAIN/claudestate/hook/token"

$raw = $input | Out-String

try { $data = $raw | ConvertFrom-Json } catch { Write-Output ""; exit 0 }

# Rate limits (official Anthropic data, Pro/Max only)
$rl = $data.rate_limits
$fh = if ($rl) { $rl.five_hour } else { $null }
$sd = if ($rl) { $rl.seven_day } else { $null }

# Context window
$ctx = $data.context
$ctx_used    = if ($ctx -and $ctx.used_tokens)   { [int]$ctx.used_tokens }   else { 0 }
$ctx_total   = if ($ctx -and $ctx.window_tokens) { [int]$ctx.window_tokens } else { 200000 }

# Only POST if we have something useful
$has_rl  = ($fh -and $fh.used_percentage -ne $null)
$has_ctx = ($ctx_used -gt 0)

if ($has_rl -or $has_ctx) {
    $payload = @{ session_id = $data.session_id }

    if ($has_ctx) {
        $payload.usage = @{
            input_tokens                = $ctx_used
            output_tokens               = 0
            cache_read_input_tokens     = 0
            cache_creation_input_tokens = 0
            total_cost_usd              = 0
        }
    }

    if ($has_rl) {
        $payload.rate_limits = @{
            five_hour = @{
                used_percentage = [double]$fh.used_percentage
                resets_at       = if ($fh.resets_at) { [long]$fh.resets_at } else { 0 }
            }
            seven_day = @{
                used_percentage = if ($sd) { [double]$sd.used_percentage } else { 0 }
                resets_at       = if ($sd -and $sd.resets_at) { [long]$sd.resets_at } else { 0 }
            }
        }
    }

    $json = $payload | ConvertTo-Json -Depth 6
    try {
        Invoke-RestMethod -Uri $server -Method POST -Body $json -ContentType "application/json" -TimeoutSec 5 | Out-Null
    } catch {}
}

# Build display string
$parts = @()
if ($has_rl) {
    $parts += "5h $([math]::Round($fh.used_percentage))%"
    if ($sd) { $parts += "7d $([math]::Round($sd.used_percentage))%" }
}
if ($has_ctx -and $ctx_total -gt 0) {
    $pct = [math]::Round($ctx_used / $ctx_total * 100)
    $parts += "ctx $pct%"
}

if ($parts.Count -gt 0) {
    Write-Output ($parts -join " | ")
} else {
    Write-Output ""
}
