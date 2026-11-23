@echo off
rem v2 device loop -- double-click this file.  It asks Windows for
rem administrator rights (one UAC prompt) and then opens the three ports the
rem tablet needs.  Nothing else on the machine is touched.
setlocal
net session >nul 2>&1
if not %errorlevel%==0 (
    echo Asking for administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0v2_open_firewall.ps1"
echo.
pause
