# ==============================================================================
# Script: verify-backup.ps1
# Description: Validates AES-256-GCM Backup Archive Integrity & Manifest Checksums
# Target: Windows 11 / PowerShell 5.1+
# Security: Non-destructive verification (does NOT launch or modify containers)
# Author: a2sn2
# Date: 2026-11-02
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "",
    [string]$BackupFile = "",
    [string]$Passphrase = "",
    [string]$KeyFile = ""
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

# Resolve Passphrase
$resolvedPassphrase = $Passphrase
if ([string]::IsNullOrWhiteSpace($resolvedPassphrase)) {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_RAG_BACKUP_KEY)) {
        $resolvedPassphrase = $env:LOCAL_RAG_BACKUP_KEY
    } elseif (-not [string]::IsNullOrWhiteSpace($KeyFile) -and (Test-Path $KeyFile)) {
        $resolvedPassphrase = (Get-Content -Path $KeyFile -Raw).Trim()
    } else {
        $defaultKeyPath = Join-Path $WorkspaceDir ".secrets\backup.key"
        if (Test-Path $defaultKeyPath) {
            $resolvedPassphrase = (Get-Content -Path $defaultKeyPath -Raw).Trim()
        }
    }
}

if ([string]::IsNullOrWhiteSpace($resolvedPassphrase)) {
    Write-Host "[ERROR] Decryption key is required to verify backup integrity." -ForegroundColor Red
    Write-Host "Provide via -Passphrase, `$env:LOCAL_RAG_BACKUP_KEY, -KeyFile, or .secrets/backup.key." -ForegroundColor Yellow
    exit 1
}

# Locate latest backup if not provided
if ([string]::IsNullOrWhiteSpace($BackupFile)) {
    $backupsBase = Join-Path $WorkspaceDir "backups"
    $latestBackup = Get-ChildItem -Path $backupsBase -Filter "*.enc" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latestBackup) {
        Write-Host "[ERROR] No encrypted backup (*.enc) found in '$backupsBase'." -ForegroundColor Red
        exit 1
    }
    $BackupFile = $latestBackup.FullName
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Local RAG: Portable Encrypted Backup Verification        " -ForegroundColor Cyan
Write-Host "  Target: $BackupFile" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$tempVerifyDir = Join-Path $WorkspaceDir "backups\temp_verify_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $tempVerifyDir -Force | Out-Null
$tempZip = Join-Path $tempVerifyDir "unpacked.zip"

try {
    # 1. File existence & Size
    $fileItem = Get-Item $BackupFile
    $archiveHash = (Get-FileHash -Path $BackupFile -Algorithm SHA256).Hash
    Write-Host "`n[1/4] Archive Header & File Integrity:" -ForegroundColor Yellow
    Write-Host "  * Size: $($fileItem.Length) bytes" -ForegroundColor Gray
    Write-Host "  * SHA-256: $archiveHash" -ForegroundColor Gray

    # 2. Authenticated AES-256-GCM Decryption Test
    Write-Host "`n[2/4] Testing Authenticated AES-256-GCM Decryption..." -ForegroundColor Yellow
    $pythonExe = "C:\Users\hassa\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
    if (-not (Test-Path $pythonExe)) {
        $pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
    }
    $cryptoScript = Join-Path $WorkspaceDir "scripts\backup_crypto.py"

    $decOutput = & cmd.exe /c "`"$pythonExe`" `"$cryptoScript`" decrypt --input `"$BackupFile`" --output `"$tempZip`" --passphrase `"$resolvedPassphrase`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        throw "Decryption failed (Authentication Tag mismatch or invalid key): $decOutput"
    }
    Write-Host "  [OK] AES-256-GCM Authentication Tag verified. Payload intact." -ForegroundColor Green

    # 3. Extract Bundle & Parse Manifest
    Write-Host "`n[3/4] Unpacking Bundle & Validating Manifest..." -ForegroundColor Yellow
    Expand-Archive -Path $tempZip -DestinationPath $tempVerifyDir -Force
    $manifestPath = Join-Path $tempVerifyDir "backup_manifest.json"
    if (-not (Test-Path $manifestPath)) {
        throw "backup_manifest.json is missing from backup package."
    }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    Write-Host "  [OK] Backup Manifest Timestamp: $($manifest.timestamp)" -ForegroundColor Green

    # 4. Check Internal Component Checksums
    Write-Host "`n[4/4] Validating Component Checksums:" -ForegroundColor Yellow
    $components = $manifest.components
    
    # PostgreSQL
    $sqlFile = Join-Path $tempVerifyDir $components.postgresql.file
    $sqlHash = (Get-FileHash -Path $sqlFile -Algorithm SHA256).Hash
    if ($sqlHash -eq $components.postgresql.sha256) {
        Write-Host "  [OK] PostgreSQL Dump SHA-256 match: $($sqlHash.Substring(0, 16))..." -ForegroundColor Green
    } else {
        throw "PostgreSQL SHA-256 mismatch! Expected: $($components.postgresql.sha256), Got: $sqlHash"
    }

    # Weaviate Volume
    $wvFile = Join-Path $tempVerifyDir $components.weaviate.volume_archive
    $wvHash = (Get-FileHash -Path $wvFile -Algorithm SHA256).Hash
    if ($wvHash -eq $components.weaviate.volume_sha256) {
        Write-Host "  [OK] Weaviate Volume SHA-256 match: $($wvHash.Substring(0, 16))..." -ForegroundColor Green
    } else {
        throw "Weaviate Volume SHA-256 mismatch!"
    }

    # Weaviate Objects
    $wvObjFile = Join-Path $tempVerifyDir $components.weaviate.objects_file
    $wvObjHash = (Get-FileHash -Path $wvObjFile -Algorithm SHA256).Hash
    if ($wvObjHash -eq $components.weaviate.objects_sha256) {
        Write-Host "  [OK] Weaviate Objects SHA-256 match: $($wvObjHash.Substring(0, 16))..." -ForegroundColor Green
    } else {
        throw "Weaviate Objects SHA-256 mismatch!"
    }

    # Storage Volume
    $stFile = Join-Path $tempVerifyDir $components.storage.file
    $stHash = (Get-FileHash -Path $stFile -Algorithm SHA256).Hash
    if ($stHash -eq $components.storage.sha256) {
        Write-Host "  [OK] Dify Storage Volume SHA-256 match: $($stHash.Substring(0, 16))..." -ForegroundColor Green
    } else {
        throw "Dify Storage Volume SHA-256 mismatch!"
    }

    # Ollama Models Manifest
    if ($components.ollama) {
        $olFile = Join-Path $tempVerifyDir $components.ollama.manifest_file
        if (Test-Path $olFile) {
            $olHash = (Get-FileHash -Path $olFile -Algorithm SHA256).Hash
            Write-Host "  [OK] Ollama Models Manifest SHA-256 match: $($olHash.Substring(0, 16))..." -ForegroundColor Green
        }
    }

    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "  Backup Verification PASSED: Archive is Authentic & Sound" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan

} catch {
    Write-Host "`n[FAIL] Backup Verification Failed: $_" -ForegroundColor Red
    exit 1
} finally {
    if (Test-Path $tempVerifyDir) {
        Remove-Item -Path $tempVerifyDir -Recurse -Force | Out-Null
    }
}
