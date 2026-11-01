# ==============================================================================
# Script: start-local-rag.ps1
# Description: Idempotent Safe Startup of Local RAG Environment (Ollama + Dify)
# Target: Windows 11 / PowerShell 5.1+
# Idempotency: Safe to run repeatedly; does NOT restart already healthy services
# Author: a2sn2
# Date: 2026-11-02
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "",
    [int]$TimeoutSeconds = 60
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
$composeFile = Join-Path $WorkspaceDir "docker\dify\docker-compose.yaml"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Starting Local RAG System (Ollama Native + Dify Stack)  " -ForegroundColor Cyan
Write-Host "  Workspace: $WorkspaceDir" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Verify Docker Engine
Write-Host "`n[1/5] Checking Docker Desktop Engine..." -ForegroundColor Yellow
$dockerPing = & docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Docker Desktop is not running. Please start Docker Desktop first." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Docker Engine is active." -ForegroundColor Green

# 2. Check / Start Ollama
Write-Host "`n[2/5] Checking Ollama Inference Engine..." -ForegroundColor Yellow
$ollamaListening = $false
try {
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 -ErrorAction Stop
    $ollamaListening = $true
} catch {}

if ($ollamaListening) {
    Write-Host "  [OK] Ollama daemon is already running on port 11434." -ForegroundColor Green
} else {
    Write-Host "  Ollama daemon is not running. Starting background process..." -ForegroundColor Gray
    $env:OLLAMA_HOST = "0.0.0.0:11434"
    $env:OLLAMA_MAX_LOADED_MODELS = "1"
    $env:OLLAMA_NUM_PARALLEL = "1"
    
    $ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollamaExe) {
        $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    }
    
    Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
    
    # Wait for readiness
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 1 -ErrorAction Stop
            $ollamaListening = $true
            break
        } catch {}
    }
    if ($ollamaListening) {
        Write-Host "  [OK] Ollama daemon started successfully." -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Ollama daemon could not be verified automatically. Check process." -ForegroundColor Yellow
    }
}

# 3. Verify Models
Write-Host "`n[3/5] Verifying Installed Local Models..." -ForegroundColor Yellow
$models = & ollama list 2>&1 | Out-String
if ($models -match "qwen3.5:4b" -and $models -match "bge-m3") {
    Write-Host "  [OK] Required models present: qwen3.5:4b, bge-m3:latest" -ForegroundColor Green
} else {
    Write-Host "  [WARN] One or more required models missing. Pulling models..." -ForegroundColor Yellow
    if ($models -notmatch "qwen3.5:4b") { & ollama pull qwen3.5:4b }
    if ($models -notmatch "bge-m3") { & ollama pull bge-m3:latest }
}

# 4. Start Dify Containers (Idempotent)
Write-Host "`n[4/5] Launching Dify Microservices (docker compose up -d)..." -ForegroundColor Yellow
if (-not (Test-Path $composeFile)) {
    Write-Host "[ERROR] docker-compose.yaml missing at: $composeFile" -ForegroundColor Red
    exit 1
}

$origEA = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$upOut = & cmd.exe /c "docker compose -f `"$composeFile`" up -d 2>&1"
$composeExit = $LASTEXITCODE
$ErrorActionPreference = $origEA

$upOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
if ($composeExit -ne 0) {
    Write-Host "[ERROR] docker compose up failed with exit code $composeExit." -ForegroundColor Red
    exit 1
}

# 5. Readiness Polling
Write-Host "`n[5/5] Polling Dify Services for HTTP Readiness..." -ForegroundColor Yellow
$difyReady = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()

while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    try {
        $webResp = Invoke-WebRequest -Uri "http://127.0.0.1" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        if ($webResp.StatusCode -eq 200) {
            $apiHealthy = docker inspect --format '{{.State.Health.Status}}' dify-api-1 2>$null
            if ($apiHealthy -eq "healthy" -or $apiHealthy -eq "") {
                $difyReady = $true
                break
            }
        }
    } catch {}
    Start-Sleep -Seconds 2
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
if ($difyReady) {
    Write-Host "  Local RAG System is ONLINE and READY!                    " -ForegroundColor Green
    Write-Host "  Web Console: http://127.0.0.1                            " -ForegroundColor Green
    Write-Host "  API Backend: http://127.0.0.1/api                        " -ForegroundColor Green
    Write-Host "  Ollama API:  http://127.0.0.1:11434                      " -ForegroundColor Green
} else {
    Write-Host "  Startup timed out after $TimeoutSeconds seconds. Review: " -ForegroundColor Yellow
    Write-Host "  docker compose -f $composeFile ps                        " -ForegroundColor Yellow
}
Write-Host "==========================================================" -ForegroundColor Cyan
