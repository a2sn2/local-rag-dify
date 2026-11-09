@echo off
title Ollama Firewall Rollback
echo ========================================================
echo   Ollama Port 11434 Windows Firewall Rollback
echo ========================================================
echo.

:: Test for Administrator rights
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges via UAC...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c', '\"%~dp0apply-rollback-as-admin.bat\"' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\rollback-ollama-firewall.ps1"
echo.
pause

