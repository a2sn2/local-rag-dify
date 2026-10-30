# ==============================================================================
# Two-Phase Orchestrator Script for Stage A Provisioning
# Phase 1: Elevated Windows Features & WSL Kernel Package (Administrator UAC)
# Phase 2: User-Context Docker Desktop Setup & Acceptance Verification (hassa)
# Workspace: C:\Users\hassa\local-rag
# ==============================================================================
$ErrorActionPreference = "Continue"
$elevatedScript = "C:\Users\hassa\local-rag\scripts\provision-wsl-elevated.ps1"
$userDockerScript = "C:\Users\hassa\local-rag\scripts\provision-docker-user.ps1"
$wslStatusPath = "C:\Users\hassa\local-rag\wsl_status.json"
$wslLogPath = "C:\Users\hassa\local-rag\wsl_elevated.log"
$stageAStatusPath = "C:\Users\hassa\local-rag\stage_a_status.json"
$workDir = "C:\Users\hassa\local-rag"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage A Orchestrator: Privilege-Separated Provisioning  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# STEP 1: Check if Phase 1 (WSL2) is already operational
# ------------------------------------------------------------------------------
Write-Host "`n[Check] Checking current WSL2 status..." -ForegroundColor Cyan
$wslTest = wsl.exe --version 2>&1 | Out-String
$wslOperational = ($LASTEXITCODE -eq 0 -and $wslTest -match "WSL version:")

if ($wslOperational) {
    Write-Host "[OK] WSL2 is already installed and operational. Skipping Phase 1 elevation." -ForegroundColor Green
    Write-Host $wslTest.Trim()
} else {
    Write-Host "[Action Required] WSL2 is not installed or enabled." -ForegroundColor Yellow
    Write-Host "Phase 1 requires Administrator privileges to configure Windows Hypervisor and WSL." -ForegroundColor Yellow

    # Reset WSL status
    Remove-Item -Path $wslStatusPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $wslLogPath -Force -ErrorAction SilentlyContinue

    $initStatus = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Phase     = "Phase-1-Elevated-WSL"
        Status    = "ELEVATION_DISPATCHED"
        Message   = "UAC elevation prompt dispatched to desktop. Awaiting user authorization."
    }
    [PSCustomObject]$initStatus | ConvertTo-Json | Set-Content -Path $wslStatusPath -Force

    Write-Host "`n[DISPATCHED] Windows UAC prompt dispatched to the active desktop." -ForegroundColor Cyan
    Write-Host "Please approve the prompt on screen to proceed." -ForegroundColor Yellow

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$elevatedScript`""
    try {
        $shell = New-Object -ComObject Shell.Application
        # Operation 'runas' prompts user with standard Windows UAC dialog
        $shell.ShellExecute("powershell.exe", $arguments, $workDir, "runas", 1)
    } catch {
        if ($_.Exception.HResult -eq -2147023673 -or $_.Exception.Message -match "canceled by the user") {
            Write-Host "`n[DENIED] UAC elevation request was declined or canceled by the user." -ForegroundColor Yellow
            $deniedObj = [ordered]@{
                Timestamp = (Get-Date).ToString("o")
                Phase     = "Phase-1-Elevated-WSL"
                Status    = "ELEVATION_DECLINED"
                ExitCode  = 1223
                Message   = "User declined the Windows UAC consent dialog."
            }
            [PSCustomObject]$deniedObj | ConvertTo-Json | Set-Content -Path $wslStatusPath -Force
            exit 1223
        } else {
            Write-Host "`n[ERROR] Failed to invoke ShellExecute: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }

    # Monitor Phase 1 progress
    Write-Host "`nMonitoring Phase 1 elevated execution..." -ForegroundColor Cyan
    $maxWait = 300
    $waited = 0
    $startedReported = $false

    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 3
        $waited += 3

        if (Test-Path $wslStatusPath) {
            try {
                $statusJson = Get-Content -Path $wslStatusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                
                if ($statusJson.Status -eq "ELEVATED_PROCESS_STARTED" -and -not $startedReported) {
                    Write-Host "[OK] UAC authorization granted by user. Elevated setup started." -ForegroundColor Green
                    $startedReported = $true
                } elseif ($statusJson.Status -eq "WSL_READY") {
                    Write-Host "`n[OK] Phase 1 Completed: Windows features and WSL2 kernel installed successfully." -ForegroundColor Green
                    break
                } elseif ($statusJson.Status -eq "REBOOT_REQUIRED") {
                    Write-Host "`n==========================================================" -ForegroundColor Yellow
                    Write-Host "  REBOOT REQUIRED BY WINDOWS                            " -ForegroundColor Yellow
                    Write-Host "  Message: $($statusJson.Message)" -ForegroundColor Yellow
                    Write-Host "==========================================================" -ForegroundColor Yellow
                    exit 3010
                } elseif ($statusJson.Status -like "FAILED_*") {
                    Write-Host "`n[ERROR] Phase 1 failed: $($statusJson.Message)" -ForegroundColor Red
                    $errCode = if ($statusJson.ExitCode) { [int]$statusJson.ExitCode } else { 1 }
                    exit $errCode
                }
            } catch {}
        }
    }
}

# ------------------------------------------------------------------------------
# STEP 2: Execute Phase 2 (User-Context Docker Setup & Acceptance Tests)
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Proceeding to Phase 2: User-Context Docker Setup       " -ForegroundColor Cyan
Write-Host "  Privilege Context: Normal User (No Elevation Required) " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $userDockerScript
$dockerExitCode = $LASTEXITCODE

if ($dockerExitCode -eq 0) {
    Write-Host "`n[OK] Stage A Provisioning and Verification Completed Successfully!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n[ERROR] Phase 2 failed with exit code: $dockerExitCode" -ForegroundColor Red
    exit $dockerExitCode
}
