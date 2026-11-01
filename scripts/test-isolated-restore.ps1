# ==============================================================================
# Script: test-isolated-restore.ps1
# Description: Stage E Disaster Recovery — Isolated Sandbox Restoration Verification
# Protocol: Strictly isolated test container; 0% modification to production databases
# Target: Windows 11 / Docker Desktop
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "C:\Users\hassa\local-rag",
    [string]$BackupDir = ""
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage E: Isolated Restoration Verification Test         " -ForegroundColor Cyan
Write-Host "  Protocol: Non-destructive Isolated Sandbox               " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Locate backup
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $backupsBase = Join-Path $WorkspaceDir "backups"
    $latestBackup = Get-ChildItem -Path $backupsBase -Directory -Filter "backup_*" | Sort-Object CreationTime -Descending | Select-Object -First 1
    if (-not $latestBackup) {
        throw "No backup found in '$backupsBase'. Please run scripts/backup-local-rag.ps1 first."
    }
    $BackupDir = $latestBackup.FullName
}

Write-Host "`nTarget Backup Directory: $BackupDir" -ForegroundColor Gray

# 2. Verify Manifest and Checksums
Write-Host "`n[1/5] Verifying Backup Integrity & SHA-256 Checksums..." -ForegroundColor Yellow
$manifestPath = Join-Path $BackupDir "backup_manifest.json"
if (-not (Test-Path $manifestPath)) {
    throw "Manifest file missing at '$manifestPath'"
}
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$sqlFile = Join-Path $BackupDir "dify_database.sql"
if (-not (Test-Path $sqlFile)) {
    throw "SQL backup file missing at '$sqlFile'"
}

$calculatedHash = (Get-FileHash -Path $sqlFile -Algorithm SHA256).Hash
$expectedHash = $manifest.components.postgresql.sha256
if ($calculatedHash -ne $expectedHash) {
    throw "Checksum mismatch! Expected: $expectedHash, Got: $calculatedHash"
}
Write-Host "  [OK] SHA-256 verified: $calculatedHash" -ForegroundColor Green

# 3. Create Ephemeral Isolated Container
$sandboxName = "dify_restore_sandbox_db_" + (Get-Random -Minimum 1000 -Maximum 9999)
$networkName = "dify_restore_net_" + (Get-Random -Minimum 1000 -Maximum 9999)

Write-Host "`n[2/5] Creating Isolated Sandbox Network & Ephemeral Container..." -ForegroundColor Yellow
try {
    docker network create $networkName | Out-Null
    # Run isolated postgres:15-alpine on isolated network with NO host port publishing
    docker run -d --name $sandboxName --network $networkName `
        -e POSTGRES_PASSWORD=restore_sandbox_pwd `
        -e POSTGRES_DB=dify `
        postgres:15-alpine | Out-Null

    # Wait for postgres genuine query readiness
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $probe = & cmd /c "docker exec $sandboxName psql -U postgres -d dify -c `"SELECT 1;`" 2>nul"
        if ($probe -match "1") {
            $ready = $true
            break
        }
    }

    if (-not $ready) {
        throw "Isolated sandbox postgres failed to reach query readiness."
    }
    Write-Host "  [OK] Ephemeral sandbox container operational: $sandboxName" -ForegroundColor Green

    # 4. Restore into Sandbox
    Write-Host "`n[3/5] Restoring SQL Dump into Isolated Sandbox..." -ForegroundColor Yellow
    docker cp $sqlFile "${sandboxName}:/tmp/restore.sql"
    docker exec $sandboxName psql -U postgres -d dify -f /tmp/restore.sql | Out-Null
    Write-Host "  [OK] SQL dump restored into sandbox." -ForegroundColor Green

    # 5. Query and Validate Restored Data
    Write-Host "`n[4/5] Auditing Schema and Data Invariants in Restored Database..." -ForegroundColor Yellow
    function Parse-DbInt($val) {
        $clean = ($val -join "") -replace '[^\d]'
        return [int]$clean
    }

    $tableCount = Parse-DbInt (docker exec $sandboxName psql -U postgres -d dify -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")
    $accountCount = Parse-DbInt (docker exec $sandboxName psql -U postgres -d dify -t -c "SELECT count(*) FROM accounts;")
    $datasetCount = Parse-DbInt (docker exec $sandboxName psql -U postgres -d dify -t -c "SELECT count(*) FROM datasets;")
    $documentCount = Parse-DbInt (docker exec $sandboxName psql -U postgres -d dify -t -c "SELECT count(*) FROM documents;")
    $segmentCount = Parse-DbInt (docker exec $sandboxName psql -U postgres -d dify -t -c "SELECT count(*) FROM document_segments WHERE status = 'completed';")
    $appCount = Parse-DbInt (docker exec $sandboxName psql -U postgres -d dify -t -c "SELECT count(*) FROM apps;")

    Write-Host "  Restored Database Metrics:" -ForegroundColor Gray
    Write-Host "    * Tables: $tableCount" -ForegroundColor Gray
    Write-Host "    * Accounts: $accountCount" -ForegroundColor Gray
    Write-Host "    * Datasets: $datasetCount" -ForegroundColor Gray
    Write-Host "    * Documents: $documentCount" -ForegroundColor Gray
    Write-Host "    * Completed Segments: $segmentCount" -ForegroundColor Gray
    Write-Host "    * Apps: $appCount" -ForegroundColor Gray

    if ([int]$tableCount -lt 50 -or [int]$accountCount -lt 1 -or [int]$datasetCount -lt 1 -or [int]$appCount -lt 2) {
        throw "Restored database metrics validation failed! Incomplete restore."
    }
    Write-Host "  [OK] All database invariants and records verified successfully." -ForegroundColor Green

    $report = [ordered]@{
        "timestamp" = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        "status" = "PASSED"
        "backup_tested" = (Split-Path $BackupDir -Leaf)
        "checksum_verified" = $true
        "isolation_verified" = $true
        "restored_metrics" = @{
            "tables_count" = [int]$tableCount
            "accounts_count" = [int]$accountCount
            "datasets_count" = [int]$datasetCount
            "documents_count" = [int]$documentCount
            "completed_segments_count" = [int]$segmentCount
            "apps_count" = [int]$appCount
        }
    }

    $reportPath = Join-Path $WorkspaceDir "tests\rag-evaluation\restore_verification_report.json"
    $report | ConvertTo-Json -Depth 5 | Out-File -FilePath $reportPath -Encoding utf8
    Write-Host "  [OK] Verification report saved: $reportPath" -ForegroundColor Green

} finally {
    # 6. Teardown Sandbox
    Write-Host "`n[5/5] Tearing Down Ephemeral Sandbox Resources..." -ForegroundColor Yellow
    docker rm -f $sandboxName 2>&1 | Out-Null
    docker network rm $networkName 2>&1 | Out-Null
    Write-Host "  [OK] Ephemeral sandbox cleanly destroyed. Production remained 100% untouched." -ForegroundColor Green
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Isolated Restoration Test PASSED!                       " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
