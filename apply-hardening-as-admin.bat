@echo off
title Ollama Firewall Hardening
echo ========================================================
echo   Ollama Port 11434 Windows Firewall Hardening
echo ========================================================
echo.

:: Test for Administrator rights
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges via UAC...
    powershell -Command "Start-Process cmd.exe -ArgumentList '/c', '\"%~dp0apply-hardening-as-admin.bat\"' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\harden-ollama-firewall.ps1"
set SCRIPT_EXIT=%ERRORLEVEL%

echo.
if %SCRIPT_EXIT% equ 0 (
    echo [SUCCESS] Firewall rules successfully hardened and verified.
) else (
    echo [ERROR] Hardening failed with exit code %SCRIPT_EXIT%.
)
echo.
pause
