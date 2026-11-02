@echo off
rem Stop the WorldMonitor local stack (vite / API sidecar / translate gateway /
rem Redis REST proxy / Redis). Redis data is kept in .env\redis\data.
setlocal
title WorldMonitor - stop
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-stack.ps1"
ping -n 4 127.0.0.1 >nul 2>&1
exit /b 0
