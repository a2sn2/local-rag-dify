# ==============================================================================
# Stage A Provisioning Script - WSL2 and Docker Desktop Installer
# Project: Local RAG Platform (Dify + Ollama)
# Workspace: C:\Users\hassa\local-rag
# Target User: hassa (C:\Users\hassa)
# ==============================================================================
[CmdletBinding()]
param(
    [switch]$Force
)

$targetUser = "hassa"
$targetUserHome = "C:\Users\$targetUser"
$logPath = "C:\Users\hassa\local-rag\stage_a_install.log"
$statusPath = "C:\Users\hassa\local-rag\stage_a_status.json"

try {
    Start-Transcript -Path $logPath -Force
} catch {
    Write-Warning "Could not start transcript: $_"
}

function Write-StatusAndExit {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$Message,
        [hashtable]$ExtraData = @{}
    )
    $obj = [ordered]@{
        Timestamp    = (Get-Date).ToString("o")
        Stage        = "Stage-A"
        Status       = $Status
        ExitCode     = $ExitCode
        Message      = $Message
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
    Write-Host "  Stage A: WSL2 and Docker Desktop Automated Provisioning  " -ForegroundColor Cyan
    Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    # --------------------------------------------------------------------------
    # 1. Administrator Elevation Check
    # --------------------------------------------------------------------------
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-StatusAndExit -Status "FAILED_ELEVATION_REQUIRED" -ExitCode 1 -Message "Script executed without Administrator privileges."
    }
    Write-Host "[OK] Administrator privileges confirmed." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # 2. Backup and Apply .wslconfig
    # --------------------------------------------------------------------------
    $targetWslConfig = Join-Path $targetUserHome ".wslconfig"
    $sourceWslConfig = "C:\Users\hassa\local-rag\config\.wslconfig"

    if (Test-Path $sourceWslConfig) {
        if (Test-Path $targetWslConfig) {
            $existingContent = Get-Content -Path $targetWslConfig -Raw
            $newContent = Get-Content -Path $sourceWslConfig -Raw
            if ($existingContent -ne $newContent) {
                $backupPath = "$targetWslConfig.bak_$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
                Copy-Item -Path $targetWslConfig -Destination $backupPath -Force
                Write-Host "[OK] Pre-existing .wslconfig backed up to: $backupPath" -ForegroundColor Green
                Copy-Item -Path $sourceWslConfig -Destination $targetWslConfig -Force
                Write-Host "[OK] Updated $targetWslConfig with Local RAG resource limits." -ForegroundColor Green
            } else {
                Write-Host "[OK] $targetWslConfig already matches Local RAG configuration." -ForegroundColor Green
            }
        } else {
            Copy-Item -Path $sourceWslConfig -Destination $targetWslConfig -Force
            Write-Host "[OK] Created $targetWslConfig with Local RAG resource limits." -ForegroundColor Green
        }
    }

    # --------------------------------------------------------------------------
    # 3. Locate winget Executable
    # --------------------------------------------------------------------------
    $wingetExe = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
    if (-not $wingetExe -or -not (Test-Path $wingetExe)) {
        $candidatePaths = @(
            "$targetUserHome\AppData\Local\Microsoft\WindowsApps\winget.exe",
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe",
            (Get-ChildItem -Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
        )
        foreach ($c in $candidatePaths) {
            if ($c -and (Test-Path $c)) {
                $wingetExe = $c
                break
            }
        }
    }
    Write-Host "[OK] Winget Executable: $wingetExe" -ForegroundColor Green

    # --------------------------------------------------------------------------
    # 4. Check & Enable Windows Virtual Machine Platform & WSL Features
    # --------------------------------------------------------------------------
    Write-Host "`n[1/3] Checking Windows Optional Features via DISM..." -ForegroundColor Cyan

    $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue

    $vmpState = if ($vmpFeature) { $vmpFeature.State.ToString() } else { "Unknown" }
    $wslState = if ($wslFeature) { $wslFeature.State.ToString() } else { "Unknown" }

    Write-Host "VirtualMachinePlatform State: $vmpState"
    Write-Host "Microsoft-Windows-Subsystem-Linux State: $wslState"

    $rebootRequired = $false
    $exitCodeVmp = 0
    $exitCodeWsl = 0

    # If state is EnablePending, a reboot is already pending from earlier operation
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
            Write-StatusAndExit -Status "FAILED_DISM_VMP" -ExitCode $exitCodeVmp -Message "DISM failed to enable VirtualMachinePlatform (Code: $exitCodeVmp)."
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
            Write-StatusAndExit -Status "FAILED_DISM_WSL" -ExitCode $exitCodeWsl -Message "DISM failed to enable Microsoft-Windows-Subsystem-Linux (Code: $exitCodeWsl)."
        }
    }

    # Check Windows CBS Pending Reboot registry key
    $cbsRebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    if ($cbsRebootPending) {
        $rebootRequired = $true
    }

    # CRITICAL: If reboot is required, STOP dependent steps immediately!
    if ($rebootRequired) {
        Write-Host "`n[IMPORTANT] Windows features require a system restart to activate Hypervisor." -ForegroundColor Yellow
        Write-Host "Dependent steps (WSL kernel and Docker) cannot proceed until the hypervisor is active." -ForegroundColor Yellow
        
        Write-StatusAndExit -Status "REBOOT_REQUIRED" -ExitCode 3010 -Message "System reboot is required to activate Windows Virtual Machine Platform. Awaiting user reboot authorization." -ExtraData @{
            Reboot_Required        = $true
            VirtualMachinePlatform = $vmpState
            WSL_Feature            = $wslState
            DISM_VMP_ExitCode      = $exitCodeVmp
            DISM_WSL_ExitCode      = $exitCodeWsl
            Next_Action            = "REBOOT_WINDOWS_THEN_RERUN_STAGE_A"
        }
    }

    # --------------------------------------------------------------------------
    # 5. Check and Install Microsoft WSL Kernel Package
    # --------------------------------------------------------------------------
    Write-Host "`n[2/3] Checking Windows Subsystem for Linux (WSL2)..." -ForegroundColor Cyan
    $wslVerTest = wsl.exe --version 2>&1 | Out-String
    $wslAlreadyInstalled = ($LASTEXITCODE -eq 0 -and $wslVerTest -match "WSL version:")

    $exitCodeWingetWsl = 0
    if ($wslAlreadyInstalled) {
        Write-Host "[OK] WSL2 package already installed and functional." -ForegroundColor Green
        Write-Host $wslVerTest.Trim()
    } else {
        Write-Host "Installing WSL2 kernel package via Winget..." -ForegroundColor Cyan
        if ($wingetExe -and (Test-Path $wingetExe)) {
            & $wingetExe install --id Microsoft.WSL --accept-package-agreements --accept-source-agreements --exact --disable-interactivity
            $exitCodeWingetWsl = $LASTEXITCODE
            Write-Host "Winget WSL Exit Code: $exitCodeWingetWsl"
            # 0 = success, -1978335189 = already installed
            if ($exitCodeWingetWsl -ne 0 -and $exitCodeWingetWsl -ne -1978335189 -and $exitCodeWingetWsl -ne -1978335212) {
                Write-StatusAndExit -Status "FAILED_WSL_INSTALL" -ExitCode $exitCodeWingetWsl -Message "Winget failed to install Microsoft.WSL package (Exit code: $exitCodeWingetWsl)."
            }
        } else {
            Write-Host "Winget not found; attempting wsl.exe --install --no-distribution" -ForegroundColor Yellow
            wsl.exe --install --no-distribution
            $exitCodeWingetWsl = $LASTEXITCODE
            if ($exitCodeWingetWsl -ne 0) {
                Write-StatusAndExit -Status "FAILED_WSL_INSTALL" -ExitCode $exitCodeWingetWsl -Message "wsl.exe --install failed (Exit code: $exitCodeWingetWsl)."
            }
        }

        # Validate WSL post-install
        $wslPostCheck = wsl.exe --status 2>&1 | Out-String
        Write-Host "WSL Post-Install Status: $wslPostCheck"
    }

    # --------------------------------------------------------------------------
    # 6. Check and Install Docker Desktop (Per-User Mode)
    # --------------------------------------------------------------------------
    Write-Host "`n[3/3] Checking Docker Desktop Installation..." -ForegroundColor Cyan

    function Find-DockerDesktopExe {
        $candidates = @(
            "$targetUserHome\AppData\Local\Programs\Docker\Docker\Docker Desktop.exe",
            "$targetUserHome\AppData\Local\Programs\DockerDesktop\Docker Desktop.exe",
            "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe",
            "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe",
            "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        )
        foreach ($cand in $candidates) {
            if (Test-Path $cand) { return $cand }
        }
        return $null
    }

    $dockerDesktopExe = Find-DockerDesktopExe
    $exitCodeWingetDocker = 0

    if ($dockerDesktopExe) {
        Write-Host "[OK] Docker Desktop already installed at: $dockerDesktopExe" -ForegroundColor Green
    } else {
        Write-Host "Installing Docker Desktop in per-user mode with WSL2 backend..." -ForegroundColor Cyan
        if ($wingetExe -and (Test-Path $wingetExe)) {
            # Use per-user flags with WSL2 backend
            & $wingetExe install -e --id Docker.DockerDesktop --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity --override "install --user --quiet --backend=wsl-2 --accept-license"
            $exitCodeWingetDocker = $LASTEXITCODE
            Write-Host "Winget Docker Exit Code: $exitCodeWingetDocker"

            if ($exitCodeWingetDocker -ne 0 -and $exitCodeWingetDocker -ne -1978335189 -and $exitCodeWingetDocker -ne -1978335212) {
                Write-StatusAndExit -Status "FAILED_DOCKER_INSTALL" -ExitCode $exitCodeWingetDocker -Message "Winget failed to install Docker Desktop (Exit code: $exitCodeWingetDocker)."
            }
        } else {
            Write-StatusAndExit -Status "FAILED_DOCKER_INSTALL" -ExitCode 1 -Message "Winget executable not available for Docker Desktop installation."
        }

        $dockerDesktopExe = Find-DockerDesktopExe
        if (-not $dockerDesktopExe) {
            Write-StatusAndExit -Status "FAILED_DOCKER_NOT_FOUND" -ExitCode 1 -Message "Docker Desktop installer finished but Docker Desktop.exe was not found in expected locations."
        }
        Write-Host "[OK] Docker Desktop installed at: $dockerDesktopExe" -ForegroundColor Green
    }

    # --------------------------------------------------------------------------
    # 7. Start Docker Desktop and Verify Actual Operation
    # --------------------------------------------------------------------------
    Write-Host "`n=== Verifying Docker Engine and Container Execution ===" -ForegroundColor Cyan

    # Locate docker.exe CLI
    function Find-DockerCli {
        $cmd = (Get-Command docker.exe -ErrorAction SilentlyContinue).Source
        if ($cmd) { return $cmd }
        $candidates = @(
            "$targetUserHome\AppData\Local\Programs\Docker\Docker\resources\bin\docker.exe",
            "$targetUserHome\AppData\Local\Programs\DockerDesktop\resources\bin\docker.exe",
            "$env:LOCALAPPDATA\Programs\Docker\Docker\resources\bin\docker.exe",
            "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { return $c }
        }
        return $null
    }

    $dockerCli = Find-DockerCli
    if (-not $dockerCli) {
        Write-StatusAndExit -Status "FAILED_DOCKER_CLI_NOT_FOUND" -ExitCode 1 -Message "docker.exe CLI binary was not found after installation."
    }
    Write-Host "[OK] Docker CLI found at: $dockerCli" -ForegroundColor Green

    # Check if Docker daemon is running; if not, start Docker Desktop
    $daemonReady = $false
    try {
        $null = & $dockerCli version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) { $daemonReady = $true }
    } catch {}

    if (-not $daemonReady) {
        Write-Host "Docker daemon is not running. Starting Docker Desktop..." -ForegroundColor Cyan
        Start-Process -FilePath $dockerDesktopExe -WindowStyle Minimized
        
        Write-Host "Waiting for Docker daemon to initialize (up to 90 seconds)..." -ForegroundColor Yellow
        $timeoutSeconds = 90
        $elapsed = 0
        while ($elapsed -lt $timeoutSeconds) {
            Start-Sleep -Seconds 3
            $elapsed += 3
            try {
                $srvVer = & $dockerCli version --format '{{.Server.Version}}' 2>&1
                if ($LASTEXITCODE -eq 0 -and $srvVer) {
                    $daemonReady = $true
                    Write-Host "[OK] Docker daemon is ready (Server Version: $srvVer) after $elapsed seconds." -ForegroundColor Green
                    break
                }
            } catch {}
            Write-Host "Waiting... ($elapsed/$timeoutSeconds s)"
        }
    }

    if (-not $daemonReady) {
        Write-StatusAndExit -Status "FAILED_DOCKER_DAEMON_TIMEOUT" -ExitCode 1 -Message "Docker Desktop daemon did not become responsive within timeout." -ExtraData @{
            Docker_Desktop_Path = $dockerDesktopExe
            Docker_CLI_Path     = $dockerCli
        }
    }

    # Verify Docker Info
    Write-Host "Executing docker info..." -ForegroundColor Cyan
    $dockerInfoOut = & $dockerCli info 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-StatusAndExit -Status "FAILED_DOCKER_INFO" -ExitCode $LASTEXITCODE -Message "docker info command failed."
    }

    # Verify Docker Compose
    Write-Host "Executing docker compose version..." -ForegroundColor Cyan
    $composeVerOut = & $dockerCli compose version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-StatusAndExit -Status "FAILED_DOCKER_COMPOSE" -ExitCode $LASTEXITCODE -Message "docker compose version command failed."
    }
    Write-Host "[OK] Compose Version: $($composeVerOut.Trim())" -ForegroundColor Green

    # Run Hello-World Container
    Write-Host "Testing container execution: docker run --rm hello-world..." -ForegroundColor Cyan
    $helloWorldOut = & $dockerCli run --rm hello-world 2>&1 | Out-String
    $helloExitCode = $LASTEXITCODE
    if ($helloExitCode -ne 0 -or $helloWorldOut -notmatch "Hello from Docker!") {
        Write-StatusAndExit -Status "FAILED_HELLO_WORLD" -ExitCode $helloExitCode -Message "docker run --rm hello-world failed or returned unexpected output." -ExtraData @{
            Output = $helloWorldOut
        }
    }
    Write-Host "[OK] Container execution test (hello-world) succeeded!" -ForegroundColor Green

    # --------------------------------------------------------------------------
    # 8. Verify Existing Ollama Service Remains Operational
    # --------------------------------------------------------------------------
    Write-Host "`n=== Verifying Ollama Health ===" -ForegroundColor Cyan
    $ollamaTagCheck = curl.exe -s http://127.0.0.1:11434/api/tags
    if ($ollamaTagCheck -notmatch "qwen3.5:4b") {
        Write-StatusAndExit -Status "FAILED_OLLAMA_CHECK" -ExitCode 1 -Message "Ollama service check failed or model qwen3.5:4b is not responding."
    }
    Write-Host "[OK] Ollama service verified operational on localhost:11434 with qwen3.5:4b." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # 9. All Validations Passed: Record SUCCESS
    # --------------------------------------------------------------------------
    $wslFinalVer = (wsl.exe --version 2>&1 | Out-String).Trim()
    $dockerCliVer = (& $dockerCli --version 2>&1 | Out-String).Trim()

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "  STAGE A PROVISIONING AND VERIFICATION SUCCEEDED!      " -ForegroundColor Green
    Write-Host "  WSL: $wslFinalVer" -ForegroundColor Green
    Write-Host "  Docker: $dockerCliVer" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green

    Write-StatusAndExit -Status "SUCCESS" -ExitCode 0 -Message "WSL2 and Docker Desktop fully provisioned, running Linux containers, and verified with hello-world." -ExtraData @{
        Reboot_Required        = $false
        WSL_Installed          = $true
        WSL_Version_Raw        = $wslFinalVer
        Docker_Installed       = $true
        Docker_Desktop_Path    = $dockerDesktopExe
        Docker_CLI_Path        = $dockerCli
        Docker_CLI_Version     = $dockerCliVer
        Docker_Compose_Version = $composeVerOut.Trim()
        Hello_World_Verified   = $true
        Ollama_Verified        = $true
    }

} catch {
    Write-Host "[FATAL ERROR] An unexpected exception occurred: $_" -ForegroundColor Red
    Write-StatusAndExit -Status "FAILED_EXCEPTION" -ExitCode 1 -Message $_.Exception.Message -ExtraData @{
        StackTrace = $_.ScriptStackTrace
    }
}
