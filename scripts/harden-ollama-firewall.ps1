# ==============================================================================
# Script: harden-ollama-firewall.ps1
# Purpose: Harden Windows Firewall rules for Ollama (Port 11434)
# Scope: Creates or updates a scoped rule (LocalRAG_Ollama_TCP_Inbound) with Block
#        EdgeTraversalPolicy, restricts RemoteAddress to dynamic WSL2 subnet
#        with CIDR/Netmask normalization, and disables legacy permissive TCP/UDP rules.
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

# --- Subnet Normalization Helper Functions ---

function Convert-PrefixToMask([int]$prefix) {
    $bytes = @(0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) {
        $shift = [Math]::Max(0, [Math]::Min(8, $prefix - ($i * 8)))
        $bytes[$i] = [byte](256 - [Math]::Pow(2, 8 - $shift))
    }
    return ([System.Net.IPAddress]::new($bytes)).IPAddressToString
}

function Convert-MaskToPrefix([string]$mask) {
    $ip = [System.Net.IPAddress]::Parse($mask)
    $bytes = $ip.GetAddressBytes()
    $prefix = 0
    foreach ($b in $bytes) {
        for ($bit = 7; $bit -ge 0; $bit--) {
            if (($b -band [byte][Math]::Pow(2, $bit)) -ne 0) {
                $prefix++
            }
        }
    }
    return $prefix
}

function Get-NormalizedSubnet([string]$inputSubnet) {
    if ([string]::IsNullOrWhiteSpace($inputSubnet)) { return $null }
    $parts = $inputSubnet.Trim() -split '/'
    $ipPart = $parts[0].Trim()
    if ($parts.Count -eq 1) {
        return @{
            Network       = $ipPart
            Prefix        = 32
            Mask          = "255.255.255.255"
            Cidr          = "$ipPart/32"
            NetmaskFormat = "$ipPart/255.255.255.255"
        }
    }
    $secondPart = $parts[1].Trim()
    $prefix = 0
    $mask = ""
    if ($secondPart -match '^\d+$') {
        $prefix = [int]$secondPart
        $mask = Convert-PrefixToMask $prefix
    } elseif ($secondPart -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        $mask = $secondPart
        $prefix = Convert-MaskToPrefix $secondPart
    } else {
        return $null
    }

    $maskIp = [System.Net.IPAddress]::Parse($mask)
    $maskBytes = $maskIp.GetAddressBytes()
    $ipBytes = ([System.Net.IPAddress]::Parse($ipPart)).GetAddressBytes()
    $netBytes = @(0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) {
        $netBytes[$i] = $ipBytes[$i] -band $maskBytes[$i]
    }
    $normNet = ([System.Net.IPAddress]::new($netBytes)).IPAddressToString

    return @{
        Network       = $normNet
        Prefix        = $prefix
        Mask          = $mask
        Cidr          = "$normNet/$prefix"
        NetmaskFormat = "$normNet/$mask"
    }
}

function Test-SubnetEquivalence([string]$subnet1, [string]$subnet2) {
    $norm1 = Get-NormalizedSubnet $subnet1
    $norm2 = Get-NormalizedSubnet $subnet2
    if (-not $norm1 -or -not $norm2) { return $false }
    return ($norm1.Cidr -eq $norm2.Cidr)
}

try {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Ollama Windows Firewall Hardening                       " -ForegroundColor Cyan
    Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    # 1. Administrator Check
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Administrator privileges are required to modify Windows Firewall rules. Please run via apply-hardening-as-admin.bat."
    }

    $legacyTcpRuleName = "TCP Query User{DFC4CFE2-EA6D-4411-AEB4-DA6AE612295A}C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"
    $legacyUdpRuleName = "UDP Query User{CC1C1831-1CA2-4A30-A8C8-1C49DBEA2D02}C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"
    $newScopedRuleName = "LocalRAG_Ollama_TCP_Inbound"
    $ollamaProgramPath = "C:\users\alhassanalshami\appdata\local\programs\ollama\ollama.exe"

    if (-not (Test-Path $ollamaProgramPath)) {
        $ollamaCmd = Get-Command ollama.exe -ErrorAction SilentlyContinue
        if ($ollamaCmd) { $ollamaProgramPath = $ollamaCmd.Source }
    }

    # 2. Dynamic WSL2 Subnet Discovery
    Write-Host "`n[1/5] Discovering dynamic WSL2 virtual network..." -ForegroundColor Yellow
    $wslAdapter = Get-NetIPAddress -InterfaceAlias "*WSL*" -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
    if (-not $wslAdapter) {
        throw "WSL2 virtual network adapter (vEthernet WSL) not detected! Cannot proceed safely."
    }

    $prefix = $wslAdapter.PrefixLength
    $maskStr = Convert-PrefixToMask $prefix
    $ipBytes = ([System.Net.IPAddress]::Parse($wslAdapter.IPAddress)).GetAddressBytes()
    $maskBytes = ([System.Net.IPAddress]::Parse($maskStr)).GetAddressBytes()
    $netBytes = @(0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) {
        $netBytes[$i] = $ipBytes[$i] -band $maskBytes[$i]
    }
    $netAddress = ([System.Net.IPAddress]::new($netBytes)).IPAddressToString
    $wslCidr = "$netAddress/$prefix"
    $wslDotted = "$netAddress/$maskStr"

    Write-Host "  [OK] Detected WSL2 Interface: $($wslAdapter.InterfaceAlias)" -ForegroundColor Green
    Write-Host "  [OK] Host Interface IP: $($wslAdapter.IPAddress)" -ForegroundColor Green
    Write-Host "  [OK] Dynamic WSL2 Subnet (CIDR):   $wslCidr" -ForegroundColor Green
    Write-Host "  [OK] Dynamic WSL2 Subnet (Netmask): $wslDotted" -ForegroundColor Green

    # 3. Verify and Backup Current Configuration
    Write-Host "`n[2/5] Verifying configuration backup..." -ForegroundColor Yellow
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
                Name                = $r.Name
                DisplayName         = $r.DisplayName
                Direction           = [string]$r.Direction
                Action              = [string]$r.Action
                Enabled             = [string]$r.Enabled
                Profile             = [string]$r.Profile
                EdgeTraversalPolicy = [string]$r.EdgeTraversalPolicy
                Program             = $app.Program
                Protocol            = $port.Protocol
                LocalPort           = $port.LocalPort
                RemotePort          = $port.RemotePort
                LocalAddress        = $addr.LocalAddress
                RemoteAddress       = $addr.RemoteAddress
            }
        }
        $backupData | ConvertTo-Json -Depth 4 | Set-Content -Path $backupPath -Encoding UTF8
        Write-Host "  [OK] Backup saved to: $backupPath" -ForegroundColor Green
    } else {
        Write-Host "  [OK] Existing backup found at: $backupPath" -ForegroundColor Green
    }

    # 4. Create or Update the New Scoped Inbound Rule
    Write-Host "`n[3/5] Configuring Scoped Inbound TCP Rule ($newScopedRuleName)..." -ForegroundColor Yellow
    $existingNew = Get-NetFirewallRule -Name $newScopedRuleName -ErrorAction SilentlyContinue

    if (-not $existingNew) {
        New-NetFirewallRule -Name $newScopedRuleName `
            -DisplayName "Local RAG - Ollama Inbound (WSL2 Only)" `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort 11434 `
            -Program $ollamaProgramPath `
            -RemoteAddress $wslCidr `
            -Profile Any `
            -EdgeTraversalPolicy Block `
            -Description "Hardened: Ollama HTTP API restricted to port 11434 from dynamic WSL2 subnet" `
            -Enabled True `
            -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Created new scoped rule: $newScopedRuleName" -ForegroundColor Green
    } else {
        Set-NetFirewallRule -Name $newScopedRuleName `
            -NewDisplayName "Local RAG - Ollama Inbound (WSL2 Only)" `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort 11434 `
            -Program $ollamaProgramPath `
            -RemoteAddress $wslCidr `
            -Profile Any `
            -EdgeTraversalPolicy Block `
            -Description "Hardened: Ollama HTTP API restricted to port 11434 from dynamic WSL2 subnet" `
            -Enabled True `
            -ErrorAction Stop
        Write-Host "  [OK] Updated existing scoped rule: $newScopedRuleName" -ForegroundColor Green
    }

    # Verify Scoped Rule with CIDR/Netmask Equivalence Normalization
    $vNew = Get-NetFirewallRule -Name $newScopedRuleName -ErrorAction Stop
    $vPortFilter = $vNew | Get-NetFirewallPortFilter
    $vAddrFilter = $vNew | Get-NetFirewallAddressFilter
    $vAppFilter  = $vNew | Get-NetFirewallApplicationFilter

    $vPort     = $vPortFilter.LocalPort
    $vProtocol = $vPortFilter.Protocol
    $vAddr     = ($vAddrFilter.RemoteAddress -join ', ')
    $vProg     = $vAppFilter.Program
    $vAction   = $vNew.Action.ToString()
    $vEnabled  = $vNew.Enabled.ToString()
    $vEdge     = $vNew.EdgeTraversalPolicy.ToString()

    $isPortMatch   = ($vPort -eq "11434")
    $isSubnetMatch = (Test-SubnetEquivalence $vAddr $wslCidr)
    $isEnabled     = ($vEnabled -eq "True")
    $isActionAllow = ($vAction -eq "Allow")
    $isEdgeBlock   = ($vEdge -eq "Block")
    $isTcp         = ($vProtocol -eq "TCP")
    $isProgValid   = ($vProg -like "*ollama.exe*")

    if (-not ($isPortMatch -and $isSubnetMatch -and $isEnabled -and $isActionAllow -and $isEdgeBlock -and $isTcp -and $isProgValid)) {
        throw "Verification check failed for new rule: Port=$vPort (Match: $isPortMatch), Protocol=$vProtocol (TCP: $isTcp), Addr=$vAddr (Equiv to $($wslCidr): $isSubnetMatch), Enabled=$vEnabled, Action=$vAction, EdgeTraversal=$vEdge, Program=$vProg"
    }
    Write-Host "  [OK] Scoped Rule Verified: Port=$vPort, Protocol=$vProtocol, RemoteAddress=$vAddr (Normalized: $wslCidr), Enabled=$vEnabled, Action=$vAction, EdgeTraversal=$vEdge" -ForegroundColor Green

    # 5. Disable Legacy Permissive TCP Rule
    Write-Host "`n[4/5] Disabling legacy permissive TCP rule..." -ForegroundColor Yellow
    $legacyTcp = Get-NetFirewallRule -Name $legacyTcpRuleName -ErrorAction SilentlyContinue
    if ($legacyTcp) {
        Set-NetFirewallRule -Name $legacyTcpRuleName -Enabled False -ErrorAction Stop
        $vLegacy = Get-NetFirewallRule -Name $legacyTcpRuleName -ErrorAction Stop
        if ($vLegacy.Enabled.ToString() -ne "False") {
            throw "Verification check failed: Legacy TCP rule could not be disabled!"
        }
        Write-Host "  [OK] Legacy permissive TCP rule ($legacyTcpRuleName) disabled." -ForegroundColor Green
    } else {
        Write-Host "  [INFO] Legacy TCP rule name not found directly; searching for unhardened ollama inbound TCP rules..." -ForegroundColor Gray
    }

    # Ensure no other permissive inbound TCP rules exist for Ollama
    $otherInboundRules = Get-NetFirewallRule | Where-Object {
        $_.Name -ne $newScopedRuleName -and
        ($_.DisplayName -eq "ollama.exe" -or $_.Name -match "ollama") -and
        ($_.Direction -eq "Inbound")
    }
    foreach ($r in $otherInboundRules) {
        $pf = $r | Get-NetFirewallPortFilter
        if ($pf.Protocol -eq "TCP" -and $r.Enabled.ToString() -eq "True") {
            Write-Host "  Disabling unhardened inbound TCP rule: $($r.Name)..." -ForegroundColor Yellow
            Set-NetFirewallRule -Name $r.Name -Enabled False -ErrorAction Stop
        }
    }

    # 6. Disable Legacy UDP Rule
    Write-Host "`n[5/5] Ensuring legacy UDP rule remains disabled..." -ForegroundColor Yellow
    $legacyUdp = Get-NetFirewallRule -Name $legacyUdpRuleName -ErrorAction SilentlyContinue
    if ($legacyUdp) {
        Set-NetFirewallRule -Name $legacyUdpRuleName -Enabled False -ErrorAction Stop
        $vUdp = Get-NetFirewallRule -Name $legacyUdpRuleName -ErrorAction Stop
        if ($vUdp.Enabled.ToString() -ne "False") {
            throw "Verification check failed: Legacy UDP rule could not be disabled!"
        }
        Write-Host "  [OK] Legacy UDP rule ($legacyUdpRuleName) disabled." -ForegroundColor Green
    }

    # Final Inventory Verification
    Write-Host "`n--- Final Effective Ollama Firewall Rules ---" -ForegroundColor Cyan
    $finalRules = Get-NetFirewallRule | Where-Object { $_.DisplayName -match "ollama" -or $_.Name -match "ollama" }
    foreach ($fr in $finalRules) {
        $pf = $fr | Get-NetFirewallPortFilter
        $af = $fr | Get-NetFirewallAddressFilter
        Write-Host ("  Rule: {0} | Enabled: {1} | Action: {2} | Dir: {3} | Proto: {4} | Port: {5} | Addr: {6}" -f `
            $fr.Name, $fr.Enabled, $fr.Action, $fr.Direction, $pf.Protocol, $pf.LocalPort, ($af.RemoteAddress -join ',')) -ForegroundColor Gray
    }

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "  Ollama Firewall Hardening Successfully Applied & Verified! " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    exit 0
} catch {
    Write-Host "`n==========================================================" -ForegroundColor Red
    Write-Host "  [FATAL ERROR] Firewall Hardening Failed" -ForegroundColor Red
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
} finally {
    Stop-Transcript
}
