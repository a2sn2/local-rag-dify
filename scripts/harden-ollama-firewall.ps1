# ==============================================================================
# Script: harden-ollama-firewall.ps1
# Purpose: Harden Windows Firewall rules for Ollama (Port 11434)
# Scope: Restrict inbound access strictly to the dynamic WSL2 Hyper-V subnet.
#        Excludes ::1/127.0.0.1 (rejected by WFP in RemoteAddress).
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

$logFile = Join-Path $WorkspaceDir "config\firewall_hardening.log"
Start-Transcript -Path $logFile -Force

try {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Ollama Windows Firewall Hardening                       " -ForegroundColor Cyan
    Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    # 1. Administrator Check
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Administrator privileges are required to modify Windows Firewall rules."
    }

    $tcpRuleName = "TCP Query User{DFC4CFE2-EA6D-4411-AEB4-DA6AE612295A}C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"
    $udpRuleName = "UDP Query User{CC1C1831-1CA2-4A30-A8C8-1C49DBEA2D02}C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"

    # 2. Dynamic WSL2 Subnet Discovery
    Write-Host "`n[1/4] Discovering dynamic WSL2 virtual network..." -ForegroundColor Yellow
    $wslAdapter = Get-NetIPAddress -InterfaceAlias "*WSL*" -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
    if (-not $wslAdapter) {
        throw "WSL2 virtual network adapter (vEthernet WSL) not detected! Cannot proceed safely."
    }

    $prefix = $wslAdapter.PrefixLength
    $maskBytes = @(0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) {
        $shift = [Math]::Max(0, [Math]::Min(8, $prefix - ($i * 8)))
        $maskBytes[$i] = [byte](256 - [Math]::Pow(2, 8 - $shift))
    }
    $ipBytes = ([System.Net.IPAddress]::Parse($wslAdapter.IPAddress)).GetAddressBytes()
    $netBytes = @(0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) {
        $netBytes[$i] = $ipBytes[$i] -band $maskBytes[$i]
    }
    $netAddress = ([System.Net.IPAddress]::new($netBytes)).IPAddressToString
    $wslCidr = "$netAddress/$prefix"
    Write-Host "  [OK] Detected WSL2 Interface: $($wslAdapter.InterfaceAlias)" -ForegroundColor Green
    Write-Host "  [OK] Host Interface IP: $($wslAdapter.IPAddress)" -ForegroundColor Green
    Write-Host "  [OK] Calculated Dynamic Subnet: $wslCidr" -ForegroundColor Green

    # 3. Verify and Backup Current Configuration
    Write-Host "`n[2/4] Verifying configuration backup..." -ForegroundColor Yellow
    $configDir = Join-Path $WorkspaceDir "config"
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $backupPath = Join-Path $configDir "firewall_ollama_backup.json"

    if (-not (Test-Path $backupPath)) {
        Write-Host "  Creating backup of current firewall rules..." -ForegroundColor Yellow
        $rules = Get-NetFirewallRule | Where-Object { $_.DisplayName -match "ollama" -or $_.Name -match "ollama" }
        $backupData = foreach ($r in $rules) {
            $app = $r | Get-NetFirewallApplicationFilter
            $port = $r | Get-NetFirewallPortFilter
            $addr = $r | Get-NetFirewallAddressFilter
            @{
                Name          = $r.Name
                DisplayName   = $r.DisplayName
                Direction     = [string]$r.Direction
                Action        = [string]$r.Action
                Enabled       = [string]$r.Enabled
                Profile       = [string]$r.Profile
                Program       = $app.Program
                Protocol      = $port.Protocol
                LocalPort     = $port.LocalPort
                RemotePort    = $port.RemotePort
                LocalAddress  = $addr.LocalAddress
                RemoteAddress = $addr.RemoteAddress
            }
        }
        $backupData | ConvertTo-Json -Depth 4 | Set-Content -Path $backupPath -Encoding UTF8
        Write-Host "  [OK] Backup saved to: $backupPath" -ForegroundColor Green
    } else {
        Write-Host "  [OK] Existing backup found at: $backupPath" -ForegroundColor Green
    }

    # 4. Apply Hardening to TCP Rule (Dynamic Subnet only, no invalid loopback/IPv6 in RemoteAddress)
    Write-Host "`n[3/4] Hardening Ollama TCP Rule (Port 11434 -> $wslCidr)..." -ForegroundColor Yellow
    Set-NetFirewallRule -Name $tcpRuleName `
        -Profile "Any" `
        -LocalPort 11434 `
        -RemoteAddress $wslCidr `
        -Description "Hardened: Ollama HTTP API restricted to dynamic WSL2 subnet ($wslCidr)" `
        -ErrorAction Stop

    # Explicit Verification of TCP rule
    $verifyTcp = Get-NetFirewallRule -Name $tcpRuleName -ErrorAction Stop
    $verifyPort = ($verifyTcp | Get-NetFirewallPortFilter).LocalPort
    $verifyAddr = ($verifyTcp | Get-NetFirewallAddressFilter).RemoteAddress
    if ($verifyPort -ne "11434" -or $verifyAddr -ne $wslCidr) {
        throw "Post-change verification failed for TCP rule: LocalPort='$verifyPort', RemoteAddress='$verifyAddr' (Expected: 11434 / $wslCidr)"
    }
    Write-Host "  [OK] TCP Rule Verified: LocalPort=$verifyPort, RemoteAddress=$verifyAddr, Profiles=Any" -ForegroundColor Green

    # 5. Disable unused Ollama UDP Rule with Verification
    Write-Host "`n[4/4] Disabling unused Ollama UDP Rule..." -ForegroundColor Yellow
    Set-NetFirewallRule -Name $udpRuleName -Enabled False -ErrorAction Stop
    $verifyUdp = Get-NetFirewallRule -Name $udpRuleName -ErrorAction Stop
    if ($verifyUdp.Enabled.ToString() -ne "False") {
        throw "Post-change verification failed for UDP rule: Enabled='$($verifyUdp.Enabled)' (Expected: False)"
    }
    Write-Host "  [OK] UDP Rule Verified: Enabled=False" -ForegroundColor Green

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "  Ollama Firewall Hardening Successfully Applied & Verified! " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
} catch {
    Write-Host "`n==========================================================" -ForegroundColor Red
    Write-Host "  [FATAL ERROR] Firewall Hardening Failed: $_            " -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    exit 1
} finally {
    Stop-Transcript
}
