@echo off
setlocal
title Stage A - WSL2 and Docker Desktop Installer
echo ========================================================
echo Local RAG Platform - Stage A Provisioning
echo ========================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0provision-stage-a.ps1"
set EXITCODE=%ERRORLEVEL%
if %EXITCODE% EQU 3010 (
    echo.
    echo [NOTICE] Windows features enabled. A system reboot is required.
    timeout /t 5
    exit /b 3010
)
if %EXITCODE% NEQ 0 (
    echo.
    echo [ERROR] Provisioning encountered an issue (Exit code: %EXITCODE%).
    timeout /t 5
    exit /b %EXITCODE%
)
echo.
echo [SUCCESS] Stage A provisioning and validation finished.
timeout /t 3
exit /b 0
