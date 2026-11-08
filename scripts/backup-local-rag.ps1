# ==============================================================================
# Script: backup-local-rag.ps1
# Description: Stage E.1 Enterprise Disaster Recovery — Complete Encrypted System Backup
# Backs up:
#   1. PostgreSQL relational database (pg_dump UTF-8)
#   2. Weaviate vector objects, embeddings, indexes, and schema
#   3. Dify document storage (uploaded files and tenant private keys)
#   4. Plugin daemon configurations, packages, and installed plugins
#   5. Redis persistent state and cache snapshot (dump.rdb)
#   6. Workflow definitions and DSL specifications
# Security: AES-256-GCM authenticated encryption with PBKDF2 key derivation (100k iterations)
# Target: Windows 11 / Docker Desktop / Ollama Native
# Author: a2sn2
# Date: 2026-11-01
# ==============================================================================

[CmdletBinding()]
param(
    [string]$WorkspaceDir = "",
    [string]$BackupsBaseDir = "",
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
if ([string]::IsNullOrWhiteSpace($BackupsBaseDir)) {
    $BackupsBaseDir = Join-Path $WorkspaceDir "backups"
}

# ------------------------------------------------------------------------------
# External Key Management: Resolve passphrase (No hardcoded defaults)
# ------------------------------------------------------------------------------
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
    Write-Host "`n[FATAL ERROR] Backup encryption passphrase is required!" -ForegroundColor Red
    Write-Host "For production security, hardcoded default passphrases have been eliminated." -ForegroundColor Red
    Write-Host "Please provide a key via:" -ForegroundColor Yellow
    Write-Host "  1. CLI parameter:   -Passphrase 'YourStrongPassphrase!'" -ForegroundColor Yellow
    Write-Host "  2. Environment var: `$env:LOCAL_RAG_BACKUP_KEY = 'YourStrongPassphrase!'" -ForegroundColor Yellow
    Write-Host "  3. Key file:        -KeyFile 'path/to/key.txt' or place in .secrets/backup.key" -ForegroundColor Yellow
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$tempBackupDir = Join-Path $BackupsBaseDir "temp_backup_$timestamp"
$encryptedArchive = Join-Path $BackupsBaseDir "backup_$timestamp.enc"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Stage E.1: Complete Encrypted System Backup Automation   " -ForegroundColor Cyan
Write-Host "  Timestamp: $timestamp                                   " -ForegroundColor Cyan
Write-Host "  Target Encrypted File: $encryptedArchive                " -ForegroundColor Cyan
Write-Host "  Cipher: AES-256-GCM Authenticated Encryption             " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if (-not (Test-Path $BackupsBaseDir)) {
    New-Item -ItemType Directory -Path $BackupsBaseDir -Force | Out-Null
}
if (Test-Path $tempBackupDir) {
    Remove-Item -Path $tempBackupDir -Recurse -Force | Out-Null
}
New-Item -ItemType Directory -Path $tempBackupDir -Force | Out-Null

$manifest = [ordered]@{
    "timestamp" = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    "backup_id" = "backup_$timestamp"
    "git_commit" = (& git -C $WorkspaceDir rev-parse HEAD).Trim()
    "encryption" = @{
        "algorithm" = "AES-256-GCM"
        "mode" = "AEAD (Authenticated Encryption with Associated Data)"
        "kdf" = "PBKDF2-HMAC-SHA256"
        "iterations" = 100000
        "auth_tag_length_bits" = 128
        "tamper_protection" = "Cryptographic authentication tag prevents unauthorized modification"
    }
    "components" = [ordered]@{}
}

# ------------------------------------------------------------------------------
# 1. PostgreSQL Relational Database Dump
# ------------------------------------------------------------------------------
Write-Host "`n[1/6] Exporting PostgreSQL Relational Database Dump..." -ForegroundColor Yellow
$sqlFile = Join-Path $tempBackupDir "dify_database.sql"
try {
    # Dump directly inside container to preserve pure UTF-8 encoding
    docker exec dify-db_postgres-1 pg_dump -U postgres -d dify -f /tmp/backup_dify.sql
    docker cp dify-db_postgres-1:/tmp/backup_dify.sql $sqlFile
    docker exec dify-db_postgres-1 rm -f /tmp/backup_dify.sql
    
    if (-not (Test-Path $sqlFile) -or (Get-Item $sqlFile).Length -lt 1000) {
        throw "PostgreSQL dump produced missing or empty file."
    }
    $sqlSize = (Get-Item $sqlFile).Length
    $sqlHash = (Get-FileHash -Path $sqlFile -Algorithm SHA256).Hash
    Write-Host "  [OK] Database dump successful: $sqlSize bytes (SHA-256: $($sqlHash.Substring(0, 12))...)" -ForegroundColor Green
    $manifest["components"]["postgresql"] = @{
        "file" = "dify_database.sql"
        "size_bytes" = $sqlSize
        "sha256" = $sqlHash
    }
} catch {
    Write-Host "  [FAIL] PostgreSQL dump failed: $_" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 2. Weaviate Vector Database Objects, Indexes & Schema
# ------------------------------------------------------------------------------
Write-Host "`n[2/6] Exporting Weaviate Vector Objects, Embeddings & Indexes..." -ForegroundColor Yellow
$weaviateSchemaFile = Join-Path $tempBackupDir "weaviate_schema.json"
$weaviateObjectsFile = Join-Path $tempBackupDir "weaviate_objects.json"
$weaviateDataArchive = Join-Path $tempBackupDir "weaviate_volume.tar.gz"

try {
    $weaviateApiKey = "nAb9sAVbKR4GHUTbkZObAC93nfbHK9ee"

    # A. Schema JSON
    $schemaJson = docker exec dify-api-1 curl -s -H "Authorization: Bearer $weaviateApiKey" http://weaviate:8080/v1/schema
    $schemaJson | Out-File -FilePath $weaviateSchemaFile -Encoding utf8
    $schemaHash = (Get-FileHash -Path $weaviateSchemaFile -Algorithm SHA256).Hash

    # B. Export all objects with dense vector embeddings across all classes
    $pyExportObjects = @'
import json, requests, sys

api_key = "nAb9sAVbKR4GHUTbkZObAC93nfbHK9ee"
headers = {"Authorization": f"Bearer {api_key}"}

# Get classes
schema_resp = requests.get("http://weaviate:8080/v1/schema", headers=headers, timeout=10)
classes = [c["class"] for c in schema_resp.json().get("classes", [])]

all_objects = {}
for cls in classes:
    # Fetch objects with vector embeddings
    url = f"http://weaviate:8080/v1/objects?class={cls}&include=vector&limit=1000"
    resp = requests.get(url, headers=headers, timeout=30)
    objs = resp.json().get("objects", [])
    all_objects[cls] = {
        "count": len(objs),
        "objects": objs
    }
    print(f"Exported {len(objs)} vector objects for class {cls}")

with open("/tmp/weaviate_objects_dump.json", "w", encoding="utf-8") as f:
    json.dump(all_objects, f, ensure_ascii=False)
'@
    $pyExportObjects | docker exec -i dify-api-1 python -
    docker cp dify-api-1:/tmp/weaviate_objects_dump.json $weaviateObjectsFile
    docker exec dify-api-1 rm -f /tmp/weaviate_objects_dump.json
    $objectsHash = (Get-FileHash -Path $weaviateObjectsFile -Algorithm SHA256).Hash
    $objectsSize = (Get-Item $weaviateObjectsFile).Length

    # C. Archive physical Weaviate data directory (LSM trees, HNSW graph, schema.db)
    $sourceWeaviateDir = Join-Path $WorkspaceDir "docker\dify\volumes\weaviate"
    if (Test-Path $sourceWeaviateDir) {
        tar.exe -czf $weaviateDataArchive -C $sourceWeaviateDir .
        $weaviateVolSize = (Get-Item $weaviateDataArchive).Length
        $weaviateVolHash = (Get-FileHash -Path $weaviateDataArchive -Algorithm SHA256).Hash
        Write-Host "  [OK] Physical Weaviate data archive: $weaviateVolSize bytes (SHA-256: $($weaviateVolHash.Substring(0, 12))...)" -ForegroundColor Green
    } else {
        throw "Weaviate physical volume directory not found at '$sourceWeaviateDir'."
    }

    Write-Host "  [OK] Weaviate vector objects dump: $objectsSize bytes (SHA-256: $($objectsHash.Substring(0, 12))...)" -ForegroundColor Green
    $manifest["components"]["weaviate"] = @{
        "schema_file" = "weaviate_schema.json"
        "schema_sha256" = $schemaHash
        "objects_file" = "weaviate_objects.json"
        "objects_size_bytes" = $objectsSize
        "objects_sha256" = $objectsHash
        "volume_archive" = "weaviate_volume.tar.gz"
        "volume_size_bytes" = $weaviateVolSize
        "volume_sha256" = $weaviateVolHash
    }
} catch {
    Write-Host "  [FAIL] Weaviate backup failed: $_" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 3. Dify Document Storage (Uploads & Tenant Private Keys)
# ------------------------------------------------------------------------------
Write-Host "`n[3/6] Archiving Dify Document Storage (Upload Files & Encryption Keys)..." -ForegroundColor Yellow
$storageArchive = Join-Path $tempBackupDir "storage_volume.tar.gz"
try {
    $sourceStorageDir = Join-Path $WorkspaceDir "docker\dify\volumes\app\storage"
    if (Test-Path $sourceStorageDir) {
        tar.exe -czf $storageArchive -C $sourceStorageDir .
        $storageSize = (Get-Item $storageArchive).Length
        $storageHash = (Get-FileHash -Path $storageArchive -Algorithm SHA256).Hash
        Write-Host "  [OK] Document storage archive: $storageSize bytes (SHA-256: $($storageHash.Substring(0, 12))...)" -ForegroundColor Green
        $manifest["components"]["storage"] = @{
            "file" = "storage_volume.tar.gz"
            "size_bytes" = $storageSize
            "sha256" = $storageHash
        }
    } else {
        throw "Document storage directory not found at '$sourceStorageDir'."
    }
} catch {
    Write-Host "  [FAIL] Document storage backup failed: $_" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# 4. Plugin Daemon Configurations & Packages
# ------------------------------------------------------------------------------
Write-Host "`n[4/6] Archiving Plugin Daemon Configurations & Installed Plugins..." -ForegroundColor Yellow
$pluginArchive = Join-Path $tempBackupDir "plugin_daemon_volume.tar.gz"
try {
    $sourcePluginDir = Join-Path $WorkspaceDir "docker\dify\volumes\plugin_daemon"
    if (Test-Path $sourcePluginDir) {
        # Archive excluding volatile uv cache
        tar.exe --exclude="cwd/.uv-cache" -czf $pluginArchive -C $sourcePluginDir .
        $pluginSize = (Get-Item $pluginArchive).Length
        $pluginHash = (Get-FileHash -Path $pluginArchive -Algorithm SHA256).Hash
        Write-Host "  [OK] Plugin daemon archive: $pluginSize bytes (SHA-256: $($pluginHash.Substring(0, 12))...)" -ForegroundColor Green
        $manifest["components"]["plugin_daemon"] = @{
            "file" = "plugin_daemon_volume.tar.gz"
            "size_bytes" = $pluginSize
            "sha256" = $pluginHash
        }
    } else {
        Write-Warning "Plugin daemon directory not found; skipping."
    }
} catch {
    Write-Warning "Plugin daemon archive warning: $_"
}

# ------------------------------------------------------------------------------
# 5. Redis Persistent State Snapshot
# ------------------------------------------------------------------------------
Write-Host "`n[5/6] Exporting Redis Cache & Broker Snapshot..." -ForegroundColor Yellow
$redisFile = Join-Path $tempBackupDir "dump.rdb"
try {
    $bgsave = docker exec dify-redis-1 redis-cli bgsave
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
    }
} catch {
    Write-Warning "Redis backup warning: $_"
}

# ------------------------------------------------------------------------------
# 6. Workflows, Manifest & AES-256 Archive Encryption
# ------------------------------------------------------------------------------
Write-Host "`n[6/6] Packaging Workflows, Manifest & Applying AES-256 Encryption..." -ForegroundColor Yellow
try {
    # Archive workflows
    $workflowsSource = Join-Path $WorkspaceDir "workflows"
    $workflowsDest = Join-Path $tempBackupDir "workflows"
    if (Test-Path $workflowsSource) {
        Copy-Item -Path $workflowsSource -Destination $workflowsDest -Recurse -Force
        $workflowFiles = Get-ChildItem -Path $workflowsDest -Filter "*.yml"
        $manifest["components"]["workflows"] = @{
            "count" = $workflowFiles.Count
            "files" = ($workflowFiles | ForEach-Object { $_.Name })
        }
    }

    # Archive Ollama Model Manifests and Reproducible Instructions
    Write-Host "  Exporting Ollama Model Manifests & Configurations..." -ForegroundColor Gray
    try {
        $ollamaVer = (& ollama --version 2>&1)
        $qwenModelfile = (& ollama show qwen3.5:4b --modelfile 2>&1 | Out-String)
        $bgeModelfile = (& ollama show bge-m3:latest --modelfile 2>&1 | Out-String)

        $ollamaMeta = [ordered]@{
            "ollama_version" = $ollamaVer
            "models" = @(
                [ordered]@{
                    "name" = "qwen3.5:4b"
                    "role" = "Chat LLM (Generation)"
                    "pull_command" = "ollama pull qwen3.5:4b"
                    "parameters" = "presence_penalty 1.5, temperature 1, top_k 20, top_p 0.95"
                    "modelfile" = $qwenModelfile
                },
                [ordered]@{
                    "name" = "bge-m3:latest"
                    "role" = "Text Embedding (1024-dim)"
                    "pull_command" = "ollama pull bge-m3:latest"
                    "modelfile" = $bgeModelfile
                }
            )
        }
        $ollamaMetaPath = Join-Path $tempBackupDir "ollama_models_manifest.json"
        $ollamaMeta | ConvertTo-Json -Depth 5 | Out-File -FilePath $ollamaMetaPath -Encoding utf8
        $manifest["components"]["ollama"] = @{
            "manifest_file" = "ollama_models_manifest.json"
            "models" = @("qwen3.5:4b", "bge-m3:latest")
            "sha256" = (Get-FileHash -Path $ollamaMetaPath -Algorithm SHA256).Hash
        }
    } catch {
        Write-Warning "Ollama manifest export warning: $_"
    }

    # Archive Runtime Environment Configuration (.env)
    $envSource = Join-Path $WorkspaceDir "docker\dify\.env"
    if (Test-Path $envSource) {
        Copy-Item -Path $envSource -Destination (Join-Path $tempBackupDir ".env") -Force
        $manifest["components"]["environment"] = @{
            "file" = ".env"
            "sha256" = (Get-FileHash -Path $envSource -Algorithm SHA256).Hash
        }
    }

    # Save manifest inside the package
    $manifestPath = Join-Path $tempBackupDir "backup_manifest.json"
    $manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestPath -Encoding utf8

    # Compress the entire staging directory into intermediate bundle
    $bundleZip = Join-Path $BackupsBaseDir "temp_bundle_$timestamp.zip"
    if (Test-Path $bundleZip) { Remove-Item $bundleZip -Force }
    Compress-Archive -Path "$tempBackupDir\*" -DestinationPath $bundleZip -CompressionLevel Optimal

    # Authenticated Encryption with AES-256-GCM via backup_crypto.py
    Write-Host "  Encrypting backup bundle with AES-256-GCM (128-bit Auth Tag, PBKDF2 100k iterations)..." -ForegroundColor Gray
    $cryptoScript = Join-Path $WorkspaceDir "scripts\backup_crypto.py"
    $pythonExe = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    $useWsl = $true
    if ($pythonExe -and $pythonExe -notmatch "WindowsApps") {
        try {
            $testCrypto = & cmd.exe /c "`"$pythonExe`" -c `"import cryptography`" 2>nul"
            if ($LASTEXITCODE -eq 0) { $useWsl = $false }
        } catch {}
    }

    if ($useWsl) {
        $wslInput = $bundleZip.Replace("\", "/").Replace("C:", "/mnt/c").Replace("c:", "/mnt/c")
        $wslOutput = $encryptedArchive.Replace("\", "/").Replace("C:", "/mnt/c").Replace("c:", "/mnt/c")
        $wslScript = $cryptoScript.Replace("\", "/").Replace("C:", "/mnt/c").Replace("c:", "/mnt/c")
        $encOutput = & wsl.exe -d Ubuntu -- python3 "$wslScript" encrypt --input "$wslInput" --output "$wslOutput" --passphrase "$resolvedPassphrase" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "AES-256-GCM encryption failed: $encOutput"
        }
    } else {
        $encOutput = & cmd.exe /c "`"$pythonExe`" `"$cryptoScript`" encrypt --input `"$bundleZip`" --output `"$encryptedArchive`" --passphrase `"$resolvedPassphrase`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            throw "AES-256-GCM encryption failed: $encOutput"
        }
    }

    # Clean intermediate unencrypted files
    Remove-Item -Path $bundleZip -Force
    Remove-Item -Path $tempBackupDir -Recurse -Force

    $encSize = (Get-Item $encryptedArchive).Length
    $encHash = (Get-FileHash -Path $encryptedArchive -Algorithm SHA256).Hash

    Write-Host "  [OK] AES-256-GCM Authenticated Archive created: $encryptedArchive ($encSize bytes)" -ForegroundColor Green
    Write-Host "  [OK] Encrypted Archive SHA-256: $encHash" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] Packaging or Encryption failed: $_" -ForegroundColor Red
    exit 1
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Encrypted Backup Completed Successfully!     " -ForegroundColor Green
Write-Host "  Encrypted File: $encryptedArchive                       " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
