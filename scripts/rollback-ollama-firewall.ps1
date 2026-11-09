# ==============================================================================
# Script: rollback-ollama-firewall.ps1
# Purpose: Rollback Windows Firewall rules for Ollama to original state
# Privilege: Requires Administrator Elevation
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

# 1. Administrator Check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] Administrator privileges are required to modify Windows Firewall rules." -ForegroundColor Red
    exit 1
}

$legacyTcpRuleName = "TCP Query User{DFC4CFE2-EA6D-4411-AEB4-DA6AE612295A}C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"
$legacyUdpRuleName = "UDP Query User{CC1C1831-1CA2-4A30-A8C8-1C49DBEA2D02}C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"
$newScopedRuleName = "LocalRAG_Ollama_TCP_Inbound"

try {
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  Rolling back Ollama Firewall Rules to Original State    " -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow

    # 1. Disable the new scoped rule if present
    $newRule = Get-NetFirewallRule -Name $newScopedRuleName -ErrorAction SilentlyContinue
    if ($newRule) {
        Set-NetFirewallRule -Name $newScopedRuleName -Enabled False -ErrorAction Stop
        Write-Host "[OK] Scoped rule ($newScopedRuleName) disabled." -ForegroundColor Green
    }

    # 2. Re-enable legacy TCP Rule
    $legacyTcp = Get-NetFirewallRule -Name $legacyTcpRuleName -ErrorAction SilentlyContinue
    if ($legacyTcp) {
        Set-NetFirewallRule -Name $legacyTcpRuleName -Enabled True -ErrorAction Stop
        Write-Host "[OK] Restored legacy TCP Rule: Enabled=True" -ForegroundColor Green
    }

    # 3. Re-enable legacy UDP Rule
    $legacyUdp = Get-NetFirewallRule -Name $legacyUdpRuleName -ErrorAction SilentlyContinue
    if ($legacyUdp) {
        Set-NetFirewallRule -Name $legacyUdpRuleName -Enabled True -ErrorAction Stop
        Write-Host "[OK] Restored legacy UDP Rule: Enabled=True" -ForegroundColor Green
    }

    Write-Host "`nFirewall Rollback Completed Successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n==========================================================" -ForegroundColor Red
    Write-Host "  [FATAL ERROR] Rollback Failed" -ForegroundColor Red
    Write-Host "  Message:               $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host "  Script Line / Column:  Line $($_.InvocationInfo.ScriptLineNumber), Col $($_.InvocationInfo.OffsetInLine)" -ForegroundColor Red
        Write-Host "  Position:              $($_.InvocationInfo.PositionMessage.Trim())" -ForegroundColor Red
    }
    if ($_.FullyQualifiedErrorId) {
        Write-Host "  Error ID:              $($_.FullyQualifiedErrorId)" -ForegroundColor Red
    }
    if ($_.ScriptStackTrace) {
        Write-Host "  Stack Trace:`n$($_.ScriptStackTrace)" -ForegroundColor Red
    }
    Write-Host "==========================================================" -ForegroundColor Red
    exit 1
}
