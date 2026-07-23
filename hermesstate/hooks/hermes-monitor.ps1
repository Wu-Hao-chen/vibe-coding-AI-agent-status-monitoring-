# Hermes State Monitor — process watcher + log monitor launcher
# EDIT ME: point this at your own deployment
$SERVER        = "https://YOUR-DOMAIN/hermesstate"
$PROCESS_NAME  = "Hermes"
$POLL_INTERVAL = 5
$HOOKS_DIR     = "$env:LOCALAPPDATA\hermes\hooks"

function Notify($endpoint) {
    try {
        Invoke-RestMethod -Uri "$SERVER/hook/$endpoint" -Method POST `
            -ContentType "application/json" -Body "{}" -TimeoutSec 8 | Out-Null
    } catch {}
}

Start-Process powershell.exe -ArgumentList `
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$HOOKS_DIR\hermes-log-monitor.ps1`"" `
    -WindowStyle Hidden

$wasRunning = $false
while ($true) {
    $proc = Get-Process -Name $PROCESS_NAME -ErrorAction SilentlyContinue
    $isRunning = ($proc -ne $null)
    if ($isRunning -and -not $wasRunning) { Notify "hermes-online"; $wasRunning = $true }
    elseif (-not $isRunning -and $wasRunning) { Notify "hermes-offline"; $wasRunning = $false }
    Start-Sleep -Seconds $POLL_INTERVAL
}
