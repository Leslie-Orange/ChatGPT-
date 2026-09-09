@echo off
setlocal
set "ROOT_DIR=%~dp0"

where pwsh.exe >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    start "" /b pwsh.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%ROOT_DIR%ChatGPTQuotaPet.ps1" %*
) else (
    start "" /b powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%ROOT_DIR%ChatGPTQuotaPet.ps1" %*
)

endlocal
