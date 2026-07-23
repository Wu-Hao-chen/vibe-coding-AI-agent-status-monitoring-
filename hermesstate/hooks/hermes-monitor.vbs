' Silent launcher for hermes-monitor.ps1 — put a shortcut to this in
' shell:startup (Win+R -> shell:startup) so it runs at logon with no window.
' IMPORTANT: save this file as plain ASCII/UTF-8 *without a BOM* — a BOM here
' makes VBScript fail with "Invalid character" at line 1, char 1.
Set WshShell = CreateObject("WScript.Shell")
scriptDir = WshShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\hermes\hooks\hermes-monitor.ps1"
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & """", 0, False
