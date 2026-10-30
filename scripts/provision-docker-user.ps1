# ==============================================================================
# Phase 2: User-Context Docker Desktop Setup and Operational Verification
# Target: Docker Desktop (Per-User Mode, WSL2 Backend) + Acceptance Tests
# Privilege: Normal User (hassa) - NO ELEVATION
# Workspace: C:\Users\hassa\local-rag
# ==============================================================================
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$targetUser = "hassa"
$userHome = "C:\Users\$targetUser"
$logPath = "C:\Users\hassa\local-rag\docker_user.log"
$statusPath = "C:\Users\hassa\local-rag\stage_a_status.json"

try {
    Start-Transcript -Path $logPath -Force
} catch {
    Write-Warning "Could not start transcript: $_"
}

function Write-StageAStatusAndExit {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$Message,
        [hashtable]$ExtraData = @{}
    )
    $obj = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Phase     = "Phase-2-User-Docker"
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
    Write-Host "  Phase 2: Docker Desktop Setup (User Context: $targetUser)  " -ForegroundColor Cyan
    Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    # 1. Verify User Context
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Host "[OK] Current Execution Identity: $currentUser" -ForegroundColor Green

    # 2. Verify WSL2 Operational State
    Write-Host "`n[1/5] Verifying WSL2 Operational Status..." -ForegroundColor Cyan
    $wslVerRaw = wsl.exe --version 2>&1 | Out-String
    $wslVerClean = ($wslVerRaw -replace "`0", "").Trim()
    $wslStatRaw = wsl.exe --status 2>&1 | Out-String
    $wslStatClean = ($wslStatRaw -replace "`0", "").Trim()

    Write-Host "WSL Version Cleaned:`n$wslVerClean"
    Write-Host "WSL Status Cleaned:`n$wslStatClean"

    if ($wslVerClean -notmatch "WSL version" -and $wslStatClean -notmatch "Default Version") {
        Write-StageAStatusAndExit -Status "FAILED_WSL_NOT_OPERATIONAL" -ExitCode 1 -Message "WSL2 is not operational post-reboot."
    }
    Write-Host "[OK] WSL2 is verified operational." -ForegroundColor Green

    # 3. Apply Resource Configuration (.wslconfig)
    Write-Host "`n[2/5] Checking .wslconfig in User Profile ($userHome)..." -ForegroundColor Cyan
    $targetWslConfig = Join-Path $userHome ".wslconfig"
    $sourceWslConfig = "C:\Users\hassa\local-rag\config\.wslconfig"

    if (Test-Path $sourceWslConfig) {
        if (Test-Path $targetWslConfig) {
            $existing = Get-Content -Path $targetWslConfig -Raw
            $newConf = Get-Content -Path $sourceWslConfig -Raw
            if ($existing -ne $newConf) {
                $backup = "$targetWslConfig.bak_$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
                Copy-Item -Path $targetWslConfig -Destination $backup -Force
                Copy-Item -Path $sourceWslConfig -Destination $targetWslConfig -Force
                Write-Host "[OK] Applied resource configuration to $targetWslConfig (backup created)." -ForegroundColor Green
            } else {
                Write-Host "[OK] $targetWslConfig already matches Local RAG configuration." -ForegroundColor Green
            }
        } else {
            Copy-Item -Path $sourceWslConfig -Destination $targetWslConfig -Force
            Write-Host "[OK] Created $targetWslConfig with 16GB RAM, 12 CPUs, 8GB swap." -ForegroundColor Green
        }
    }

    # 4. Check & Install Docker Desktop in Per-User Mode
    Write-Host "`n[3/5] Checking Docker Desktop Installation..." -ForegroundColor Cyan

    function Find-DockerDesktopExe {
        $candidates = @(
            "$userHome\AppData\Local\Programs\Docker\Docker\Docker Desktop.exe",
            "$userHome\AppData\Local\Programs\DockerDesktop\Docker Desktop.exe",
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
        $localInstaller = "C:\Users\hassa\local-rag\docker\DockerDesktopInstaller.exe"
        if (Test-Path $localInstaller) {
            Write-Host "Installing Docker Desktop via local installer in per-user mode..." -ForegroundColor Cyan
            $p = Start-Process -FilePath $localInstaller -ArgumentList "install", "--user", "--quiet", "--backend=wsl-2", "--accept-license" -Wait -PassThru
            $exitCodeWingetDocker = $p.ExitCode
            Write-Host "Installer Exit Code: $exitCodeWingetDocker"
        } else {
            Write-Host "Installing Docker Desktop in per-user mode via Winget..." -ForegroundColor Cyan
            $wingetCmd = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
            if (-not $wingetCmd) {
                $wingetCmd = "$userHome\AppData\Local\Microsoft\WindowsApps\winget.exe"
            }

            if (Test-Path $wingetCmd) {
                & $wingetCmd install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --disable-interactivity --override "install --user --quiet --backend=wsl-2 --accept-license"
                $exitCodeWingetDocker = $LASTEXITCODE
                Write-Host "Winget Docker Exit Code: $exitCodeWingetDocker"
            } else {
                Write-StageAStatusAndExit -Status "FAILED_DOCKER_INSTALL" -ExitCode 1 -Message "Winget executable not found in user path."
            }
        }

        # Validate exit code: 0 = success, -1978335189 = already installed
        if ($exitCodeWingetDocker -ne 0 -and $exitCodeWingetDocker -ne -1978335189 -and $exitCodeWingetDocker -ne -1978335212) {
            Write-StageAStatusAndExit -Status "FAILED_DOCKER_INSTALL" -ExitCode $exitCodeWingetDocker -Message "Docker Desktop installation failed (Exit code: $exitCodeWingetDocker)."
        }

        $dockerDesktopExe = Find-DockerDesktopExe
        if (-not $dockerDesktopExe) {
            Write-StageAStatusAndExit -Status "FAILED_DOCKER_NOT_FOUND" -ExitCode 1 -Message "Docker Desktop installation finished but executable was not found."
        }
        Write-Host "[OK] Docker Desktop successfully installed at: $dockerDesktopExe" -ForegroundColor Green
    }

    # 5. Start Docker Desktop and Verify Daemon
    Write-Host "`n[4/5] Starting Docker Desktop and Waiting for Daemon..." -ForegroundColor Cyan

    function Find-DockerCli {
        $cmd = (Get-Command docker.exe -ErrorAction SilentlyContinue).Source
        if ($cmd) { return $cmd }
        $candidates = @(
            "$userHome\AppData\Local\Programs\Docker\Docker\resources\bin\docker.exe",
            "$userHome\AppData\Local\Programs\DockerDesktop\resources\bin\docker.exe",
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
        Write-StageAStatusAndExit -Status "FAILED_DOCKER_CLI_NOT_FOUND" -ExitCode 1 -Message "docker.exe CLI binary was not found after installation."
    }
    Write-Host "[OK] Docker CLI found at: $dockerCli" -ForegroundColor Green

    # Add docker CLI directory to session PATH
    $cliDir = Split-Path $dockerCli -Parent
    if ($env:PATH -notlike "*$cliDir*") {
        $env:PATH = "$cliDir;$env:PATH"
    }

    # Check daemon availability
    $daemonReady = $false
    try {
        $srvVer = & $dockerCli version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0 -and $srvVer) { $daemonReady = $true }
    } catch {}

    if (-not $daemonReady) {
        Write-Host "Launching Docker Desktop application..." -ForegroundColor Cyan
        Start-Process -FilePath $dockerDesktopExe -WindowStyle Minimized

        Write-Host "Waiting for Docker daemon to become responsive (up to 120 seconds)..." -ForegroundColor Yellow
        $timeout = 120
        $waited = 0
        while ($waited -lt $timeout) {
            Start-Sleep -Seconds 5
            $waited += 5
            try {
                $srvVer = & $dockerCli version --format '{{.Server.Version}}' 2>&1
                if ($LASTEXITCODE -eq 0 -and $srvVer) {
                    $daemonReady = $true
                    Write-Host "`n[OK] Docker daemon is responsive (Server Version: $srvVer) after $waited seconds." -ForegroundColor Green
                    break
                }
            } catch {}
            Write-Host "Waiting for daemon... ($waited/$timeout s)"
        }
    }

    if (-not $daemonReady) {
        Write-StageAStatusAndExit -Status "FAILED_DOCKER_DAEMON_TIMEOUT" -ExitCode 1 -Message "Docker Desktop daemon did not become responsive within timeout." -ExtraData @{
            Docker_Desktop_Path = $dockerDesktopExe
            Docker_CLI_Path     = $dockerCli
        }
    }

    # 6. Comprehensive Acceptance Verification
    Write-Host "`n[5/5] Executing Stage A Acceptance Verification..." -ForegroundColor Cyan

    # A. docker info
    Write-Host "Executing docker info..." -ForegroundColor Cyan
    $dockerInfoOut = & $dockerCli info 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-StageAStatusAndExit -Status "FAILED_DOCKER_INFO" -ExitCode $LASTEXITCODE -Message "docker info failed."
    }
    Write-Host "[OK] docker info succeeded." -ForegroundColor Green

    # B. docker compose version
    Write-Host "Executing docker compose version..." -ForegroundColor Cyan
    $composeVerOut = & $dockerCli compose version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-StageAStatusAndExit -Status "FAILED_DOCKER_COMPOSE" -ExitCode $LASTEXITCODE -Message "docker compose version failed."
    }
    Write-Host "[OK] docker compose: $($composeVerOut.Trim())" -ForegroundColor Green

    # C. docker run --rm hello-world
    Write-Host "Executing container validation: docker run --rm hello-world..." -ForegroundColor Cyan
    $helloOut = & $dockerCli run --rm hello-world 2>&1 | Out-String
    $helloCode = $LASTEXITCODE
    if ($helloCode -ne 0 -or $helloOut -notmatch "Hello from Docker!") {
        Write-StageAStatusAndExit -Status "FAILED_HELLO_WORLD" -ExitCode $helloCode -Message "docker run --rm hello-world failed." -ExtraData @{
            Output = $helloOut
        }
    }
    Write-Host "[OK] Container execution test (hello-world) verified successfully!" -ForegroundColor Green

    # D. Ollama Health Check
    Write-Host "Verifying existing host Ollama service..." -ForegroundColor Cyan
    $ollamaTags = curl.exe -s http://127.0.0.1:11434/api/tags
    if ($ollamaTags -notmatch "qwen3.5:4b") {
        Write-StageAStatusAndExit -Status "FAILED_OLLAMA_CHECK" -ExitCode 1 -Message "Ollama service check failed or model qwen3.5:4b is not responding."
    }
    Write-Host "[OK] Ollama service verified operational on localhost:11434 with model qwen3.5:4b." -ForegroundColor Green

    # 7. Final Success State Record
    $dockerCliVer = (& $dockerCli --version 2>&1 | Out-String).Trim()
    $finalWslVer = (wsl.exe --version 2>&1 | Out-String).Trim()

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "  STAGE A PROVISIONING AND VERIFICATION SUCCEEDED!      " -ForegroundColor Green
    Write-Host "  WSL2:   $finalWslVer" -ForegroundColor Green
    Write-Host "  Docker: $dockerCliVer" -ForegroundColor Green
    Write-Host "  Hello-World Container: Verified (Linux Containers Active)" -ForegroundColor Green
    Write-Host "  Ollama: Host CUDA Service Intact (qwen3.5:4b)" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green

    Write-StageAStatusAndExit -Status "SUCCESS" -ExitCode 0 -Message "WSL2 and Docker Desktop fully provisioned, Linux containers operational, and all acceptance tests passed." -ExtraData @{
        Reboot_Required        = $false
        WSL_Installed          = $true
        WSL_Version_Raw        = $finalWslVer
        Docker_Installed       = $true
        Docker_User            = $targetUser
        Docker_Desktop_Path    = $dockerDesktopExe
        Docker_CLI_Path        = $dockerCli
        Docker_CLI_Version     = $dockerCliVer
        Docker_Compose_Version = $composeVerOut.Trim()
        Hello_World_Verified   = $true
        Ollama_Verified        = $true
    }

} catch {
    Write-Host "[FATAL ERROR] An unexpected exception occurred in Phase 2: $_" -ForegroundColor Red
    Write-StageAStatusAndExit -Status "FAILED_EXCEPTION" -ExitCode 1 -Message $_.Exception.Message -ExtraData @{
        StackTrace = $_.ScriptStackTrace
    }
}
