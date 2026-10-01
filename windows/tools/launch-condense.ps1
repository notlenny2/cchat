# Starts the debug build on the PC's desktop with a throwaway data folder and a DevTools port for drive.mjs.
Get-Process cchat -ErrorAction SilentlyContinue | Stop-Process -Force
$env:CCHAT_CONDENSE_AT = '5000'
$env:CCHAT_DATA_DIR = 'C:\Users\you\cchat-test\data'
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=9333'
Start-Process 'C:\Users\you\cchat-win\src-tauri\target\debug\cchat.exe' -RedirectStandardError 'C:\Users\you\cchat-test\stderr.txt'
