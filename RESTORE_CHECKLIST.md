# Local RAG System — Restoration & Migration Checklist

This document provides a comprehensive, field-tested procedure for migrating and restoring the complete Local RAG platform (Dify v1.18.0 + Ollama + JAIB Visual Identity) onto a new Windows machine.

---

## 1. Destination Machine Prerequisites

Ensure the target machine meets the following baseline requirements before initiating restoration:

- [ ] **Windows 11 (64-bit)** with Virtualization enabled in BIOS/UEFI.
- [ ] **WSL2 Installed & Configured:**
  ```powershell
  wsl --install --no-distribution
  wsl --update
  wsl --status
  ```
- [ ] **Docker Desktop for Windows:**
  - Installed and configured to use the **WSL 2 backend** (`Settings > General > Use the WSL 2 based engine`).
  - Allocated at least 8 GB RAM (recommended: 12–16 GB) in `%USERPROFILE%\.wslconfig`.
- [ ] **Ollama for Windows:**
  - Installed from `https://ollama.com/download/windows`.
  - Ollama process running on host port `11434`.
- [ ] **Git for Windows:**
  ```powershell
  winget install --id Git.Git -e --source winget
  ```
- [ ] **Python 3.10+ & Cryptography Library:**
  ```powershell
  python --version
  pip install cryptography
  ```

---

## 2. Directory & Path Neutrality

The system is fully portable and **does NOT require the original username or path** (`C:\Users\hassa\local-rag`).

- Any target directory is supported (e.g., `C:\Users\<NewUser>\local-rag`, `D:\AI\local-rag`).
- Throughout this guide, `<TARGET_DIR>` denotes your chosen workspace directory on the new machine.
- All PowerShell scripts accept the `-WorkspaceDir` parameter and auto-detect their location via `$PSScriptRoot`.

---

## 3. Migration Package Checklist (Files on Encrypted USB)

Before leaving the source machine, ensure the following items are stored on your secure external drive:

- [ ] `backup_20261107_235138.enc` (Encrypted system snapshot — 3.64 MB)
- [ ] `backup.key` (PBKDF2 passphrase key file — 37 bytes)
- [ ] `docker\dify\.env` (Dify environment configuration — 10.8 KB)
- [ ] `Jaib Theme\` (Raw brand reference assets — 1.63 MB)
- [ ] `models\` (Ollama model blobs directory from `%USERPROFILE%\.ollama\models\` — 4.17 GB, optional to save download bandwidth)

---

## 4. Step-by-Step Restoration Protocol

### Phase 1: Clone Repository
On the new machine, open PowerShell as Administrator and run:
```powershell
git clone https://github.com/a2sn2/local-rag-dify.git "<TARGET_DIR>"
cd "<TARGET_DIR>"
```

### Phase 2: Place Secrets & Configuration Files
Copy the sensitive, git-ignored assets from your secure drive into their designated paths:
```powershell
# 1. Create .secrets directory and place the backup decryption key
New-Item -ItemType Directory -Path "<TARGET_DIR>\.secrets" -Force
Copy-Item "E:\Migration\backup.key" -Destination "<TARGET_DIR>\.secrets\backup.key" -Force

# 2. Place runtime .env configuration
Copy-Item "E:\Migration\.env" -Destination "<TARGET_DIR>\docker\dify\.env" -Force

# 3. Place encrypted backup archive
New-Item -ItemType Directory -Path "<TARGET_DIR>\backups" -Force
Copy-Item "E:\Migration\backup_20261107_235138.enc" -Destination "<TARGET_DIR>\backups\" -Force

# 4. (Optional) Place raw JAIB brand references
Copy-Item "E:\Migration\Jaib Theme" -Destination "<TARGET_DIR>\Jaib Theme" -Recurse -Force
```

### Phase 3: Setup Ollama Models
Ensure Ollama is running, then populate the models:

**Option A (Fast Local Copy — Recommended):**
```powershell
# Copy blobs and manifests into the destination user profile
Copy-Item "E:\Migration\models\*" -Destination "$env:USERPROFILE\.ollama\models" -Recurse -Force
Restart-Process -Name ollama -ErrorAction SilentlyContinue
ollama list
```

**Option B (Network Pull from Registry):**
```powershell
ollama pull bge-m3:latest
ollama pull qwen3.5:4b
```

**Configure Ollama Windows Environment Variables (Critical for 6GB VRAM):**
```powershell
[System.Environment]::SetEnvironmentVariable('OLLAMA_MAX_LOADED_MODELS', '1', 'User')
[System.Environment]::SetEnvironmentVariable('OLLAMA_NUM_PARALLEL', '1', 'User')
[System.Environment]::SetEnvironmentVariable('OLLAMA_FLASH_ATTENTION', '1', 'User')
```

### Phase 4: Verify Backup Integrity (Non-Destructive)
Verify the archive before modifying Docker state:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify-backup.ps1 -WorkspaceDir "<TARGET_DIR>" -BackupFile "<TARGET_DIR>\backups\backup_20261107_235138.enc"
```
*Expected Output:* `Backup Verification PASSED: Archive is Authentic & Sound`.

### Phase 5: Execute Production Restoration
Restore the PostgreSQL relational database, Weaviate vector engine, and Dify storage:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\restore-local-rag.ps1 -WorkspaceDir "<TARGET_DIR>" -BackupFile "<TARGET_DIR>\backups\backup_20261107_235138.enc" -Force
```
*Expected Output:*
- PostgreSQL relational tables: `172`
- Restored applications: `3`
- Status: `Restoration COMPLETED Successfully!`

### Phase 6: Rebuild Custom JAIB Web Container
Build the air-gapped custom frontend image on the destination machine and apply the theme:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\apply-jaib-theme.ps1 -WorkspaceDir "<TARGET_DIR>"
```
*Expected Output:*
- Builds `local-rag/dify-web:1.18.0-jaib` from `themes\jaib\docker\Dockerfile.jaib-web`.
- Verifies `docker-compose.override.yaml` is active.
- Recreates `dify-web-1` container.
- Health check: `http://127.0.0.1/logo/logo.svg` returns `200 OK`.

---

## 5. Post-Restoration Acceptance Verification

Run through these checks to certify the migration:

1. [ ] **Container Health:**
   ```powershell
   docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
   ```
   *Verify that all 15 containers are `Up`, and `dify-plugin_daemon-1` is strictly bound to `127.0.0.1:5003->5003/tcp`.*
2. [ ] **Browser Access:**
   Navigate to `http://127.0.0.1` in Chrome or Edge.
   - [ ] Sign-in page renders with JAIB pure vector SVG logo.
   - [ ] Login using existing administrator credentials (no account reset needed).
   - [ ] Dify Studio displays the 3 existing RAG applications.
   - [ ] Knowledge Base displays existing datasets and documents.
3. [ ] **End-to-End RAG Functional Verification:**
   - Execute an Arabic test query in the Chat Assistant.
   - Verify that citations are generated and facts match the knowledge documents.
   - Verify abstention on unsupported questions.

---

## 6. Troubleshooting Common Migration Issues

| Issue / Symptom | Root Cause | Solution |
| :--- | :--- | :--- |
| `Decryption failed (Authentication Tag mismatch)` | Incorrect passphrase or corrupted `.enc` file | Verify `backup.key` SHA-256 matches manifest (`00874EC53446...`) and re-copy `.enc`. |
| `docker compose up failed: port 80/443 in use` | IIS or Windows HTTP.sys listening on port 80 | Run `net stop was /y` or disable IIS in Windows Features. |
| `Failed to connect to Ollama (11434)` | Ollama daemon not started or firewall block | Run `ollama serve` or start Ollama from the Windows Start menu. |
| `White screen on http://127.0.0.1` | Web image built with legacy runtime patch | Ensure image is built via `apply-jaib-theme.ps1` using the static CSS bundling Dockerfile. |
| `Port 5003 listening on 0.0.0.0` | Git clone pulled an older commit | Ensure you are on commit `e4345bc` or later where loopback binding is enforced. |
