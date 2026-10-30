# Phased Implementation Roadmap — Local RAG Deployment

**Pinned Target:** Dify v1.18.0 Stable Release + Ollama Native Engine  
**Execution Protocol:** Isolated Staged Approval Protocol (Stage 0 through Stage E)

---

## 1. Roadmap Overview & Execution Gates

```mermaid
flowchart TD
    Stage0["Stage 0: GitHub Integration & Project Init\n(COMPLETED & VERIFIED)"] --> Gate0{User Review & Approval}
    Gate0 --> StageA["Stage A: WSL2 & Docker Desktop Prerequisites\n(COMPLETED & VERIFIED)"]
    StageA --> GateA{User Review & Approval\n(CURRENT GATE)}
    GateA --> StageB["Stage B: Dify 1.18.0 Deployment & Health Check\n(AUTHORIZED UPON APPROVAL)"]
    StageB --> GateB{User Review & Approval}
    GateB --> StageC["Stage C: Ollama Networking & Embedding Model\n(PENDING STAGE B)"]
    StageC --> GateC{User Review & Approval}
    GateC --> StageD["Stage D: Knowledge Base & RAG App Creation\n(PENDING STAGE C)"]
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
- **Status:** **COMPLETED & FULLY VERIFIED**
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

### Stage B: Dify 1.18.0 Deployment & Container Health Check
- **Status:** **PENDING USER AUTHORIZATION (Next Gate)**
- **Objective:** Deploy Dify's official pinned stable release `1.18.0` with full security token hardening.
- **Actions:**
  1. Clone pinned release `1.18.0` into project deployment folder.
  2. Generate cryptographic keys: `SECRET_KEY`, `SANDBOX_API_KEY`, `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN`.
  3. Enforce loopback binding: `127.0.0.1:80` for Nginx reverse proxy.
  4. Launch the multi-container stack: `docker compose up -d`.
- **Verification Gate:** All 7 core services and 8 dependent components report `running (healthy)`, and `init_permissions` reports `Exited (0)`.

---

### Stage C: Ollama Host Networking & Embedding Model Setup
- **Status:** **PENDING STAGE B COMPLETION**
- **Objective:** Establish low-latency loopback communication between Dify containers and Ollama host engine.
- **Actions:**
  1. Verify container-to-host connectivity: probe `http://host.docker.internal:11434` from inside `dify-api`.
  2. Pull and benchmark the bilingual embedding model `bge-m3` (`ollama pull bge-m3`).
  3. Verify concurrent GPU memory headroom against `qwen3.5:4b`.
- **Verification Gate:** Successful embedding generation for sample Arabic and English sentences via cURL from Dify API container.

---

### Stage D: Knowledge Base Indexing & Bilingual RAG Application
- **Status:** **PENDING STAGE C COMPLETION**
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
