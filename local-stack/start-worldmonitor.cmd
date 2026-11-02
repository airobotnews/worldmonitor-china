@echo off
rem ---------------------------------------------------------------
rem WorldMonitor local stack - one-click launcher
rem Starts: Redis + Redis REST proxy + translate gateway + API sidecar + vite
rem Then opens the dashboard in the default browser.
rem Logs: local-stack\logs\
rem ---------------------------------------------------------------
setlocal
title WorldMonitor - local stack
cd /d "%~dp0"

echo.
echo  [1/2] Starting local stack (Redis / REST proxy / translate gateway / API / UI)...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-stack.ps1"
if errorlevel 1 goto failed

echo.
echo  [2/2] Opening dashboard...
start "" "http://localhost:3000/"

echo.
echo  Ready:  http://localhost:3000/
echo  Stop:   stop-worldmonitor.cmd
rem ping ???????? stdin ????timeout ????????????????
ping -n 5 127.0.0.1 >nul 2>&1
exit /b 0

:failed
echo.
echo  [FAILED] Startup failed. Check the logs in:
echo           %~dp0logs\
echo.
pause
exit /b 1
