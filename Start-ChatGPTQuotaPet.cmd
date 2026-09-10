@echo off
setlocal
set "ROOT_DIR=%~dp0"

set "WSCRIPT=%SystemRoot%\System32\wscript.exe"
if not exist "%WSCRIPT%" set "WSCRIPT=wscript.exe"
"%WSCRIPT%" //nologo "%ROOT_DIR%Start-ChatGPTQuotaPet.vbs" %*

endlocal & exit /b %ERRORLEVEL%
