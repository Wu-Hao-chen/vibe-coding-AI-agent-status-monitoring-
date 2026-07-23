# Stop hook: parse transcripts, compute session + 5h + 7d tokens, POST to ClaudeState
# EDIT ME: point this at your own deployment
$server = "https://YOUR-DOMAIN/claudestate/hook/token"

$raw = $input | Out-String
try { $hook = $raw | ConvertFrom-Json } catch { Write-Output "{}"; exit 0 }

$transcript = $hook.transcript_path
$session_id = $hook.session_id

$cutoff5h = (Get-Date).ToUniversalTime().AddHours(-5)
$cutoff7d = (Get-Date).ToUniversalTime().AddDays(-7)

$ctx_cr   = 0
$ctx_cc   = 0
$ctx_it   = 0
$ctx_ot   = 0
$win5h_input  = 0
$win5h_output = 0
$win7d_input  = 0
$win7d_output = 0

if ($transcript -and (Test-Path $transcript)) {
    $project_dir = Split-Path $transcript -Parent
    $claude_dir  = Split-Path $project_dir -Parent  # .claude/projects/

    # Scan ALL project directories for 5h/7d windows
    $all_project_dirs = @($project_dir)
    if (Test-Path $claude_dir) {
        $sub = Get-ChildItem $claude_dir -Directory -ErrorAction SilentlyContinue
        foreach ($d in $sub) {
            if ($d.FullName -ne $project_dir) { $all_project_dirs += $d.FullName }
        }
    }

    # Current session: find the LAST assistant usage entry for context window
    Get-Content $transcript | ForEach-Object {
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

    # All projects: compute 5h + 7d rolling windows
    foreach ($dir in $all_project_dirs) {
        $files = Get-ChildItem $dir -Filter "*.jsonl" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            if ($file.LastWriteTimeUtc -lt $cutoff7d) { continue }
            Get-Content $file.FullName | ForEach-Object {
                try {
                    $entry = $_ | ConvertFrom-Json
                    if ($entry.type -eq "assistant" -and $entry.message -and $entry.message.usage) {
                        $u  = $entry.message.usage
                        $cc = if ($u.cache_creation_input_tokens){ [int]$u.cache_creation_input_tokens } else { 0 }
                        $ot = if ($u.output_tokens)              { [int]$u.output_tokens }              else { 0 }
                        $it = if ($u.input_tokens)               { [int]$u.input_tokens }               else { 0 }
                        $new_in = $cc + $it
                        $ts_str = $entry.timestamp
                        if ($ts_str) {
                            $ts = [datetime]::Parse($ts_str).ToUniversalTime()
                            if ($ts -ge $cutoff5h) { $win5h_input += $new_in; $win5h_output += $ot }
                            if ($ts -ge $cutoff7d) { $win7d_input += $new_in; $win7d_output += $ot }
                        }
                    }
                } catch {}
            }
        }
    }
}

$ctx_used = $ctx_cr + $ctx_cc + $ctx_it

$payload = @{
    session_id      = $session_id
    usage = @{
        input_tokens                = $ctx_used
        output_tokens               = $ctx_ot
        cache_read_input_tokens     = $ctx_cr
        cache_creation_input_tokens = $ctx_cc
        total_cost_usd              = 0
    }
    window5h = @{ input_tokens = $win5h_input;  output_tokens = $win5h_output }
    window7d = @{ input_tokens = $win7d_input;  output_tokens = $win7d_output }
} | ConvertTo-Json -Depth 4

try {
    Invoke-RestMethod -Uri $server -Method POST -Body $payload -ContentType "application/json" -TimeoutSec 10 | Out-Null
} catch {}

Write-Output "{}"
