# ==============================================================================
# Script: apply-jaib-theme.ps1
# Description: Applies the JAIB (جيب) Visual Identity to Local Dify v1.18.0
# Builds the custom Web container image and activates docker-compose.override.yaml
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

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  JAIB x Dify Visual Identity Theme Application           " -ForegroundColor Cyan
Write-Host "  Time: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

Set-Location $WorkspaceDir

# 1. Verify Prerequisites
$themeCss = Join-Path $WorkspaceDir "themes\jaib\css\jaib-theme.css"
$themeAssets = Join-Path $WorkspaceDir "themes\jaib\assets"
$dockerfile = Join-Path $WorkspaceDir "themes\jaib\docker\Dockerfile.jaib-web"
$dockerDir = Join-Path $WorkspaceDir "docker\dify"
$overrideFile = Join-Path $dockerDir "docker-compose.override.yaml"
$disabledOverride = Join-Path $dockerDir "docker-compose.override.yaml.disabled"

if (-not (Test-Path $themeCss) -or -not (Test-Path $themeAssets) -or -not (Test-Path $dockerfile)) {
    throw "Required theme files missing under themes/jaib."
}

# 2. Build Custom Dify Web Image
Write-Host "`n[1/3] Building local-rag/dify-web:1.18.0-jaib..." -ForegroundColor Yellow
docker build -t local-rag/dify-web:1.18.0-jaib -f $dockerfile .
if ($LASTEXITCODE -ne 0) {
    throw "Docker build failed with exit code $LASTEXITCODE."
}
Write-Host "  [OK] Custom image built successfully." -ForegroundColor Green

# 3. Ensure docker-compose.override.yaml is active
Write-Host "`n[2/3] Configuring Docker Compose override..." -ForegroundColor Yellow
if (Test-Path $disabledOverride) {
    Move-Item -Path $disabledOverride -Destination $overrideFile -Force
}
if (-not (Test-Path $overrideFile)) {
    $overrideContent = @"
services:
  web:
    image: local-rag/dify-web:1.18.0-jaib
"@
    Set-Content -Path $overrideFile -Value $overrideContent -Encoding utf8
}
Write-Host "  [OK] docker-compose.override.yaml configured." -ForegroundColor Green

# 4. Deploy web container
Write-Host "`n[3/3] Deploying JAIB-themed web container..." -ForegroundColor Yellow
Set-Location $dockerDir
docker compose up -d --force-recreate web
if ($LASTEXITCODE -ne 0) {
    throw "docker compose up -d web failed."
}

# 5. Health Check
Write-Host "  Waiting for Web gateway readiness..." -ForegroundColor Gray
Start-Sleep -Seconds 3
$response = Invoke-WebRequest -Uri "http://127.0.0.1/logo/logo.svg" -UseBasicParsing -TimeoutSec 10
if ($response.StatusCode -ne 200) {
    throw "Web gateway health check failed with status code $($response.StatusCode)."
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  JAIB Theme Applied Successfully!                       " -ForegroundColor Green
Write-Host "  Access Dify at: http://127.0.0.1                       " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

