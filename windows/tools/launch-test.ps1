# Starts the debug build on the PC's desktop with a throwaway data folder and a DevTools port for drive.mjs.
Get-Process cchat -ErrorAction SilentlyContinue | Stop-Process -Force
$env:CCHAT_DATA_DIR = "$env:USERPROFILE\cchat-test\data"
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=9333'
Start-Process (Join-Path $PSScriptRoot '..\src-tauri\target\debug\cchat.exe') -RedirectStandardError "$env:USERPROFILE\cchat-test\stderr.txt"
