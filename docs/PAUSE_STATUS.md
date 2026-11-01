# Project Pause Status & Operational Baseline

> **Status:** `PAUSED — PORTABLE HANDOVER PREPARED — MANUAL CORRECTIONS PENDING`  
> **Date:** 2026-11-02  
> **Lead DevOps & Handover Manager:** Antigravity Engineering  
> **Workspace:** `C:\Users\hassa\local-rag`  
> **Git Repository:** [https://github.com/a2sn2/local-rag-dify](https://github.com/a2sn2/local-rag-dify)  
> **Reference Commit:** `0d46c2f6e5a3d0d81e08c73107a1611468865d6e`

---

## 1. Executive Summary & Non-Readiness Notice

This document establishes the verified operational baseline of the **Local RAG Platform (Dify v1.18.0 + Ollama Native)** at the point of graceful project pause and handover.

> [!CAUTION]
> **Production Non-Readiness Notice:**
> While the infrastructure, container orchestration, authenticated AES-256-GCM disaster recovery engine, and tamper-detection safeguards have been completed and verified (Stage E.1), **final RAG quality acceptance remains incomplete**.
> - The sealed evaluation suite (Stage E.1 zero-tuning benchmark) demonstrated that while the Chatflow architecture achieved 100% abstention precision on ungrounded/adversarial queries, single-step and fine-grained factual token matching require further prompt engineering, chunk overlap optimization, and parameter tuning.
> - **Do NOT claim full production readiness.** The system is paused in a stable, verified, and restorable state.

---

## 2. Infrastructure & Software Configuration Matrix

| Component | Pinned Version / Build | Verification Digest / Output | Operational Notes |
| :--- | :--- | :--- | :--- |
| **Operating System** | Windows 11 Pro 64-bit | Build `26300.9818` | Host workstation platform |
| **WSL2** | Kernel 6.18.54.1-1 | Default Distro: `docker-desktop` (v2) | Virtualization backend |
| **Docker Engine** | 29.9.2 (build a82e528) | Client & Engine API v1.52 | Docker Desktop runtime |
| **Docker Compose** | v5.6.1 | Go Compose plugin | Stack orchestrator |
| **Dify Platform** | Pinned `v1.18.0` | Official Langgenius release | 16-container microservices architecture |
| **Host LLM Engine**| Ollama `0.40.13` | Native Windows (`127.0.0.1:11434`) | Native CUDA acceleration (`qwen3.5:4b`) |
| **Host Embedding** | Ollama Native | Native CUDA acceleration | Dense 1024-dim embedding (`bge-m3:latest`)|
| **Hardware GPU**   | NVIDIA RTX 3060 Laptop | Driver `621.01`, 6GB GDDR6 VRAM | Peak VRAM measured: 4,149 MB |

### 2.1 Exact Docker Images & Digests

| Container Name | Image Repository & Tag | Image Digest (SHA-256) |
| :--- | :--- | :--- |
| `dify-api-1` | `langgenius/dify-api:1.18.0` | `sha256:0120970fb4ea59aa328d63b7dda635cccc071efb8aae470cd07115a026dbffd3` |
| `dify-worker-1` | `langgenius/dify-api:1.18.0` | `sha256:0120970fb4ea59aa328d63b7dda635cccc071efb8aae470cd07115a026dbffd3` |
| `dify-web-1` | `langgenius/dify-web:1.18.0` | `sha256:e55a6bf1addf109c3655567663f906624f0980061efed864e0f07d23c71fa385` |
| `dify-db_postgres-1`| `postgres:15-alpine` | `sha256:54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984` |
| `dify-weaviate-1` | `cr.weaviate.io/semitechnologies/weaviate:1.39.13` | `sha256:ad2b986bbe4666fbd5302a5ee0cc6c74a048c4c769198d46147ea232d46a2dd8` |
| `dify-redis-1` | `redis:6-alpine` | `sha256:63d5174750e285bc3069c4519c53c8b6de6ebe70715140a6c9d21d6f04b77319` |
| `dify-nginx-1` | `nginx:latest` | `sha256:5ab5b0b01097420873a3f3330f44248e34a3c2a3e8d5ee30658aeae8cb7435da` |
| `dify-plugin_daemon-1`| `langgenius/dify-plugin-daemon:0.6.10-local` | `sha256:34412a22d1e1d1a6c73727fef88cffbcdd9be7a21bf9ad3076b4bf5c1b88fd9b` |
| `dify-sandbox-1` | `langgenius/dify-sandbox:0.2.15` | `sha256:750e1111426ef31a9217b81c98cccfb750f17b182af3221102e420afa9f0928e` |
| `dify-ssrf_proxy-1`| `ubuntu/squid:latest` | `sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029` |
| `dify-agent_backend-1`| `langgenius/dify-agent-backend:1.18.0` | `sha256:80d638d7114bb0fbe954952e37da1f464b61969ff870c0b173963b9f2b91e06e` |

### 2.2 Ollama Models & Layer Hashes

- **Chat Model:** `qwen3.5:4b`
  - Model ID: `d8b0f5e9760c` (Size: 3.3 GB)
  - Primary Weights Blob: `sha256:a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50`
  - Config Blob: `sha256:e56a899b1540860385465756dd308c84417410b94dbc1c380adffd20a921ca60`
  - Reproduction Command: `ollama pull qwen3.5:4b`
- **Embedding Model:** `bge-m3:latest`
  - Model ID: `790764642607` (Size: 1.2 GB)
  - Primary Weights Blob: `sha256:daec91ffb5dd0c27411bd71f29932917c49cf529a641d0168496c3a501e3062c`
  - Reproduction Command: `ollama pull bge-m3:latest`

---

## 3. Verified Authenticated Backup Inventory

The complete operational state of the local RAG environment has been captured in an **AES-256-GCM** authenticated archive:

- **Archive File:** `backups\backup_20261102_021800.enc`
- **Archive Size:** 3,473,054 bytes (~3.31 MB)
- **Archive SHA-256:** `B7B2AAB46C12E653439936A64E2356DF28226E3483C60066A7EB3DA6F6ADD774`
- **Cipher Suite:** AES-256-GCM (128-bit authentication tag, PBKDF2-HMAC-SHA256 with 100,000 iterations, 12-byte random nonce).
- **Encryption Key:** Managed externally via `.secrets/backup.key` or `$env:LOCAL_RAG_BACKUP_KEY`. Excluded from Git.
- **Verification Status:** Verified via `scripts/verify-backup.ps1` and non-destructive dry-run `scripts/test-isolated-restore.ps1`.

### Archive Manifest Contents:
1. `dify_database.sql` (19.5 MB uncompressed PostgreSQL relational dump): Accounts, workspace bindings, applications, datasets, document metadata, and completed segments.
2. `weaviate_volume.tar.gz`: Physical LSM trees, HNSW graphs, and schema definitions from `/var/lib/weaviate`.
3. `weaviate_objects.json`: Vector objects and raw 1024-dim embeddings across all 3 indexed classes.
4. `storage_volume.tar.gz`: Uploaded documents and tenant RSA encryption private keys (`private.pem`).
5. `dump.rdb`: Redis persistent cache and task broker snapshot.
6. `workflows/`: Application YAML DSL specifications for Chatbot and Chatflow apps.
7. `ollama_models_manifest.json`: Model manifests, modelfiles, and exact parameters.
8. `.env`: Complete Dify deployment environment configuration.

---

## 4. Outstanding Issues Postponed for Manual Remediation

When resuming work, the following engineering tasks should be addressed:

1. **RAG Generalization Quality Tuning:**
   - Optimize chunk segmentation boundary detection for Arabic technical standards.
   - Implement hybrid retrieval score weighting (balancing dense vector cosine distance with BM25 keyword matching) to improve exact numerical/acronym token recall.
2. **Windows Firewall Rule Automation:**
   - The Ollama host binding (`0.0.0.0:11434`) allows Docker containers to communicate via Docker Desktop's bridge, but exposes port 11434 to the local LAN under default Windows Firewall rules.
   - Run the administrator PowerShell command documented in `docs/operations/operations-runbook.md` to restrict inbound traffic to loopback and Docker subnets.
3. **Offsite Backup Replication:**
   - The encrypted backup currently resides on the local workstation disk (`C:\Users\hassa\local-rag\backups`). To achieve complete migration sign-off, copy `backup_20261102_021800.enc` and `.secrets/backup.key` to an independent external drive or private secure cloud vault.
