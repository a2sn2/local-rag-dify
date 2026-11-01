# ==============================================================================
# Script: backup-local-rag.ps1
# Description: Stage E Disaster Recovery — Comprehensive Local RAG Backup Automation
# Backs up: PostgreSQL database, Weaviate schemas, Redis RDB, configs, and manifest
# Target: Windows 11 / Docker Desktop
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag",
    [string]$BackupsBaseDir = "C:\Users\hassa\local-rag\backups"
)

$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$targetBackupDir = Join-Path $BackupsBaseDir "backup_$timestamp"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage E: Local RAG Full System Backup                    " -ForegroundColor Cyan
Write-Host "  Timestamp: $timestamp                                   " -ForegroundColor Cyan
Write-Host "  Target: $targetBackupDir                                " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if (-not (Test-Path $targetBackupDir)) {
    New-Item -ItemType Directory -Path $targetBackupDir -Force | Out-Null
}

$manifest = [ordered]@{
    "timestamp" = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    "backup_id" = "backup_$timestamp"
    "git_commit" = (& git -C $WorkspaceDir rev-parse HEAD).Trim()
    "components" = [ordered]@{}
}

# 1. PostgreSQL Database Dump
Write-Host "`n[1/4] Exporting PostgreSQL Database Dump..." -ForegroundColor Yellow
$sqlFile = Join-Path $targetBackupDir "dify_database.sql"
try {
    # Execute pg_dump directly inside container, then copy out to preserve native UTF-8 without Windows redirection corruption
    docker exec dify-db_postgres-1 pg_dump -U postgres -d dify -f /tmp/backup_dify.sql
    docker cp dify-db_postgres-1:/tmp/backup_dify.sql $sqlFile
    docker exec dify-db_postgres-1 rm -f /tmp/backup_dify.sql
    if (-not (Test-Path $sqlFile) -or (Get-Item $sqlFile).Length -lt 1000) {
        throw "Database dump failed or produced empty file."
    }
    $sqlSize = (Get-Item $sqlFile).Length
    $sqlHash = (Get-FileHash -Path $sqlFile -Algorithm SHA256).Hash
    Write-Host "  [OK] Database dump successful: $sqlSize bytes (SHA-256: $($sqlHash.Substring(0, 12))...)" -ForegroundColor Green
    $manifest["components"]["postgresql"] = @{
        "file" = "dify_database.sql"
        "size_bytes" = $sqlSize
        "sha256" = $sqlHash
        "database" = "dify"
        "user" = "postgres"
    }
} catch {
    Write-Host "  [FAIL] PostgreSQL dump failed: $_" -ForegroundColor Red
    exit 1
}

# 2. Redis Cache & Broker Snapshot
Write-Host "`n[2/4] Triggering and Exporting Redis Snapshot..." -ForegroundColor Yellow
$redisFile = Join-Path $targetBackupDir "dump.rdb"
try {
    $bgsave = docker exec dify-redis-1 redis-cli bgsave
    Write-Host "  Redis BGSAVE status: $bgsave" -ForegroundColor Gray
    Start-Sleep -Seconds 2
    docker cp dify-redis-1:/data/dump.rdb $redisFile
    if (Test-Path $redisFile) {
        $redisSize = (Get-Item $redisFile).Length
        $redisHash = (Get-FileHash -Path $redisFile -Algorithm SHA256).Hash
        Write-Host "  [OK] Redis snapshot saved: $redisSize bytes (SHA-256: $($redisHash.Substring(0, 12))...)" -ForegroundColor Green
        $manifest["components"]["redis"] = @{
            "file" = "dump.rdb"
            "size_bytes" = $redisSize
            "sha256" = $redisHash
        }
    } else {
        Write-Warning "Redis dump.rdb not accessible; continuing with database backup."
    }
} catch {
    Write-Warning "Redis backup encountered warning: $_"
}

# 3. Weaviate Vector Database Schema & Metadata
Write-Host "`n[3/4] Exporting Weaviate Vector Schema & Meta..." -ForegroundColor Yellow
$weaviateFile = Join-Path $targetBackupDir "weaviate_schema.json"
try {
    $schemaJson = docker exec dify-api-1 curl -s http://weaviate:8080/v1/schema
    $schemaJson | Out-File -FilePath $weaviateFile -Encoding utf8
    $weaviateSize = (Get-Item $weaviateFile).Length
    $weaviateHash = (Get-FileHash -Path $weaviateFile -Algorithm SHA256).Hash
    Write-Host "  [OK] Weaviate schema exported: $weaviateSize bytes (SHA-256: $($weaviateHash.Substring(0, 12))...)" -ForegroundColor Green
    $manifest["components"]["weaviate"] = @{
        "file" = "weaviate_schema.json"
        "size_bytes" = $weaviateSize
        "sha256" = $weaviateHash
    }
} catch {
    Write-Host "  [FAIL] Weaviate schema export failed: $_" -ForegroundColor Red
    exit 1
}

# 4. Applications and Workflow Definitions
Write-Host "`n[4/4] Archiving Workflows and Manifest..." -ForegroundColor Yellow
try {
    $workflowsSource = Join-Path $WorkspaceDir "workflows"
    $workflowsDest = Join-Path $targetBackupDir "workflows"
    if (Test-Path $workflowsSource) {
        Copy-Item -Path $workflowsSource -Destination $workflowsDest -Recurse -Force
        $workflowFiles = Get-ChildItem -Path $workflowsDest -Filter "*.yml"
        Write-Host "  [OK] Archived $($workflowFiles.Count) workflow DSL definitions." -ForegroundColor Green
        $manifest["components"]["workflows"] = @{
            "count" = $workflowFiles.Count
            "files" = ($workflowFiles | ForEach-Object { $_.Name })
        }
    }

    # Save Manifest
    $manifestPath = Join-Path $targetBackupDir "backup_manifest.json"
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $manifestPath -Encoding utf8
    Write-Host "  [OK] Backup manifest saved: $manifestPath" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] Archiving workflows/manifest failed: $_" -ForegroundColor Red
    exit 1
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Backup Completed Successfully!                          " -ForegroundColor Green
Write-Host "  Archive Location: $targetBackupDir                      " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
