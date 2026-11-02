# Migration & Full Disaster Recovery Guide

> **Scope:** Reproducible, machine-independent instructions for migrating the Local RAG platform to a new computer or recovering from complete data loss.  
> **Target Platform:** Windows 11 (64-bit) with NVIDIA CUDA GPU (>= 6GB VRAM)  
> **Security Baseline:** Public Git repository paired with authenticated AES-256-GCM private data archives.

---

## 1. Storage Boundaries: GitHub vs. Private Encrypted Backup

To maintain strict data sovereignty and comply with open-source repository policies:

| Layer | What is Stored on Public GitHub | What is Stored in Encrypted Backup Archive (`.enc`) |
| :--- | :--- | :--- |
| **Source Code & Scripts** | All orchestration scripts, evaluation suites, Docker Compose manifests, documentation | Redundant copy of workflows and deployment configs |
| **Relational Database** | `.env.example` baseline template only | Complete PostgreSQL database dump (`dify_database.sql`): accounts, workspaces, app configs |
| **Vector Database** | None | Physical Weaviate LSM data trees (`weaviate_volume.tar.gz`) and vector object dump (`weaviate_objects.json`) |
| **Storage Volumes** | None | Uploaded tenant files and tenant RSA private keys (`private.pem`) in `storage_volume.tar.gz` |
| **Cache & Task Broker** | None | Redis persistent RDB snapshot (`dump.rdb`) |
| **Model Weights** | Open-source references and reproduction commands | Model manifests and modelfiles (`ollama_models_manifest.json`) |
| **Security Keys** | None (strictly excluded via `.gitignore`) | External key managed separately by operator |

> [!IMPORTANT]
> **GitHub alone cannot restore application state.**  
> Restoring your knowledge bases, chat history, and accounts requires the encrypted backup archive (`backups\backup_<timestamp>.enc`) and the corresponding decryption passphrase.

---

## 2. Target Machine Prerequisites

Before initiating restoration on a new workstation, ensure the following hardware and software prerequisites are met:

1. **Hardware:**
   - **CPU:** x86_64 multi-core processor (AMD Ryzen or Intel Core, 8+ threads recommended).
   - **RAM:** Minimum 16 GB system memory (32+ GB recommended).
   - **GPU:** Dedicated NVIDIA GPU with **minimum 6 GB GDDR6 VRAM** (e.g., RTX 3060, RTX 4060 or higher).
   - **Disk Space:** At least 40 GB free SSD storage.
2. **Operating System:**
   - Windows 11 64-bit (Build 22000 or higher).
3. **Software Toolchain:**
   - **WSL2:** Enabled with default version 2 (`wsl --set-default-version 2`).
   - **Docker Desktop:** Latest version with WSL2 backend enabled.
   - **Ollama:** Native Windows installation ([https://ollama.com/download](https://ollama.com/download)).
   - **Python:** Python 3.10+ installed with the `cryptography` package (`pip install cryptography`).
   - **Git:** Git for Windows.

---

## 3. Step-by-Step Migration & Restoration Procedure

### Step 1: Clone the Project Repository
Open PowerShell on the target workstation:
```powershell
# Navigate to your desired development directory
Set-Location "$env:USERPROFILE"
git clone https://github.com/a2sn2/local-rag-dify.git local-rag
Set-Location local-rag
```

### Step 2: Transfer the Private Encrypted Backup & Key
Transfer your encrypted backup archive and decryption key from secure storage into the project directory:
```powershell
# Create directories if needed
if (-not (Test-Path "backups")) { New-Item -ItemType Directory -Path "backups" -Force | Out-Null }
if (-not (Test-Path ".secrets")) { New-Item -ItemType Directory -Path ".secrets" -Force | Out-Null }

# Copy your backup archive into backups\
# (Example: backup_20261102_021800.enc)
Copy-Item "D:\secure-vault\backup_20261102_021800.enc" -Destination "backups\"

# Place your decryption passphrase into .secrets\backup.key OR set $env:LOCAL_RAG_BACKUP_KEY
Set-Content -Path ".secrets\backup.key" -Value "YourStrongDecryptionPassphrase" -NoNewline
```

### Step 3: Verify Preflight Environment Readiness
Execute the automated preflight audit script:
```powershell
.\scripts\check-environment.ps1
```
Confirm that OS, WSL2, Docker, GPU, and Python all report `[PASS]`.

### Step 4: Download and Verify Ollama Models
Ensure Ollama is running, then pull the exact pinned models:
```powershell
# Set required concurrency and model residency settings
$env:OLLAMA_HOST = "0.0.0.0:11434"
$env:OLLAMA_MAX_LOADED_MODELS = "1"
$env:OLLAMA_NUM_PARALLEL = "1"

# Pull Generation and Embedding models
ollama pull qwen3.5:4b
ollama pull bge-m3:latest

# Verify model presence
ollama list
```

### Step 5: Verify Encrypted Archive Soundness
Verify the cryptographic authenticity and checksums of the backup before applying:
```powershell
.\scripts\verify-backup.ps1
```
Expected output:
```
[OK] AES-256-GCM Authentication Tag verified. Payload intact.
[OK] PostgreSQL Dump SHA-256 match
[OK] Weaviate Volume SHA-256 match
[OK] Dify Storage Volume SHA-256 match
Backup Verification PASSED: Archive is Authentic & Sound
```

### Step 6: Execute Automated Restoration
Run the production restoration script:
```powershell
.\scripts\restore-local-rag.ps1 -Force
```
This automates:
1. AES-256-GCM authenticated decryption.
2. Restoring `docker/dify/.env` configuration.
3. Starting PostgreSQL and importing `dify_database.sql`.
4. Restoring Weaviate LSM trees and vector indexes into `docker/dify/volumes/weaviate`.
5. Restoring uploaded documents and tenant encryption keys into `docker/dify/volumes/app/storage`.
6. Starting the complete 16-container Dify microservices stack.

---

## 4. Post-Restoration Verification & Acceptance Testing

Once restoration finishes, verify operational integrity:

1. **Web Console Access:**
   Open your browser to [http://127.0.0.1](http://127.0.0.1). Log in with your restored administrator credentials.
2. **Application Verification:**
   - Navigate to **Studio** and verify that both applications are present:
     - `Local Bilingual RAG Assistant` (Chatbot)
     - `Local Bilingual RAG Chatflow` (Advanced Chat)
3. **Knowledge Base Verification:**
   - Navigate to **Knowledge** and verify that your datasets and indexed segments are intact.
4. **End-to-End Inference Smoke Test:**
   Submit a test query in the Chatflow application:
   - Query: `"ما هو الارتفاع المداري لمنظومة الأقمار الاصطناعية الكمومية؟"`
   - Expected: Grounded response citing `sovereign_quantum_satellite_communications.ar.md` with zero external cloud requests.

---

## 5. Troubleshooting Migration Errors

| Symptom | Root Cause | Remediation |
| :--- | :--- | :--- |
| `Decryption failed (Invalid Tag)` | Incorrect passphrase or corrupted archive file | Verify `.secrets/backup.key` matches the key used during `backup-local-rag.ps1`. Check archive SHA-256. |
| `Weaviate: need at least one user` | Missing authentication API key configuration | Ensure `AUTHENTICATION_APIKEY_USERS=hello@dify.ai` is present in `docker/dify/.env`. |
| `Docker: network dify_default not found` | Docker Compose stack not initialized | Run `docker compose -f docker/dify/docker-compose.yaml up -d` before restoring databases. |
| `Ollama: Connection refused (11434)` | Ollama daemon not started or bound to 127.0.0.1 only | Set `$env:OLLAMA_HOST = "0.0.0.0:11434"` and run `ollama serve`. |

