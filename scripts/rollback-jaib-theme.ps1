# ==============================================================================
# Script: rollback-jaib-theme.ps1
# Description: Rolls back Dify Web to the official upstream image (langgenius/dify-web:1.18.0)
# Disables docker-compose.override.yaml and cleanly restarts the web service.
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Yellow
Write-Host "  JAIB Theme Rollback - Revert to Upstream Dify Web       " -ForegroundColor Yellow
Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Yellow

$dockerDir = Join-Path $WorkspaceDir "docker\dify"
$overrideFile = Join-Path $dockerDir "docker-compose.override.yaml"
$disabledOverride = Join-Path $dockerDir "docker-compose.override.yaml.disabled"

Set-Location $dockerDir

# 1. Disable override file
Write-Host "`n[1/2] Disabling docker-compose.override.yaml..." -ForegroundColor Yellow
if (Test-Path $overrideFile) {
    Move-Item -Path $overrideFile -Destination $disabledOverride -Force
    Write-Host "  [OK] docker-compose.override.yaml renamed to docker-compose.override.yaml.disabled." -ForegroundColor Green
} else {
    Write-Host "  [INFO] No active docker-compose.override.yaml found." -ForegroundColor Gray
}

# 2. Restart web service with original image
Write-Host "`n[2/2] Recreating web container with langgenius/dify-web:1.18.0..." -ForegroundColor Yellow
docker compose up -d web
if ($LASTEXITCODE -ne 0) {
    throw "docker compose up -d web failed during rollback."
}

# 3. Verify Rollback
Write-Host "  Waiting for Web gateway readiness..." -ForegroundColor Gray
Start-Sleep -Seconds 3
$response = Invoke-WebRequest -Uri "http://127.0.0.1/logo/logo.svg" -UseBasicParsing -TimeoutSec 10
if ($response.StatusCode -ne 200) {
    throw "Web gateway health check failed during rollback."
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  Rollback Completed Successfully!                       " -ForegroundColor Green
Write-Host "  Reverted to official image: langgenius/dify-web:1.18.0   " -ForegroundColor Green
Write-Host "  Access Dify at: http://127.0.0.1                       " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
