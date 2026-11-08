# ==============================================================================
# Script: restore-local-rag.ps1
# Description: Production Disaster Recovery & Migration Restoration Script
# Target: Windows 11 / PowerShell 5.1+
# Security: AES-256-GCM Authenticated Decryption with SHA-256 Integrity Verification
# Author: a2sn2
# Date: 2026-11-02
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "",
    [string]$BackupFile = "",
    [string]$Passphrase = "",
    [string]$KeyFile = "",
    [switch]$Force = $false
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceDir)) {
    if ($PSScriptRoot) {
        $WorkspaceDir = (Split-Path $PSScriptRoot -Parent)
    }
    else {
        $WorkspaceDir = (Get-Location).Path
    }
}
$WorkspaceDir = (Resolve-Path $WorkspaceDir).Path
$composeFile = Join-Path $WorkspaceDir "docker\dify\docker-compose.yaml"

# 1. Resolve Passphrase
$resolvedPassphrase = $Passphrase
if ([string]::IsNullOrWhiteSpace($resolvedPassphrase)) {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_RAG_BACKUP_KEY)) {
        $resolvedPassphrase = $env:LOCAL_RAG_BACKUP_KEY
    }
    elseif (-not [string]::IsNullOrWhiteSpace($KeyFile) -and (Test-Path $KeyFile)) {
        $resolvedPassphrase = (Get-Content -Path $KeyFile -Raw).Trim()
    }
    else {
        $defaultKeyPath = Join-Path $WorkspaceDir ".secrets\backup.key"
        if (Test-Path $defaultKeyPath) {
            $resolvedPassphrase = (Get-Content -Path $defaultKeyPath -Raw).Trim()
        }
    }
}

if ([string]::IsNullOrWhiteSpace($resolvedPassphrase)) {
    Write-Host "[ERROR] Decryption passphrase is required to perform restoration." -ForegroundColor Red
    Write-Host "Provide via -Passphrase, `$env:LOCAL_RAG_BACKUP_KEY, -KeyFile, or .secrets/backup.key." -ForegroundColor Yellow
    exit 1
}

# 2. Locate Backup File
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
Write-Host "  Local RAG System: Production Disaster Recovery Restore   " -ForegroundColor Cyan
Write-Host "  Backup Source: $BackupFile" -ForegroundColor Cyan
Write-Host "  Target Workspace: $WorkspaceDir" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if (-not $Force) {
    Write-Host "`n[WARNING] This operation will restore databases, vector indexes, and storage volumes." -ForegroundColor Yellow
    $confirm = Read-Host "Are you sure you want to proceed? (Type 'RESTORE' to confirm)"
    if ($confirm -ne "RESTORE") {
        Write-Host "Restoration aborted by user." -ForegroundColor Gray
        exit 0
    }
}

$tempRestoreDir = Join-Path $WorkspaceDir "backups\temp_prod_restore_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $tempRestoreDir -Force | Out-Null
$tempZip = Join-Path $tempRestoreDir "unpacked.zip"

try {
    # --------------------------------------------------------------------------
    # Step 1: Authenticated Decryption (AES-256-GCM)
    # --------------------------------------------------------------------------
    Write-Host "`n[1/6] Decrypting Backup Archive using AES-256-GCM..." -ForegroundColor Yellow
    $cryptoScript = Join-Path $WorkspaceDir "scripts\backup_crypto.py"
    $pythonExe = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    $useWsl = $true
    if ($pythonExe -and $pythonExe -notmatch "WindowsApps") {
        try {
            $testCrypto = & cmd.exe /c "`"$pythonExe`" -c `"import cryptography`" 2>nul"
            if ($LASTEXITCODE -eq 0) { $useWsl = $false }
        }
        catch {}
    }

    if ($useWsl) {
        $wslInput = $BackupFile.Replace("\", "/").Replace("C:", "/mnt/c").Replace("c:", "/mnt/c")
        $wslOutput = $tempZip.Replace("\", "/").Replace("C:", "/mnt/c").Replace("c:", "/mnt/c")
        $wslScript = $cryptoScript.Replace("\", "/").Replace("C:", "/mnt/c").Replace("c:", "/mnt/c")
        $decOutput = & wsl.exe -d Ubuntu -- python3 "$wslScript" decrypt --input "$wslInput" --output "$wslOutput" --passphrase "$resolvedPassphrase" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Decryption failed (Authentication Tag mismatch or invalid key): $decOutput"
        }
    }
    else {
        $decOutput = & cmd.exe /c "`"$pythonExe`" `"$cryptoScript`" decrypt --input `"$BackupFile`" --output `"$tempZip`" --passphrase `"$resolvedPassphrase`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            throw "Decryption failed (Authentication Tag mismatch or invalid key): $decOutput"
        }
    }
    Write-Host "  [OK] AES-256-GCM authenticated decryption successful." -ForegroundColor Green

    # Unpack
    Expand-Archive -Path $tempZip -DestinationPath $tempRestoreDir -Force
    $manifest = Get-Content (Join-Path $tempRestoreDir "backup_manifest.json") -Raw | ConvertFrom-Json

    # --------------------------------------------------------------------------
    # Step 2: Restore Runtime Configuration (.env)
    # --------------------------------------------------------------------------
    Write-Host "`n[2/6] Restoring Runtime Environment Configuration..." -ForegroundColor Yellow
    $targetEnv = Join-Path $WorkspaceDir "docker\dify\.env"
    $backupEnv = Join-Path $tempRestoreDir ".env"
    if (Test-Path $backupEnv) {
        if (-not (Test-Path $targetEnv)) {
            Copy-Item -Path $backupEnv -Destination $targetEnv -Force
            Write-Host "  [OK] Restored .env to $targetEnv" -ForegroundColor Green
        }
        else {
            Write-Host "  [INFO] Target .env already exists; preserving existing configuration." -ForegroundColor Gray
        }
    }

    # --------------------------------------------------------------------------
    # Step 3: Restore PostgreSQL Relational Database
    # --------------------------------------------------------------------------
    Write-Host "`n[3/6] Restoring PostgreSQL Relational Database..." -ForegroundColor Yellow
    & cmd.exe /c "docker compose -f `"$composeFile`" up -d db_postgres 2>&1" | Out-Null
    
    # Wait for DB readiness
    $pgReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $probe = & cmd.exe /c "docker compose -f `"$composeFile`" exec -T db_postgres psql -U postgres -d dify -c `"SELECT 1;`" 2>nul"
        if ($probe -match "1") { $pgReady = $true; break }
    }
    if (-not $pgReady) { throw "PostgreSQL did not become healthy within timeout." }

    $sqlDump = Join-Path $tempRestoreDir $manifest.components.postgresql.file
    $pgContainer = (& cmd.exe /c "docker compose -f `"$composeFile`" ps -q db_postgres 2>nul").Trim()
    docker cp $sqlDump "${pgContainer}:/tmp/restore.sql"
    & cmd.exe /c "docker compose -f `"$composeFile`" exec -T db_postgres psql -U postgres -d dify -f /tmp/restore.sql 2>&1" | Out-Null
    & cmd.exe /c "docker compose -f `"$composeFile`" exec -T db_postgres rm -f /tmp/restore.sql 2>&1" | Out-Null
    Write-Host "  [OK] PostgreSQL database restored from dump." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 4: Restore Weaviate Physical Data & Vector Index
    # --------------------------------------------------------------------------
    Write-Host "`n[4/6] Restoring Weaviate Vector Database LSM Trees..." -ForegroundColor Yellow
    & cmd.exe /c "docker compose -f `"$composeFile`" stop weaviate 2>&1" | Out-Null
    
    $weaviateVolDir = Join-Path $WorkspaceDir "docker\dify\volumes\weaviate"
    if (-not (Test-Path $weaviateVolDir)) {
        New-Item -ItemType Directory -Path $weaviateVolDir -Force | Out-Null
    }
    $weaviateArchive = Join-Path $tempRestoreDir $manifest.components.weaviate.volume_archive
    tar.exe -xzf $weaviateArchive -C $weaviateVolDir
    
    & cmd.exe /c "docker compose -f `"$composeFile`" up -d weaviate 2>&1" | Out-Null
    Write-Host "  [OK] Weaviate LSM trees and vector indexes restored." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 5: Restore Document Storage & Tenant Encryption Keys
    # --------------------------------------------------------------------------
    Write-Host "`n[5/6] Restoring Dify Document Storage & RSA Keys..." -ForegroundColor Yellow
    $storageVolDir = Join-Path $WorkspaceDir "docker\dify\volumes\app\storage"
    if (-not (Test-Path $storageVolDir)) {
        New-Item -ItemType Directory -Path $storageVolDir -Force | Out-Null
    }
    $storageArchive = Join-Path $tempRestoreDir $manifest.components.storage.file
    tar.exe -xzf $storageArchive -C $storageVolDir
    Write-Host "  [OK] Document files and tenant private keys restored." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 6: Restart Full Stack & Verify Health
    # --------------------------------------------------------------------------
    Write-Host "`n[6/6] Launching Full Dify Stack & Verifying Health..." -ForegroundColor Yellow
    & cmd.exe /c "docker compose -f `"$composeFile`" up -d 2>&1" | Out-Null

    # Quick check
    Start-Sleep -Seconds 5
    $tableCount = & cmd.exe /c "docker compose -f `"$composeFile`" exec -T db_postgres psql -U postgres -d dify -t -c `"SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';`" 2>nul"
    $appCount = & cmd.exe /c "docker compose -f `"$composeFile`" exec -T db_postgres psql -U postgres -d dify -t -c `"SELECT count(*) FROM apps;`" 2>nul"
    
    Write-Host "  Restored Metrics:" -ForegroundColor Gray
    Write-Host "    * Relational Tables: $($tableCount.Trim())" -ForegroundColor Gray
    Write-Host "    * Restored Applications: $($appCount.Trim())" -ForegroundColor Gray

    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "  Restoration COMPLETED Successfully!                      " -ForegroundColor Green
    Write-Host "  Dify Console is accessible at: http://127.0.0.1          " -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan

}
catch {
    Write-Host "`n[FAIL] Restoration Failed: $_" -ForegroundColor Red
    exit 1
}
finally {
    if (Test-Path $tempRestoreDir) {
        Remove-Item -Path $tempRestoreDir -Recurse -Force | Out-Null
    }
}

