# ==============================================================================
# Script: check-environment.ps1
# Description: Preflight and Readiness Check for Local RAG Environment
# Target: Windows 11 / PowerShell 5.1+
# Checks: OS, WSL2, Docker Desktop, NVIDIA GPU, Ollama, Python, Dify Ports
# Author: a2sn2
# Date: 2026-11-02
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = ""
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($WorkspaceDir)) {
    if ($PSScriptRoot) {
        $WorkspaceDir = (Split-Path $PSScriptRoot -Parent)
    } else {
        $WorkspaceDir = (Get-Location).Path
    }
}
$WorkspaceDir = (Resolve-Path $WorkspaceDir).Path

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Local RAG Environment Readiness & Preflight Audit        " -ForegroundColor Cyan
Write-Host "  Workspace: $WorkspaceDir" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$allPass = $true

# 1. Operating System
Write-Host "`n[1/7] Operating System & Hardware Platform:" -ForegroundColor Yellow
$osVer = [System.Environment]::OSVersion.VersionString
$isWin11 = [System.Environment]::OSVersion.Version.Build -ge 22000
if ($isWin11) {
    Write-Host "  [PASS] Windows 11 detected: $osVer (Build $([System.Environment]::OSVersion.Version.Build))" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Operating system is not Windows 11: $osVer" -ForegroundColor Yellow
}

# 2. WSL2
Write-Host "`n[2/7] Windows Subsystem for Linux (WSL2):" -ForegroundColor Yellow
$wslStatus = & wsl --status 2>&1 | Out-String
if ($LASTEXITCODE -eq 0 -and $wslStatus -match "Default Version:\s*2") {
    Write-Host "  [PASS] WSL2 is installed and set as default version." -ForegroundColor Green
} else {
    Write-Host "  [INFO] WSL status output: $($wslStatus.Trim())" -ForegroundColor Gray
}

# 3. Docker Desktop & Compose
Write-Host "`n[3/7] Docker Desktop & Container Runtime:" -ForegroundColor Yellow
$dockerVer = & docker --version 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [PASS] Docker CLI: $dockerVer" -ForegroundColor Green
    $dockerPing = & docker info 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [PASS] Docker daemon is running and accessible." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Docker daemon is NOT responding. Start Docker Desktop." -ForegroundColor Red
        $allPass = $false
    }
} else {
    Write-Host "  [FAIL] Docker is not installed or not in PATH." -ForegroundColor Red
    $allPass = $false
}

$composeVer = & docker compose version 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [PASS] Docker Compose: $composeVer" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Docker Compose plugin is not available." -ForegroundColor Red
    $allPass = $false
}

# 4. NVIDIA GPU & CUDA
Write-Host "`n[4/7] NVIDIA GPU & CUDA Acceleration:" -ForegroundColor Yellow
$smiOut = & nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version --format=csv,noheader,nounits 2>&1
if ($LASTEXITCODE -eq 0) {
    $parts = [string]($smiOut -join "") -split ','
    if ($parts.Count -ge 4) {
        $gpuName = $parts[0].Trim()
        $vramTotal = [math]::Round([float]$parts[1].Trim() / 1024, 2)
        $vramFree = [math]::Round([float]$parts[2].Trim() / 1024, 2)
        $drv = $parts[3].Trim()
        Write-Host "  [PASS] Detected GPU: $gpuName (Driver: $drv)" -ForegroundColor Green
        Write-Host "  [PASS] Total VRAM: $vramTotal GB | Available VRAM: $vramFree GB" -ForegroundColor Green
        if ($vramTotal -lt 5.5) {
            Write-Host "  [WARN] VRAM is below recommended 6GB threshold. Model offloading may be limited." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  [WARN] nvidia-smi failed. System may lack dedicated NVIDIA GPU acceleration." -ForegroundColor Yellow
}

# 5. Ollama & Required Models
Write-Host "`n[5/7] Ollama Engine & Models:" -ForegroundColor Yellow
$ollamaVer = & ollama --version 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [PASS] Ollama CLI: $ollamaVer" -ForegroundColor Green
    
    # Check HTTP endpoint
    try {
        $ollamaResp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 3 -ErrorAction Stop
        Write-Host "  [PASS] Ollama HTTP API is responding on port 11434." -ForegroundColor Green
        
        $modelNames = $ollamaResp.models | ForEach-Object { $_.name }
        $hasQwen = $modelNames -contains "qwen3.5:4b" -or ($modelNames | Where-Object { $_ -match "^qwen3.5:4b" })
        $hasBge = $modelNames -contains "bge-m3:latest" -or ($modelNames | Where-Object { $_ -match "^bge-m3" })
        
        if ($hasQwen) {
            Write-Host "  [PASS] Chat Model installed: qwen3.5:4b" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Missing model: qwen3.5:4b (Run: ollama pull qwen3.5:4b)" -ForegroundColor Red
            $allPass = $false
        }
        
        if ($hasBge) {
            Write-Host "  [PASS] Embedding Model installed: bge-m3:latest" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Missing model: bge-m3:latest (Run: ollama pull bge-m3:latest)" -ForegroundColor Red
            $allPass = $false
        }
    } catch {
        Write-Host "  [WARN] Ollama daemon is not currently responding on http://127.0.0.1:11434." -ForegroundColor Yellow
    }
} else {
    Write-Host "  [FAIL] Ollama is not installed or not in PATH." -ForegroundColor Red
    $allPass = $false
}

# 6. Python Runtime & Cryptography
Write-Host "`n[6/7] Python Runtime & Cryptographic Module:" -ForegroundColor Yellow
$pythonExe = "C:\Users\hassa\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $pythonExe)) {
    $pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
}
if ($pythonExe) {
    $pyVer = & $pythonExe --version 2>&1
    Write-Host "  [PASS] Python: $pyVer ($pythonExe)" -ForegroundColor Green
    $hasCrypto = & cmd.exe /c "`"$pythonExe`" -c `"from cryptography.hazmat.primitives.ciphers.aead import AESGCM; print('OK')`" 2>nul"
    if ($hasCrypto -match "OK") {
        Write-Host "  [PASS] cryptography (AES-256-GCM AEAD) is available." -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Python 'cryptography' library is missing. (Run: pip install cryptography)" -ForegroundColor Red
        $allPass = $false
    }
} else {
    Write-Host "  [FAIL] Python runtime not found." -ForegroundColor Red
    $allPass = $false
}

# 7. Dify Configuration & Port Availability
Write-Host "`n[7/7] Dify Project Configuration & Ports:" -ForegroundColor Yellow
$envPath = Join-Path $WorkspaceDir "docker\dify\.env"
if (Test-Path $envPath) {
    Write-Host "  [PASS] Dify environment file present: $envPath" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Dify .env is missing. Restore from encrypted backup or copy from .env.example." -ForegroundColor Red
    $allPass = $false
}

# Port check helper
function Test-PortOpen($port) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    return ($conn -ne $null)
}

$port80Used = Test-PortOpen 80
$port5003Used = Test-PortOpen 5003
Write-Host "  * Host Port 80 (Dify Web Gateway): $(if ($port80Used) { 'Bound (Active/In Use)' } else { 'Free' })" -ForegroundColor Gray
Write-Host "  * Host Port 5003 (Dify Plugin Daemon): $(if ($port5003Used) { 'Bound (Active/In Use)' } else { 'Free' })" -ForegroundColor Gray

Write-Host "`n==========================================================" -ForegroundColor Cyan
if ($allPass) {
    Write-Host "  Environment Readiness: READY FOR LOCAL RAG EXECUTION    " -ForegroundColor Green
} else {
    Write-Host "  Environment Readiness: ATTENTION NEEDED (Review above) " -ForegroundColor Yellow
}
Write-Host "==========================================================" -ForegroundColor Cyan

