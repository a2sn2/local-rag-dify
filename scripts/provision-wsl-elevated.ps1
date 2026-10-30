# ==============================================================================
# Phase 1: Elevated Windows & WSL Prerequisites Setup
# Target: Windows Virtual Machine Platform + WSL Kernel Package
# Privilege: Administrator (Elevated UAC)
# Workspace: C:\Users\hassa\local-rag
# ==============================================================================
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$logPath = "C:\Users\hassa\local-rag\wsl_elevated.log"
$statusPath = "C:\Users\hassa\local-rag\wsl_status.json"

try {
    Start-Transcript -Path $logPath -Force
} catch {
    Write-Warning "Could not start transcript: $_"
}

function Write-WslStatusAndExit {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$Message,
        [hashtable]$ExtraData = @{}
    )
    $obj = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Phase     = "Phase-1-Elevated-WSL"
        Status    = $Status
        ExitCode  = $ExitCode
        Message   = $Message
    }
    foreach ($k in $ExtraData.Keys) {
        $obj[$k] = $ExtraData[$k]
    }
    [PSCustomObject]$obj | ConvertTo-Json -Depth 4 | Set-Content -Path $statusPath -Force
    try { Stop-Transcript } catch {}
    exit $ExitCode
}

try {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Phase 1: Elevated Windows Features and WSL Prerequisites " -ForegroundColor Cyan
    Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    # 1. Administrator Elevation Check
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-WslStatusAndExit -Status "FAILED_ELEVATION_REQUIRED" -ExitCode 1 -Message "Elevated administrator privileges are required for Windows feature configuration."
    }
    Write-Host "[OK] Administrator privileges confirmed." -ForegroundColor Green

    # Signal to launcher that elevated execution has physically begun
    $startedObj = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Phase     = "Phase-1-Elevated-WSL"
        Status    = "ELEVATED_PROCESS_STARTED"
        Message   = "Elevated process running with Administrator token."
    }
    [PSCustomObject]$startedObj | ConvertTo-Json | Set-Content -Path $statusPath -Force

    # 2. Check & Enable Windows Virtual Machine Platform & WSL Features
    Write-Host "`n[1/2] Checking Windows Optional Features via DISM..." -ForegroundColor Cyan

    $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue

    $vmpState = if ($vmpFeature) { $vmpFeature.State.ToString() } else { "Unknown" }
    $wslState = if ($wslFeature) { $wslFeature.State.ToString() } else { "Unknown" }

    Write-Host "VirtualMachinePlatform State: $vmpState"
    Write-Host "Microsoft-Windows-Subsystem-Linux State: $wslState"

    $rebootRequired = $false
    $exitCodeVmp = 0
    $exitCodeWsl = 0

    if ($vmpState -eq "EnablePending" -or $wslState -eq "EnablePending") {
        $rebootRequired = $true
    }

    if ($vmpState -ne "Enabled" -and $vmpState -ne "EnablePending") {
        Write-Host "Enabling VirtualMachinePlatform via DISM..." -ForegroundColor Yellow
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        $exitCodeVmp = $LASTEXITCODE
        Write-Host "DISM VirtualMachinePlatform Exit Code: $exitCodeVmp"
        if ($exitCodeVmp -eq 3010 -or $exitCodeVmp -eq 1641) {
            $rebootRequired = $true
        } elseif ($exitCodeVmp -ne 0) {
            Write-WslStatusAndExit -Status "FAILED_DISM_VMP" -ExitCode $exitCodeVmp -Message "DISM failed to enable VirtualMachinePlatform (Code: $exitCodeVmp)."
        }
    }

    if ($wslState -ne "Enabled" -and $wslState -ne "EnablePending") {
        Write-Host "Enabling Microsoft-Windows-Subsystem-Linux via DISM..." -ForegroundColor Yellow
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        $exitCodeWsl = $LASTEXITCODE
        Write-Host "DISM Microsoft-Windows-Subsystem-Linux Exit Code: $exitCodeWsl"
        if ($exitCodeWsl -eq 3010 -or $exitCodeWsl -eq 1641) {
            $rebootRequired = $true
        } elseif ($exitCodeWsl -ne 0) {
            Write-WslStatusAndExit -Status "FAILED_DISM_WSL" -ExitCode $exitCodeWsl -Message "DISM failed to enable Microsoft-Windows-Subsystem-Linux (Code: $exitCodeWsl)."
        }
    }

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $rebootRequired = $true
    }

    # CRITICAL: If reboot is required, STOP immediately!
    if ($rebootRequired) {
        Write-Host "`n[IMPORTANT] Windows Virtual Machine Platform requires a system reboot to activate Hypervisor." -ForegroundColor Yellow
        Write-WslStatusAndExit -Status "REBOOT_REQUIRED" -ExitCode 3010 -Message "System reboot is required to activate Windows Virtual Machine Platform before continuing." -ExtraData @{
            Reboot_Required        = $true
            VirtualMachinePlatform = $vmpState
            WSL_Feature            = $wslState
            DISM_VMP_ExitCode      = $exitCodeVmp
            DISM_WSL_ExitCode      = $exitCodeWsl
            Next_Action            = "REBOOT_WINDOWS_THEN_RERUN_STAGE_A"
        }
    }

    # 3. Check and Install Microsoft WSL Kernel Package
    Write-Host "`n[2/2] Checking WSL2 Package Status..." -ForegroundColor Cyan
    $wslVerTest = wsl.exe --version 2>&1 | Out-String
    $wslAlreadyInstalled = ($LASTEXITCODE -eq 0 -and $wslVerTest -match "WSL version:")

    $exitCodeWingetWsl = 0
    if ($wslAlreadyInstalled) {
        Write-Host "[OK] WSL2 package already installed and functional." -ForegroundColor Green
        Write-Host $wslVerTest.Trim()
    } else {
        # Locate winget
        $wingetExe = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
        if (-not $wingetExe -or -not (Test-Path $wingetExe)) {
            $candidatePaths = @(
                "C:\Users\hassa\AppData\Local\Microsoft\WindowsApps\winget.exe",
                "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe",
                (Get-ChildItem -Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
            )
            foreach ($c in $candidatePaths) {
                if ($c -and (Test-Path $c)) { $wingetExe = $c; break }
            }
        }

        Write-Host "Installing WSL2 package via Winget ($wingetExe)..." -ForegroundColor Cyan
        if ($wingetExe -and (Test-Path $wingetExe)) {
            & $wingetExe install --id Microsoft.WSL --accept-package-agreements --accept-source-agreements --exact --disable-interactivity
            $exitCodeWingetWsl = $LASTEXITCODE
            Write-Host "Winget WSL Exit Code: $exitCodeWingetWsl"
            if ($exitCodeWingetWsl -ne 0 -and $exitCodeWingetWsl -ne -1978335189 -and $exitCodeWingetWsl -ne -1978335212) {
                Write-WslStatusAndExit -Status "FAILED_WSL_INSTALL" -ExitCode $exitCodeWingetWsl -Message "Winget failed to install Microsoft.WSL (Exit code: $exitCodeWingetWsl)."
            }
        } else {
            Write-Host "Winget not found; attempting wsl.exe --install --no-distribution" -ForegroundColor Yellow
            wsl.exe --install --no-distribution
            $exitCodeWingetWsl = $LASTEXITCODE
            if ($exitCodeWingetWsl -ne 0) {
                Write-WslStatusAndExit -Status "FAILED_WSL_INSTALL" -ExitCode $exitCodeWingetWsl -Message "wsl.exe --install failed (Exit code: $exitCodeWingetWsl)."
            }
        }
    }

    # Verify WSL
    $finalWslVer = (wsl.exe --version 2>&1 | Out-String).Trim()
    $finalWslStat = (wsl.exe --status 2>&1 | Out-String).Trim()

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "  PHASE 1 (ELEVATED WSL SETUP) COMPLETED SUCCESSFULLY!  " -ForegroundColor Green
    Write-Host "  WSL Version: $finalWslVer" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green

    Write-WslStatusAndExit -Status "WSL_READY" -ExitCode 0 -Message "Windows features and WSL2 kernel package are installed and operational." -ExtraData @{
        Reboot_Required = $false
        WSL_Installed   = $true
        WSL_Version_Raw = $finalWslVer
        WSL_Status_Raw  = $finalWslStat
    }

} catch {
    Write-Host "[FATAL ERROR] An unexpected exception occurred in Phase 1: $_" -ForegroundColor Red
    Write-WslStatusAndExit -Status "FAILED_EXCEPTION" -ExitCode 1 -Message $_.Exception.Message -ExtraData @{
        StackTrace = $_.ScriptStackTrace
    }
}

