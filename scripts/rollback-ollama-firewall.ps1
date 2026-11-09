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

$tcpRuleName = "TCP Query User{DFC4CFE2-EA6D-4411-AEB4-DA6AE612295A}C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"
$udpRuleName = "UDP Query User{CC1C1831-1CA2-4A30-A8C8-1C49DBEA2D02}C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"

try {
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  Rolling back Ollama Firewall Rules to Original State    " -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow

    # 1. Restore TCP Rule
    Set-NetFirewallRule -Name $tcpRuleName `
        -Profile "Public" `
        -LocalPort "Any" `
        -RemoteAddress "Any" `
        -Description "ollama.exe" `
        -ErrorAction Stop

    # 2. Restore UDP Rule
    Set-NetFirewallRule -Name $udpRuleName -Enabled True -ErrorAction Stop

    # 3. Verify Rollback
    $vTcp = Get-NetFirewallRule -Name $tcpRuleName -ErrorAction Stop
    $vPort = ($vTcp | Get-NetFirewallPortFilter).LocalPort
    $vAddr = ($vTcp | Get-NetFirewallAddressFilter).RemoteAddress
    $vUdp = Get-NetFirewallRule -Name $udpRuleName -ErrorAction Stop

    if ($vPort -ne "Any" -or $vAddr -ne "Any" -or $vUdp.Enabled.ToString() -ne "True") {
        throw "Rollback verification failed! TCP Port: $vPort, TCP Addr: $vAddr, UDP Enabled: $($vUdp.Enabled)"
    }

    Write-Host "[OK] Rollback Verified: TCP Port=Any, RemoteAddress=Any, UDP Enabled=True" -ForegroundColor Green
    Write-Host "`nFirewall Rollback Completed Successfully!" -ForegroundColor Green
} catch {
    Write-Host "`n[FATAL ERROR] Rollback failed: $_" -ForegroundColor Red
    exit 1
}
