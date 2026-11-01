# Operations Runbook — Local RAG Platform

**Platform Target:** Dify v1.18.0 Stable + Native Ollama Engine (CUDA)  
**Host Environment:** Windows 11 / WSL2 (Kernel 6.18.54.1-1) / NVIDIA GeForce RTX 3060 Laptop GPU (6GB VRAM)  
**Security Boundary:** 100% Loopback Containment (`127.0.0.1`), Air-Gapped Local Inference  
**Document Revision:** Stage E Operational Handover (v1.0.0)

---

## 1. System Architecture & Inventory

The Local RAG platform couples an official Dify v1.18.0 microservices stack with a host-native Ollama inference daemon:

```
[ Local User Browser ] --> http://127.0.0.1:80 (Nginx Gateway)
                                   |
         +-------------------------+-------------------------+
         |                                                   |
    [ dify-web ] (Next.js :3000)                        [ dify-api ] (Flask :5001)
                                                             |
                 +-------------------+-----------------------+-----------------------+
                 |                   |                       |                       |
          [ dify-worker ]     [ db_postgres ]         [ dify-redis ]          [ dify-weaviate ]
          (Celery Indexer)   (PostgreSQL 15)          (Redis 6 Alpine)        (Vector Engine :8080)
                 |
                 v
   http://host.docker.internal:11434 (Host Gateway Bridge)
                 |
                 v
       [ Native Ollama Engine ] (CUDA Accelerated on RTX 3060 6GB)
          ├── Chat LLM: qwen3.5:4b (num_ctx: 4096, think: false)
          └── Embedding: bge-m3:latest (1024-dim vectors)
```

### Critical Runtime Settings
- **`OLLAMA_MAX_LOADED_MODELS=1`**: Enforces strict sequential model residency in GPU VRAM, preventing out-of-memory errors by swapping `bge-m3:latest` and `qwen3.5:4b` safely.
- **`OLLAMA_NUM_PARALLEL=1`**: Limits inference concurrency to 1 to avoid thread contention on laptop GPUs.
- **`think: false`**: Configured in `completion_params` to disable runaway chain-of-thought tokens, keeping turn generation under 15–20s.

---

## 2. Standard Operating Procedures (SOP)

### 2.1 Daily Startup Procedure

1. **Verify Ollama Host Service:**
   ```powershell
   # Confirm Ollama process is running and environment variable persists
   $envMax = (Get-ItemProperty -Path "HKCU:\Environment" -Name "OLLAMA_MAX_LOADED_MODELS" -ErrorAction SilentlyContinue).OLLAMA_MAX_LOADED_MODELS
   if ($envMax -ne "1") {
       [Environment]::SetEnvironmentVariable("OLLAMA_MAX_LOADED_MODELS", "1", "User")
   }
   
   # Start Ollama daemon if not already running
   if (-not (Get-Process ollama -ErrorAction SilentlyContinue)) {
       Start-Process -FilePath "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" -ArgumentList "serve" -WindowStyle Hidden
       Start-Sleep -Seconds 3
   }
   
   # Probe model tags
   Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get
   ```

2. **Start Dify Microservices:**
   ```powershell
   Set-Location C:\Users\hassa\local-rag
   docker compose -f docker/dify/docker-compose.yaml -f docker/dify/docker-compose.override.yaml up -d
   ```

3. **Verify Service Health:**
   ```powershell
   # Check container status
   docker compose -f docker/dify/docker-compose.yaml ps
   
   # Probe Nginx loopback endpoint
   $resp = Invoke-WebRequest -Uri "http://127.0.0.1/apps" -UseBasicParsing -TimeoutSec 10
   if ($resp.StatusCode -eq 200) { Write-Host "Dify Web Console is ONLINE!" -ForegroundColor Green }
   ```

---

### 2.2 Graceful Shutdown Procedure

To prevent SQLite, PostgreSQL, or Weaviate index corruption, always follow the graceful shutdown sequence:

1. **Verify No Active Workflows or Indexing Tasks:**
   ```powershell
   # Check worker queue
   docker exec dify-worker-1 celery -A app.celery inspect active
   ```

2. **Stop Dify Containers Gracefully:**
   ```powershell
   Set-Location C:\Users\hassa\local-rag
   docker compose -f docker/dify/docker-compose.yaml stop
   ```

3. **Stop Ollama Daemon and Release VRAM:**
   ```powershell
   Stop-Process -Name ollama -Force -ErrorAction SilentlyContinue
   nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
   ```

---

## 3. Disaster Recovery & Backup / Restore

### 3.1 Automated Backup Execution

Run the provided PowerShell backup script regularly:
```powershell
Set-Location C:\Users\hassa\local-rag
.\scripts\backup-local-rag.ps1
```

The script exports:
- `dify_database.sql`: Full PostgreSQL schema, accounts, datasets, apps, and chat records.
- `dump.rdb`: Redis snapshot.
- `weaviate_schema.json`: Complete vector class schema definitions.
- `workflows/`: Exported YAML DSL files for both Chatbot and Chatflow apps.
- `backup_manifest.json`: Cryptographic SHA-256 hashes and timestamp metadata.

All archives are stored in `C:\Users\hassa\local-rag\backups\backup_<timestamp>\`, which is strictly excluded from Git tracking via `.gitignore`.

### 3.2 Isolated Restoration Verification (Dry Run)

To verify backup validity without overwriting or disrupting production databases, execute:
```powershell
Set-Location C:\Users\hassa\local-rag
.\scripts\test-isolated-restore.ps1
```
This spawns an ephemeral isolated container, restores the dump, validates table and segment invariants, and cleans up the sandbox completely.

### 3.3 Production Disaster Recovery Procedure

In the event of physical host drive replacement or volume failure:
1. Ensure Docker Desktop and Ollama are installed and running.
2. Initialize fresh containers: `docker compose -f docker/dify/docker-compose.yaml up -d db_postgres redis weaviate`.
3. Restore database dump:
   ```powershell
   Get-Content "backups\backup_<timestamp>\dify_database.sql" | docker exec -i dify-db_postgres-1 psql -U postgres -d dify
   ```
4. Start remaining application services: `docker compose -f docker/dify/docker-compose.yaml up -d`.
5. Execute acceptance test suite: `.\tests\integration\test-stage-d.ps1`.

---

## 4. Maintenance, Upgrades & Model Lifecycle

### 4.1 Updating Ollama Models
```powershell
# Pull newer quantizations or updated weights
ollama pull qwen3.5:4b
ollama pull bge-m3:latest

# Verify model registration
ollama list
```

### 4.2 Updating Dify Microservices (Minor / Patch Versions)
```powershell
# 1. Take a full backup first
.\scripts\backup-local-rag.ps1

# 2. Pull new container images
docker compose -f docker/dify/docker-compose.yaml pull

# 3. Restart stack with Alembic migrations
docker compose -f docker/dify/docker-compose.yaml up -d

# 4. Check API migration logs
docker logs dify-api-1 --tail 50
```

### 4.3 Disk Space & Docker Volume Hygiene
Do NOT run `docker system prune -a` blindly, as this deletes downloaded model containers and volumes.
Safe volume-preserving cleanup:
```powershell
# Remove dangling build cache and stopped temporary containers only
docker container prune -f
docker image prune -f
```

---

## 5. Troubleshooting & Root Cause Analysis (RCA) Matrix

| Symptom / Error | Root Cause | Remediation Procedure |
| :--- | :--- | :--- |
| **CUDA Out of Memory (OOM)** | Multiple models concurrently loaded into 6GB VRAM. | Verify `OLLAMA_MAX_LOADED_MODELS=1` in HKCU Environment. Restart Ollama daemon to reset GPU memory allocation. |
| **HTTP 502 / Bad Gateway on `127.0.0.1`** | `dify-api` or `dify-web` container restarting or initializing Alembic migrations. | Inspect `docker logs dify-api-1 --tail 100`. Wait 30s for migration completion. Verify PostgreSQL is healthy. |
| **`host.docker.internal:11434` connection refused** | Ollama daemon stopped or Windows Defender Firewall blocking Docker NAT bridge. | Run `Get-Process ollama`. Start Ollama if missing. Verify Docker subnet can route to host (`ping host.docker.internal` from inside container). |
| **Weaviate Socket Timeout during indexing** | High batch size overloading CPU/GPU during embedding generation. | Set paragraph chunk size to 600 tokens and 60 tokens overlap in ingestion script. Ensure BGE-M3 is cached in RAM/VRAM. |
| **Chatflow returns "Workflow not published" (HTTP 400)** | App model record is unlinked from latest published workflow ID. | Re-publish workflow via console or execute `WorkflowService.publish_workflow()` and set `app.workflow_id = published_wf.id`. |
| **Plugin Daemon Disconnected** | Port 5003 conflict or daemon timeout. | Run `docker restart dify-plugin_daemon-1`. Verify `127.0.0.1:5003` loopback binding in `docker-compose.override.yaml`. |

