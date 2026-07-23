# Tails agent.log and drives HermesState's yellow/green light precisely.
# EDIT ME: point this at your own deployment, and adjust $LOG_PATH / the
# turn-start / turn-end regexes if your Hermes install's log format differs.
$SERVER   = "https://YOUR-DOMAIN/hermesstate"
$LOG_PATH = "$env:LOCALAPPDATA\hermes\logs\agent.log"

function Notify($endpoint) {
    try {
        Invoke-RestMethod -Uri "$SERVER/hook/$endpoint" -Method POST `
            -ContentType "application/json" -Body "{}" -TimeoutSec 8 | Out-Null
    } catch {}
}

while (-not (Test-Path $LOG_PATH)) { Start-Sleep -Seconds 3 }

$fs = [System.IO.File]::Open($LOG_PATH,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite + [System.IO.FileShare]::Delete)
$fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
$reader = New-Object System.IO.StreamReader($fs)

while ($true) {
    $line = $reader.ReadLine()
    if ($null -ne $line) {
        if ($line -match 'agent\.turn_context: conversation turn:') { Notify "turn-start" }
        elseif ($line -match 'agent\.conversation_loop: Turn ended:') { Notify "turn-end" }
    } else { Start-Sleep -Milliseconds 200 }
}
