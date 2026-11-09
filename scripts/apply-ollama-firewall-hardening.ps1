# ==============================================================================
# Script: apply-ollama-firewall-hardening.ps1
# Purpose: Launcher to dispatch elevated firewall hardening via ShellExecute
# Scope: Triggers harden-ollama-firewall.ps1 with Administrator privileges
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceDir)) {
    if ($PSScriptRoot) {
        $WorkspaceDir = (Split-Path $PSScriptRoot -Parent)
    } else {
        $WorkspaceDir = (Get-Location).Path
    }
}
$WorkspaceDir = (Resolve-Path $WorkspaceDir).Path

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$targetScript = Join-Path $WorkspaceDir "scripts\harden-ollama-firewall.ps1"
$logFile = Join-Path $WorkspaceDir "config\firewall_hardening.log"

if (Test-Path $logFile) { Remove-Item $logFile -Force }

if ($isAdmin) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$targetScript" -WorkspaceDir "$WorkspaceDir"
    exit $LASTEXITCODE
} else {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Dispatching Windows Administrator UAC Elevation...      " -ForegroundColor Cyan
    Write-Host "  Target: scripts\harden-ollama-firewall.ps1              " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$targetScript`" -WorkspaceDir `"$WorkspaceDir`""
    $shell = New-Object -ComObject Shell.Application
    $shell.ShellExecute("powershell.exe", $arguments, $WorkspaceDir, "runas", 1)
    
    Write-Host "UAC prompt dispatched to the desktop. Waiting for user authorization..." -ForegroundColor Yellow
    
    $maxWait = 60
    $waited = 0
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 2
        $waited += 2
        if (Test-Path $logFile) {
            $content = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
            if ($content -match "Completed Successfully" -or $content -match "ERROR") {
                break
            }
        }
    }
    
    if (Test-Path $logFile) {
        Write-Host "`n--- Execution Log ---" -ForegroundColor Yellow
        Get-Content $logFile
    } else {
        Write-Host "`n[TIMEOUT/CANCELED] Log file was not generated within $maxWait seconds." -ForegroundColor Red
        exit 1
    }
}
