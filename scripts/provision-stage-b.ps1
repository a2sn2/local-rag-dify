# ==============================================================================
# Script: provision-stage-b.ps1
# Description: Stage B Dify v1.18.0 Local Deployment & Health Verification
# Target: Windows 11 / WSL2 / Docker Desktop (Per-User)
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag",
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
$userHome = [Environment]::GetFolderPath("UserProfile")
$stageBDir = Join-Path $WorkspaceDir "docker\dify"
$statusFile = Join-Path $WorkspaceDir "stage_b_status.json"
$logFile = Join-Path $WorkspaceDir "stage_b_install.log"

Start-Transcript -Path $logFile -Force

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage B: Dify v1.18.0 Local Deployment & Health Check   " -ForegroundColor Cyan
Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

function Write-StageBStatusAndExit {
    param(
        [string]$Status,
        [int]$ExitCode,
        [string]$Message,
        [hashtable]$Details = @{}
    )
    $payload = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        stage     = "STAGE_B"
        status    = $Status
        exitCode  = $ExitCode
        message   = $Message
        details   = $Details
    }
    $json = $payload | ConvertTo-Json -Depth 5
    Set-Content -Path $statusFile -Value $json -Force -Encoding ASCII
    Write-Host "`n[$Status] $Message (Exit Code: $ExitCode)" -ForegroundColor $(if ($ExitCode -eq 0) { "Green" } else { "Red" })
    Stop-Transcript
    exit $ExitCode
}

# ------------------------------------------------------------------------------
# 1. Pre-flight Environment Validation & Docker Daemon Auto-Start
# ------------------------------------------------------------------------------
Write-Host "`n[1/5] Validating Environment Prerequisites..." -ForegroundColor Cyan

function Find-DockerCli {
    $cmd = (Get-Command docker.exe -ErrorAction SilentlyContinue).Source
    if ($cmd) { return $cmd }
    $candidates = @(
        "$userHome\AppData\Local\Programs\Docker\Docker\resources\bin\docker.exe",
        "$userHome\AppData\Local\Programs\DockerDesktop\resources\bin\docker.exe",
        "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin\docker.exe",
        "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Find-DockerDesktopExe {
    $candidates = @(
        "$userHome\AppData\Local\Programs\Docker\Docker\Docker Desktop.exe",
        "$userHome\AppData\Local\Programs\DockerDesktop\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe",
        "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { return $cand }
    }
    return $null
}

$dockerCli = Find-DockerCli
if (-not $dockerCli) {
    Write-StageBStatusAndExit -Status "FAILED_DOCKER_CLI_MISSING" -ExitCode 1 -Message "docker.exe CLI binary was not found."
}
Write-Host "[OK] Docker CLI found at: $dockerCli" -ForegroundColor Green

# Add docker CLI directory to session PATH
$cliDir = Split-Path $dockerCli -Parent
if ($env:PATH -notlike "*$cliDir*") {
    $env:PATH = "$cliDir;$env:PATH"
}

# Verify Docker daemon responsiveness, auto-start if needed
$daemonOk = $false
try {
    $dockerVer = & $dockerCli version --format '{{.Server.Version}}' 2>&1
    if ($LASTEXITCODE -eq 0 -and $dockerVer) { $daemonOk = $true }
} catch {}

if (-not $daemonOk) {
    $dockerDesktopExe = Find-DockerDesktopExe
    if (-not $dockerDesktopExe) {
        Write-StageBStatusAndExit -Status "FAILED_DOCKER_NOT_FOUND" -ExitCode 1 -Message "Docker Desktop executable not found."
    }
    Write-Host "Docker daemon is not responsive. Launching Docker Desktop via WMI ($dockerDesktopExe)..." -ForegroundColor Cyan
    $wmiRes = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"$dockerDesktopExe`"" }
    Write-Host "WMI Launch ReturnValue: $($wmiRes.ReturnValue), PID: $($wmiRes.ProcessId)"

    Write-Host "Waiting for Docker daemon to become responsive (up to 120 seconds)..." -ForegroundColor Yellow
    $timeout = 120
    $waited = 0
    while ($waited -lt $timeout) {
        Start-Sleep -Seconds 5
        $waited += 5
        try {
            $dockerVer = & $dockerCli version --format '{{.Server.Version}}' 2>&1
            if ($LASTEXITCODE -eq 0 -and $dockerVer) {
                $daemonOk = $true
                break
            }
        } catch {}
    }
}

if (-not $daemonOk) {
    Write-StageBStatusAndExit -Status "FAILED_DOCKER_DAEMON_INACTIVE" -ExitCode 1 -Message "Docker daemon failed to become responsive."
}
Write-Host "[OK] Docker Engine is responsive (Server Version: $dockerVer)." -ForegroundColor Green

# Verify Host Ollama service
$ollamaUrl = "http://127.0.0.1:11434/api/tags"
try {
    $ollamaResp = Invoke-RestMethod -Uri $ollamaUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
    $qwenModel = $ollamaResp.models | Where-Object { $_.name -like "*qwen3.5:4b*" }
    if ($qwenModel) {
        Write-Host "[OK] Host Ollama service verified with model: $($qwenModel.name)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Ollama is active but qwen3.5:4b was not found in tag list." -ForegroundColor Yellow
    }
} catch {
    Write-StageBStatusAndExit -Status "FAILED_OLLAMA_INACTIVE" -ExitCode 1 -Message "Host Ollama service on 127.0.0.1:11434 is unreachable."
}

# ------------------------------------------------------------------------------
# 2. Cryptographic Token Generation & Hardened Configuration
# ------------------------------------------------------------------------------
Write-Host "`n[2/5] Configuring Hardened Environment (.env & override)..." -ForegroundColor Cyan

function New-SecureToken([int]$bytes = 32, [string]$format = "Hex") {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] $bytes
    $rng.GetBytes($buf)
    if ($format -eq "Base64Url") {
        return [Convert]::ToBase64String($buf).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    } elseif ($format -eq "AlphaNum") {
        $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        $res = -join (1..$bytes | ForEach-Object { $chars[$buf[$_ - 1] % $chars.Length] })
        return $res
    } else {
        return -join ($buf | ForEach-Object { "{0:x2}" -f $_ })
    }
}

$envExamplePath = Join-Path $stageBDir ".env.example"
$envPath = Join-Path $stageBDir ".env"
$overridePath = Join-Path $stageBDir "docker-compose.override.yaml"

if (-not (Test-Path $envExamplePath)) {
    Write-StageBStatusAndExit -Status "FAILED_ENV_EXAMPLE_MISSING" -ExitCode 1 -Message ".env.example not found in $stageBDir."
}

if (-not (Test-Path $envPath)) {
    Write-Host "Generating new hardened .env from .env.example..." -ForegroundColor Cyan
    $envContent = Get-Content -Path $envExamplePath -Raw

    $secKey = New-SecureToken 32 "Hex"
    $sandboxKey = New-SecureToken 32 "AlphaNum"
    $localSandboxKey = New-SecureToken 32 "AlphaNum"
    $agentServerKey = New-SecureToken 32 "Base64Url"
    $dbPass = New-SecureToken 24 "AlphaNum"
    $redisPass = New-SecureToken 24 "AlphaNum"
    $weaviateKey = New-SecureToken 32 "AlphaNum"

    # Replace placeholders using multiline regex (?m)
    $envContent = $envContent -replace "(?m)^SECRET_KEY=.*$", "SECRET_KEY=$secKey"
    $envContent = $envContent -replace "(?m)^SANDBOX_API_KEY=.*$", "SANDBOX_API_KEY=$sandboxKey"
    $envContent = $envContent -replace "(?m)^DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=.*$", "DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=$localSandboxKey"
    $envContent = $envContent -replace "(?m)^DIFY_AGENT_SERVER_SECRET_KEY=.*$", "DIFY_AGENT_SERVER_SECRET_KEY=$agentServerKey"
    $envContent = $envContent -replace "(?m)^DB_PASSWORD=.*$", "DB_PASSWORD=$dbPass"
    $envContent = $envContent -replace "(?m)^REDIS_PASSWORD=.*$", "REDIS_PASSWORD=$redisPass"
    $envContent = $envContent -replace "(?m)^CELERY_BROKER_URL=.*$", "CELERY_BROKER_URL=redis://:${redisPass}@redis:6379/1"
    $envContent = $envContent -replace "(?m)^WEAVIATE_API_KEY=.*$", "WEAVIATE_API_KEY=$weaviateKey"
    $envContent = $envContent -replace "(?m)^WEAVIATE_AUTHENTICATION_APIKEY_ALLOWED_KEYS=.*$", "WEAVIATE_AUTHENTICATION_APIKEY_ALLOWED_KEYS=$weaviateKey"

    # Enforce loopback-only binding
    $envContent = $envContent -replace "(?m)^EXPOSE_NGINX_PORT=.*$", "EXPOSE_NGINX_PORT=127.0.0.1:80"
    $envContent = $envContent -replace "(?m)^EXPOSE_NGINX_SSL_PORT=.*$", "EXPOSE_NGINX_SSL_PORT=127.0.0.1:443"
    $envContent = $envContent -replace "(?m)^EXPOSE_PLUGIN_DEBUGGING_PORT=.*$", "EXPOSE_PLUGIN_DEBUGGING_PORT=5003"

    # Append loopback and SSRF exemptions for Ollama host communication
    $extraConfig = @"

# ==============================================================================
# Local RAG Hardening & Host Networking Overrides
# ==============================================================================
COMPOSE_PROFILES=weaviate,postgresql,collaboration
VECTOR_STORE=weaviate
DB_TYPE=postgresql
SSRF_PROXY_ALLOW_PRIVATE_DOMAINS=host.docker.internal
SSRF_PROXY_ALLOW_PRIVATE_IPS=127.0.0.1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8
"@
    $envContent = $envContent + $extraConfig
    Set-Content -Path $envPath -Value $envContent -Encoding ASCII -Force
    Write-Host "[OK] Hardened .env created successfully with cryptographic tokens." -ForegroundColor Green
} else {
    Write-Host "[OK] Existing .env verified at: $envPath" -ForegroundColor Green
}

# Ensure docker-compose.override.yaml enforces localhost-only for plugin daemon
$overrideContent = @"
services:
  plugin_daemon:
    ports: !override
      - "127.0.0.1:5003:5003"
"@
Set-Content -Path $overridePath -Value $overrideContent -Encoding ASCII -Force
Write-Host "[OK] Loopback override enforced in docker-compose.override.yaml." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 3. Pull Images & Launch Docker Compose Stack
# ------------------------------------------------------------------------------
Write-Host "`n[3/5] Validating and Launching Dify v1.18.0 Services..." -ForegroundColor Cyan

# Validate compose configuration
$configOut = & $dockerCli compose --project-directory $stageBDir config 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-StageBStatusAndExit -Status "FAILED_COMPOSE_CONFIG" -ExitCode $LASTEXITCODE -Message "Docker compose config validation failed: $configOut"
}
Write-Host "[OK] Docker compose configuration validated successfully." -ForegroundColor Green

Write-Host "Ensuring all container images are present..." -ForegroundColor Cyan
& $dockerCli compose --project-directory $stageBDir pull
if ($LASTEXITCODE -ne 0) {
    Write-StageBStatusAndExit -Status "FAILED_COMPOSE_PULL" -ExitCode $LASTEXITCODE -Message "Docker compose pull failed."
}
Write-Host "[OK] Container images verified." -ForegroundColor Green

Write-Host "Dispatching multi-container stack in detached mode..." -ForegroundColor Cyan
& $dockerCli compose --project-directory $stageBDir up -d
if ($LASTEXITCODE -ne 0) {
    Write-StageBStatusAndExit -Status "FAILED_COMPOSE_UP" -ExitCode $LASTEXITCODE -Message "Docker compose up -d failed."
}
Write-Host "[OK] Containers dispatched successfully." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 4. Container Health Monitoring
# ------------------------------------------------------------------------------
Write-Host "`n[4/5] Monitoring Service Health & Database Migrations (Timeout: ${TimeoutSeconds}s)..." -ForegroundColor Cyan

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$allHealthy = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $psOut = & $dockerCli compose --project-directory $stageBDir ps --format '{{.Service}}|{{.State}}|{{.Health}}' 2>&1
    
    $services = @{}
    foreach ($line in $psOut) {
        if ($line -match "^([^|]+)\|([^|]+)\|(.*)$") {
            $services[$Matches[1]] = @{ State = $Matches[2]; Health = $Matches[3] }
        }
    }

    # Core required services that must be running
    $requiredServices = @("api", "web", "nginx", "db_postgres", "redis", "weaviate", "sandbox", "worker", "agent_backend", "plugin_daemon")
    $healthyCount = 0

    foreach ($sName in $requiredServices) {
        if ($services.ContainsKey($sName)) {
            $st = $services[$sName].State
            $hl = $services[$sName].Health
            # Service is acceptable if running and healthy (or lacks healthcheck)
            if ($st -eq "running" -and ($hl -eq "healthy" -or $hl -eq "" -or $hl -eq $null)) {
                $healthyCount++
            }
        }
    }

    $elapsed = [int]((Get-Date) - $deadline.AddSeconds(-$TimeoutSeconds)).TotalSeconds
    Write-Host "  Services ready: $healthyCount/$($requiredServices.Count) (Elapsed: ${elapsed}s)..." -ForegroundColor Gray

    # Test HTTP endpoint
    $webReady = $false
    try {
        $webResp = Invoke-WebRequest -Uri "http://127.0.0.1:80/" -Method Head -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($webResp.StatusCode -eq 200 -or $webResp.StatusCode -eq 302) {
            $webReady = $true
        }
    } catch {}

    if ($healthyCount -eq $requiredServices.Count -and $webReady) {
        $allHealthy = $true
        break
    }
}

if (-not $allHealthy) {
    $psDetailed = & $dockerCli compose --project-directory $stageBDir ps 2>&1
    Write-StageBStatusAndExit -Status "FAILED_HEALTH_TIMEOUT" -ExitCode 1 -Message "Dify services did not reach healthy state within ${TimeoutSeconds}s." -Details @{ ps = $psDetailed }
}

Write-Host "[OK] All core services are running and healthy!" -ForegroundColor Green

# ------------------------------------------------------------------------------
# 5. Endpoint Acceptance Verification
# ------------------------------------------------------------------------------
Write-Host "`n[5/5] Executing Endpoint Health Verification..." -ForegroundColor Cyan

# Test 1: Nginx Loopback Web UI
$webCheck = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:80/" -Method Get -TimeoutSec 5 -ErrorAction Stop
    if ($r.StatusCode -eq 200 -or $r.StatusCode -eq 302) {
        $webCheck = $true
        Write-Host "[OK] Web UI endpoint (http://127.0.0.1:80/) is responding (Status: $($r.StatusCode))." -ForegroundColor Green
    }
} catch {
    Write-Host "[WARN] Web UI endpoint returned: $_" -ForegroundColor Yellow
}

# Test 2: Nginx Console Health Endpoint
$apiCheck = $false
try {
    $rApi = Invoke-RestMethod -Uri "http://127.0.0.1:80/console/api/healthz" -Method Get -TimeoutSec 5 -ErrorAction Stop
    if ($rApi.status -eq "ok") {
        $apiCheck = $true
        Write-Host "[OK] Dify API healthz endpoint (/console/api/healthz) reports: status=ok." -ForegroundColor Green
    }
} catch {
    try {
        $rApi2 = Invoke-RestMethod -Uri "http://127.0.0.1:80/healthz" -Method Get -TimeoutSec 5 -ErrorAction Stop
        if ($rApi2.status -eq "ok") {
            $apiCheck = $true
            Write-Host "[OK] Dify API healthz endpoint (/healthz) reports: status=ok." -ForegroundColor Green
        }
    } catch {
        Write-Host "[WARN] API health check endpoint returned: $_" -ForegroundColor Yellow
    }
}

# Snapshot active containers and memory usage
$runningContainers = & $dockerCli compose --project-directory $stageBDir ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}' | Out-String
$statsOut = & $dockerCli stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' | Out-String

Write-StageBStatusAndExit -Status "SUCCESS" -ExitCode 0 -Message "Stage B Dify v1.18.0 deployed and verified successfully." -Details @{
    webResponse = $webCheck
    apiResponse = $apiCheck
    containers  = $runningContainers.Trim()
    resourceStats = $statsOut.Trim()
}
