# Phased Implementation Roadmap — Local RAG Deployment

**Pinned Target:** Dify v1.18.0 Stable Release + Ollama Native Engine  
**Execution Protocol:** Isolated Staged Approval Protocol (Stage 0 through Stage E)

---

## 1. Roadmap Overview & Execution Gates

```mermaid
flowchart TD
    Stage0["Stage 0: GitHub Integration & Project Init\n(COMPLETED & VERIFIED)"] --> Gate0{User Review & Approval}
    Gate0 --> StageA["Stage A: WSL2 & Docker Desktop Prerequisites\n(COMPLETED & VERIFIED)"]
    StageA --> GateA{User Review & Approval}
    GateA --> StageB["Stage B: Dify 1.18.0 Deployment & Health Check\n(COMPLETED & VERIFIED)"]
    StageB --> GateB{User Review & Approval}
    GateB --> StageC["Stage C: Ollama Networking & Embedding Model\n(COMPLETED & VERIFIED)"]
    StageC --> GateC{User Review & Approval\n(CURRENT GATE)}
    GateC --> StageD["Stage D: Knowledge Base & RAG App Creation\n(PENDING AUTHORIZATION)"]
    StageD --> GateD{User Review & Approval}
    GateD --> StageE["Stage E: Functional & Acceptance Validation\n(FINAL GATE)"]
```

---

## 2. Stage Breakdown & Acceptance Gates

### Stage 0: Repository Integration & Project Initialization (Completed)
- **Status:** **COMPLETED & VERIFIED** (Commit: `3d4b9fe`)
- **Objective:** Establish the official public GitHub repository (`https://github.com/a2sn2/local-rag-dify`), sanitize documentation, implement the security exclusion policy, configure `.gitignore`, and commit initial project scaffolding.
- **Verification Gate:** Confirmed SHA match on GitHub remote, 100% clean tree, zero sensitive data tracked.

---

### Stage A: WSL2 and Docker Desktop Prerequisites (Completed)
- **Status:** **COMPLETED & FULLY VERIFIED** (Commit: `a974088`)
- **Verified Components:**
  - `Microsoft.WSL`: Version **3.0.3.0** (Linux Kernel **6.18.54.1-1**, Default WSL Version: 2).
  - `Docker.DockerDesktop`: Version **4.97.0** (Per-User Installation under `hassa`, WSL2 backend).
  - `Docker Engine`: Version **29.9.2** (Linux daemon operational on `desktop-linux`).
  - `Docker Compose`: Version **v5.6.1**.
  - `Container Runtime`: Verified via `docker run --rm hello-world` execution.
- **Resource Allocation (`.wslconfig`):**
  - Memory ceiling: **16 GB** (reserves 24 GB RAM for Windows host and Ollama).
  - CPU cores: **12 logical processors** (reserves 4 cores for host OS and Ollama).
  - Swap: **8 GB** on NVMe SSD.
  - Loopback: `localhostForwarding=true`.
- **Provisioning Scripts & Automation:**
  - `scripts/provision-wsl-elevated.ps1`: Automated Phase 1 elevated installer enabling `VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux`.
  - `scripts/provision-docker-user.ps1`: Phase 2 un-elevated user-context installer and acceptance test runner.
  - `scripts/launch-stage-a.ps1`: Privilege-separated orchestrator.
- **Verification Gate Results:** All acceptance checks passed (`docker info`, `docker compose version`, `docker run --rm hello-world`, Ollama `qwen3.5:4b` service health).

---

### Stage B: Dify 1.18.0 Deployment & Container Health Check (Completed)
- **Status:** **COMPLETED & FULLY VERIFIED**
- **Objective:** Deploy Dify's official pinned stable release `1.18.0` with full security token hardening, local loopback containment, and database migrations.
- **Verified Deliverables & Architecture:**
  - **Dify Core Stack (`docker/dify`):** Official pinned v1.18.0 images and compose layout.
  - **Active Containers (16 total):**
    - `api` (`langgenius/dify-api:1.18.0`): Healthy (Flask API backend, Alembic migrations complete).
    - `web` (`langgenius/dify-web:1.18.0`): Running (Next.js console frontend).
    - `worker` (`langgenius/dify-api:1.18.0`): Running (Celery background task execution).
    - `worker_beat` (`langgenius/dify-api:1.18.0`): Running (Celery beat periodic scheduler).
    - `api_websocket` (`langgenius/dify-api:1.18.0`): Running (Collaboration websocket service).
    - `db_postgres` (`postgres:15-alpine`): Healthy (Relational datastore).
    - `redis` (`redis:6-alpine`): Healthy (Caching & Celery broker).
    - `weaviate` (`cr.weaviate.io/semitechnologies/weaviate:1.39.13`): Running (Vector DB for hybrid search).
    - `sandbox` (`langgenius/dify-sandbox:0.2.15`): Healthy (Code execution sandbox).
    - `local_sandbox` (`langgenius/dify-agent-local-sandbox:1.18.0`): Healthy (Agent execution sandbox).
    - `agent_backend` (`langgenius/dify-agent-backend:1.18.0`): Running (Agent orchestrator).
    - `agent_ssrf_proxy` (`ubuntu/squid:latest`): Running (Agent egress firewall).
    - `ssrf_proxy` (`ubuntu/squid:latest`): Running (Squid egress proxy).
    - `plugin_daemon` (`langgenius/dify-plugin-daemon:0.6.10-local`): Running (Plugin runtime).
    - `nginx` (`nginx:latest`): Running (Reverse proxy entrypoint).
    - `init_permissions` (`busybox:latest`): Exited (0) (Expected one-shot storage permission initialization).
  - **Loopback Containment & Port Bindings:**
    - Nginx Web UI: `127.0.0.1:80->80/tcp`, `127.0.0.1:443->443/tcp` (Strictly loopback).
    - Plugin Daemon: `127.0.0.1:5003->5003/tcp` (Loopback enforced via `docker-compose.override.yaml`).
    - Databases & Internal Services: PostgreSQL (5432), Redis (6379), Weaviate (8080/50051), Sandbox (8194), Local Sandbox (5004), API (5001), Web (3000), Agent Backend (5050) have **zero host port mappings**.
  - **Cryptographic Token Hardening:**
    - `SECRET_KEY`: Cryptographically generated 64-hex string.
    - `SANDBOX_API_KEY`: Cryptographically generated 32-character token.
    - `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN`: Cryptographically generated 32-character token.
    - `DIFY_AGENT_SERVER_SECRET_KEY`: Valid 32-byte unpadded base64url string (`^[a-zA-Z0-9_-]{43}$`).
    - `DB_PASSWORD` & `REDIS_PASSWORD`: Secure 24-character random alphanumeric strings.
    - `CELERY_BROKER_URL`: Synchronized with `REDIS_PASSWORD`.
    - `WEAVIATE_API_KEY`: Cryptographically generated 32-character token.
  - **Network & SSRF Policy:**
    - Allowed private domains: `host.docker.internal` (enables Stage C Ollama communication).
    - Allowed CIDRs: `127.0.0.1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8`.
  - **Resource Footprint:**
    - Total Memory Usage: ~2.43 GiB across all 15 active containers (~15.5% of WSL 16GB limit).
    - Host Memory Headroom: 24+ GB RAM remaining for Windows and host Ollama CUDA.
  - **Verification Gate Results:** Web UI accessible at `http://127.0.0.1/`, Administrator account created and verified, health check `status=ok`.

---

### Stage C: Ollama Host Networking & Embedding Model Setup (Completed)
- **Status:** **COMPLETED & FULLY VERIFIED**
- **Objective:** Establish low-latency loopback communication between Dify containers and the native Ollama host engine, install the official provider plugin, and register verified models.
- **Verified Deliverables & Metrics:**
  - **Container-to-Host Gateway Networking:**
    - Probed and verified `http://host.docker.internal:11434/api/tags` from inside `dify-api` and `dify-plugin_daemon`.
    - Zero external network routing; communication restricted to internal Docker virtual network bridge (`192.168.65.254`).
  - **Official Ollama Provider Plugin:**
    - Installed official Dify Marketplace plugin `langgenius/ollama` (v1.0.3) via Dify Plugin Daemon.
    - Verified registration and schema loading under tenant `b30587b8-f547-461e-bfdf-59e8cb4b1bbb`.
  - **Text Embedding Integration (`bge-m3:latest`):**
    - Configured with base URL `http://host.docker.internal:11434` and registered as workspace default embedding model.
    - Output vector dimension verified: **1024** for both Arabic and English text.
    - Warm embedding latency: **~110 ms**; cold swap latency: **~2.8 s**.
  - **Chat LLM Integration (`qwen3.5:4b`):**
    - Configured with base URL `http://host.docker.internal:11434`, context window **4096**, chat mode, and reasoning support.
    - End-to-end verified through Dify model runtime: English returned `Riyadh`, Arabic returned `الرياض`.
  - **GPU Memory Safety & Sequential Model Swapping (`OLLAMA_MAX_LOADED_MODELS=1`):**
    - Configured sequential model swapping in native Ollama environment:
      - Baseline system VRAM (OS & desktop apps): **397 MiB**.
      - `bge-m3:latest` resident VRAM: **657 MB** (Total: **1,167 MiB**, Headroom: **4,977 MiB**).
      - `qwen3.5:4b` resident VRAM: **2,995 MB** (Total: **4,164 MiB**, Headroom: **1,980 MiB**).
    - Guarantees >32% safe VRAM headroom on the NVIDIA RTX 3060 6GB Laptop GPU with stable thermal operating range (64–69°C).
  - **Acceptance Automation:**
    - `tests/integration/test-stage-c.ps1`: Full 6-stage acceptance test suite.
    - `tests/integration/verify_stage_c.py`: In-container Dify model runtime validator.
    - `scripts/provision-stage-c.ps1`: Reproducible Stage C provisioning automation.
  - **Verification Gate Results:** All 6 acceptance tests passed completely (`1_Ollama_Service`, `2_Container_Gateway_Networking`, `3_Dify_Model_Runtime`, `4_GPU_Memory_Boundaries`, `5_Port_Containment`, `6_Dify_Health_Endpoints`).

---

### Stage D: Knowledge Base Indexing & Bilingual RAG Application
- **Status:** **PENDING AUTHORIZATION (NOT YET AUTHORIZED)**
- **Objective:** Configure model providers, dataset indexing, and build the grounded RAG chat application.
- **Actions:**
  1. Register Ollama models in Dify Admin Console: `qwen3.5:4b` (LLM) and `bge-m3` (Embedding).
  2. Create Knowledge Base with hybrid search (Dense Vector + BM25 keyword).
  3. Ingest representative bilingual documents (Arabic and English).
  4. Configure prompt engineering with strict source citations and explicit abstention instructions.
- **Verification Gate:** Successful vector indexing in Weaviate and verification of chunk count.

---

### Stage E: Acceptance Testing, Security Audit & Operational Handover
- **Status:** **PENDING STAGE D COMPLETION**
- **Objective:** Execute the 10-point acceptance test matrix:
  1. Arabic document retrieval and grounded response quality.
  2. English document retrieval and grounded response quality.
  3. Cross-lingual retrieval (Arabic query -> English source).
  4. Anti-hallucination verification (abstention on unanswerable queries).
  5. Correct inline citations and chunk references.
  6. Air-gapped offline operation validation (zero cloud API dependencies).
  7. GPU thermal and VRAM headroom monitoring under load.
- **Verification Gate:** Complete acceptance test report signed off by user.
