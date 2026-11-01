# Changelog — Local RAG Project

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-11-01

### Added & Validated (Stage E — Final Acceptance, Security Audit & Operational Handover)
- **Independent Held-Out Acceptance Dataset (`tests/rag-evaluation/held_out_dataset/`):**
  - Created 3 new unseen fixtures labeled as fictional acceptance fixtures:
    - `national_smart_grid_initiative.ar.md`: Sovereign smart grid automation (18 digital sub-stations, 450 MW, Q3 2027, SG-SEC-2027 standard, 99.98% uptime, GRID-SYNC-9 protocol with 12ms P99 latency).
    - `quantum_resilient_cryptography.en.md`: Quantum-resilient cryptography architecture (ML-KEM-768, lattice N=256, Q=3329, NIST Category 3 / 128-bit margin, 1184-byte public key, 1088-byte ciphertext, 3600s rekeying).
    - `commercial_energy_solutions.ar.md`: Commercial solar solutions report for ambiguity discrimination (6 commercial solar facilities, 120 MW in Yanbu/Rabigh, 99.2% uptime, SLA-SOLAR-88, non-sovereign, SG-SEC-2027 non-applicable).
  - Ingested fixtures into dedicated "Stage E Held-Out Knowledge Base" (`4d4e7d4a-0970-475b-b8b3-f6b66b47d5f9`) indexed with BGE-M3 dense vector + BM25 keyword hybrid search.
- **Independent Acceptance Evaluation Suite (`held_out_queries.json`):**
  - Designed 10 comprehensive held-out test cases covering AR-AR, EN-EN, cross-lingual AR-EN, unsupported abstention, ambiguity discrimination, conflicting sources, adversarial fake document bait, irrelevant distractor, boundary SLA, and token precision.
  - Achieved **100% pass rate** on both Chatbot (30/30 iterations passed) and Chatflow (30/30 iterations passed).
  - Factual accuracy: **100%** on both applications.
  - Source citation grounding: **100%** (zero placeholders, exact section and file references verified against retrieved chunks).
  - Explicit abstention precision: **100%** (zero hallucinated figures on ungrounded queries).
- **Service Resilience, Restart & Recovery Automation (`tests/integration/test-service-recovery.ps1`):**
  - Validated persistence of `OLLAMA_MAX_LOADED_MODELS=1` in `HKCU:\Environment` across process restarts.
  - Verified clean termination and recovery of native Ollama daemon and model re-registration.
  - Verified container restart resilience for Dify core services (`dify-nginx-1`, `dify-api-1`, `dify-plugin_daemon-1`) with health recovery.
  - Verified post-recovery end-to-end RAG inference returning HTTP 200 with grounded answers.
- **Disaster Recovery Backup & Isolated Restoration Testing (`scripts/`):**
  - `backup-local-rag.ps1`: Automated UTF-8 PostgreSQL database dump, Redis snapshot, Weaviate schema, and DSL workflow backups with SHA-256 verification manifests.
  - `test-isolated-restore.ps1`: Automated non-destructive sandbox restoration in an ephemeral container on an isolated Docker network. Successfully verified 172 tables, 1 account, 2 datasets, 6 documents, 27 completed segments, and 3 applications (`restore_verification_report.json`).
- **Production Operations Runbook (`docs/operations/operations-runbook.md`):**
  - Detailed daily startup, graceful shutdown, backup, restore, update SOPs, and a 6-issue RCA troubleshooting matrix.
- **Local Security & Privacy Audit:**
  - Verified all published host ports strictly bound to `127.0.0.1` (ports 80, 443, 5003).
  - Confirmed internal database and backend containers (PostgreSQL, Redis, Weaviate, API) have zero external port bindings.
  - Verified air-gapped offline operation with zero external AI provider dependencies.

---

## [0.6.0] — 2026-11-01

### Added & Hardened (Stage D.1 — Visual Chatflow DAG & Hardened Evaluation)
- **Visual Advanced-Chat Chatflow Application (`Local Bilingual RAG Chatflow`):**
  - Created separate Dify application using `advanced-chat` mode (`AppMode.ADVANCED_CHAT`, App ID: `80a154cf-1787-4aae-8be9-8cd44193d30b`).
  - Constructed real editable 5-node directed acyclic graph (DAG):
    - **START Node** (`start`): Receives bilingual user query `sys.query`.
    - **Knowledge Retrieval Node** (`knowledge-retrieval`): Executes hybrid search (dense BGE-M3 vector + BM25 keyword) against the bilingual Knowledge Base (`8e29fd5b-9537-46ac-acde-191b457b793e`).
    - **If-Else Evidence Gate** (`if-else`): Evaluates retrieval evidence count (`count(result) >= 1`).
    - **LLM Synthesis Node** (`llm`): Invokes local `qwen3.5:4b` with `think: false` and strict citation prompt (`[Document Name, Section]`).
    - **Answer Nodes** (`answer`): Grounded response route for supported facts; explicit abstention branch returning standardized refusal ("المعلومة المطلوبة غير متوفرة في الوثائق المرفقة.") without fabricating sources when evidence is missing.
  - Verified visual accessibility and live editing in Dify Studio (`http://127.0.0.1/app/80a154cf-1787-4aae-8be9-8cd44193d30b/workflow`).
  - Exported complete portable Chatflow DSL to `workflows/local_bilingual_rag_chatflow.yml`.
- **Corpus Ingestion Protection & Content Hashing:**
  - Hardened `tests/rag-evaluation/ingest_corpus.py` to prevent accidental index wipes: requires explicit `--force-reindex --confirm-destroy` flags.
  - Added `--fixtures` parameter to restrict destructive operations to explicitly specified fixture files.
  - Implemented SHA-256 source hashing in document metadata (`doc_metadata['sha256']`) to detect file changes and avoid redundant indexing.
- **Independent Iteration & Latency Hardening:**
  - Refactored `tests/rag-evaluation/evaluate_rag.py` to independently evaluate every benchmark iteration (status, latency, facts, citations, placeholders, unit precision).
  - Explicitly flags HTTP error responses and empty model answers as failed iterations.
  - Measures standalone retrieval latency using `HitTestingService.retrieve` without invoking LLM, reporting `None` when unmeasured (never substitutes `0ms`).
  - Directly computes median (P50) and 95th percentile (P95) latencies from all raw successful request timings.
- **Automated Comparative Benchmark (`tests/rag-evaluation/compare_rag_apps.py`):**
  - Head-to-head comparison between single-step Chatbot (`chat`) and multi-node Chatflow (`advanced-chat`).
  - Confirmed 100% test case pass rate, 100% iteration pass rate, and zero citation placeholders across both applications.
  - Generated comprehensive comparison report at `tests/rag-evaluation/comparison_report.json`.
- **Comprehensive Acceptance Test Suite (`tests/integration/test-stage-d.ps1`):**
  - Updated acceptance test script to validate both applications, verify Chatflow DSL integrity, and enforce comparative benchmark gates across 7 automated stages.

---

## [0.5.1] — 2026-11-01

### Fixed & Remediated (Stage D Quality & Evaluation Remediation)
- **Evaluation False Positives Fixed:**
  - `TC-01-AR-AR`: Enforced strict conjunct assertions requiring both **14 centers** AND **120 PFLOPS** for the government program, preventing false passes on single-number mentions.
  - `TC-05-AMBIGUITY-DISCRIMINATION`: Implemented strict entity-attribution assertions validating private commercial sector figures (**8 centers**, **35 PFLOPS**) and government program figures (**14 centers**, **120 PFLOPS**), preventing ungrounded attribution swaps.
- **Source Citation Integrity Hardened:**
  - Banned citation placeholder patterns (e.g. `[Document Name, Section X]`, `[اسم الوثيقة]`, `[رقم الفقرة]`) across the system prompt and automated test harness.
  - Replaced placeholders with mandatory real document filenames (e.g. `[saudi_tech_initiatives.ar.md, قسم 1]`, `[cloud_architecture_standards.en.md, Section 2]`).
  - Verified inline citations against actual document metadata in Dify's native `retriever_resources`.
- **Cross-Lingual Unit Precision Enforced:**
  - Explicitly distinguished tokens from words across documents, prompts, and evaluation assertions: sliding window overlap is strictly **60 tokens (10%)**, not 60 words.
- **Safe & Idempotent Indexing Operations:**
  - Refactored `tests/rag-evaluation/ingest_corpus.py` to be non-destructive and idempotent by default: skips existing healthy indexed documents.
  - Implemented explicit `--force-reindex` gate utilizing Dify's `DocumentService.delete_document()` to trigger `document_was_deleted` signals, ensuring clean vector removal in Weaviate without orphaned index nodes.
  - Refactored segmentation to use semantic paragraph splitting (`\n\n`), yielding **12 cohesive chunks** (5 in `saudi_tech_initiatives.ar.md`, 4 in `cloud_architecture_standards.en.md`, 3 in `regional_datacenter_comparison.ar.md`).
- **Synthetic Benchmark Data Labeled:**
  - Added explicit `[!NOTE] FICTIONAL TEST FIXTURE` warning headers to all 3 test dataset documents to guarantee they cannot be mistaken for real operational data.
- **Expanded 10-Case Evaluation Suite:**
  - Expanded `tests/rag-evaluation/dataset/test_queries.json` and `evaluate_rag.py` from 5 to 10 test cases:
    - `TC-01-AR-AR`: Sovereign government program metrics (14 centers, 120 PFLOPS).
    - `TC-02-EN-EN`: Interconnect latency specification (15ms P99 under ARCH-NET-09).
    - `TC-03-CROSS-LINGUAL`: Multilingual vector dimensions (1024-dim, 60-token overlap).
    - `TC-04-UNSUPPORTED`: Explicit abstention on unanswerable financial data (Haramain train budget).
    - `TC-05-AMBIGUITY-DISCRIMINATION`: Strict entity attribution (8/35 private vs 14/120 government).
    - `TC-06-ADVERSARIAL-CONFLICTING-SOURCE`: Boundary sovereignty rules (GOV-DATA-SEC non-applicability to commercial 40% hybrid cloud).
    - `TC-07-ADVERSARIAL-FAKE-CITATION`: Rejection of unprovided fake document bait (`cyber_security_vision_2035.ar.md`).
    - `TC-08-IRRELEVANT-DISTRACTOR`: Clean abstention on culinary recipe distractor query.
    - `TC-09-BOUNDARY-EXACT-SLA`: Commercial SLA boundary extraction (99.5% availability, 4-hour RTO).
    - `TC-10-TOKEN-PRECISION-SPEC`: Chunking window nominal target (600 tokens, 60 tokens, strictly tokens).
  - Multi-run benchmarking (3 iterations per case): **10/10 PASSED (100% pass rate)**.
  - Measured latency aggregate: Total Median = **14.62s**, Total P95 = **43.90s**, Generation Median = **14.56s**.
- **Updated Acceptance Test Runner:**
  - Updated `tests/integration/test-stage-d.ps1` to validate the 12 cohesive segments and 10/10 evaluation pass gate.

## [0.5.0] — 2026-11-01

### Added
- Successfully completed and verified **Stage D (Bilingual Knowledge Base & Grounded RAG Chat Application)**.
- Created controlled bilingual test dataset (`tests/rag-evaluation/dataset/`):
  - `saudi_tech_initiatives.ar.md`: Sovereign cloud and AI infrastructure report with verified factual anchors (14 regional data centers, 120 PFLOPS, Dec 2026 target, Saudi-Bench-v2 94.8% retrieval benchmark, GOV-DATA-SEC standard).
  - `cloud_architecture_standards.en.md`: Enterprise cloud specifications (ARCH-NET-09 <=15ms P99 round-trip latency, VEC-DIM-1024 1024-dim vectors, 600 token chunk / 60 token 10% overlap, zero data loss WAL, 99.95% uptime).
  - `regional_datacenter_comparison.ar.md`: Commercial sector comparison document for ambiguity discrimination (8 data centers in Dammam/Jubail, 35 PFLOPS, 40% non-sovereign hybrid cloud, SLA-COM-99 99.5% uptime, 4-hour RTO).
  - `test_queries.json`: Standardized test query suite covering AR-AR, EN-EN, cross-lingual AR-EN, unsupported abstention, and ambiguity discrimination.
- Created and indexed Dify Knowledge Base (`8e29fd5b-9537-46ac-acde-191b457b793e`):
  - Indexing mode: High Quality with `bge-m3:latest` (1024-dimension embedding).
  - Retrieval method: Hybrid Search (Dense Vector + BM25 keyword search).
  - Semantic chunking: 600 max tokens per chunk, 60 tokens (10%) sliding overlap.
  - Successfully indexed all 3 documents into 27 segments in Weaviate vector store (`dify-weaviate-1`).
- Built and hardened Grounded RAG Chatbot Application (`Local Bilingual RAG Assistant`, ID: `5fa6a5ae-ddf1-4a89-a8cd-57891ad5c244`):
  - Primary LLM: `qwen3.5:4b` via `langgenius/ollama/ollama`.
  - Configured `think: false` in model completion parameters to eliminate runaway reasoning loops, slashing response latency from 31+ seconds down to 1.5–2.9 seconds per turn.
  - Prompt engineering: Hardened bilingual system prompt enforcing strict context grounding, anti-hallucination, mandatory inline citations `[اسم الوثيقة، رقم الفقرة]` / `[Document Name, Section]`, and explicit abstention ("المعلومة المطلوبة غير متوفرة في الوثائق المرفقة." / "The requested information is not available in the provided documents.").
  - Linked directly to Knowledge Base dataset and enabled retriever resource citations.
  - Exported complete application DSL to `workflows/local_bilingual_rag_assistant.yml`.
- Executed Comprehensive Automated Acceptance Suite (`tests/integration/test-stage-d.ps1` & `tests/rag-evaluation/evaluate_rag.py`):
  - 100% pass rate (5/5 evaluation cases passed):
    - `TC-01-AR-AR`: Verified 14 centers, cited `saudi_tech_initiatives.ar.md`, 2.74s latency.
    - `TC-02-EN-EN`: Verified 15ms latency at P99 under ARCH-NET-09, cited `cloud_architecture_standards.en.md`.
    - `TC-03-CROSS-LINGUAL`: Arabic query correctly retrieved English document, extracted 1024 dimensions and 10% overlap, answered in Arabic citing source.
    - `TC-04-UNSUPPORTED`: Model strictly abstained ("المعلومة المطلوبة غير متوفرة في الوثائق المرفقة.") with zero fabricated data or hallucinations.
    - `TC-05-AMBIGUITY-DISCRIMINATION`: Perfectly contrasted private commercial sector (8 centers / 35 PFLOPS) vs government sovereign program (14 centers), citing both documents and sections.
  - Resource safety audited: Verified >= 1,200 MiB safe VRAM headroom maintained under full load (measured free headroom: ~1,909 MiB, temperature stable at ~71°C).
  - Security containment verified: Strict localhost port binding (`127.0.0.1:80`, `443`, `5003`) with zero unauthorized external exposure.

## [0.4.0] — 2026-11-01

### Added
- Successfully completed and verified **Stage C (Local Ollama Networking & Embedding Integration)**.
- Established low-latency container-to-host model networking using `http://host.docker.internal:11434`, verified from both `dify-api` and `dify-plugin_daemon`.
- Installed official Dify Marketplace model provider plugin `langgenius/ollama` (v1.0.3) via Dify Plugin Daemon.
- Configured and validated `bge-m3:latest` as primary Text Embedding model (1024-dimension vector output for Arabic and English text, verified with 110ms warm latency).
- Configured and validated `qwen3.5:4b` as primary Chat LLM (4096 context window, chat completion mode with reasoning support).
- Set `qwen3.5:4b` and `bge-m3:latest` as workspace default models for LLM and Embedding within workspace `b30587b8-f547-461e-bfdf-59e8cb4b1bbb`.
- Implemented sequential model swapping strategy using `OLLAMA_MAX_LOADED_MODELS=1` in the native Windows Ollama environment:
  - When embedding runs: `bge-m3:latest` consumes ~657 MB VRAM (total system VRAM: 1,167 MiB, ~4,977 MiB free).
  - When chat inference runs: `qwen3.5:4b` consumes ~2,995 MB VRAM (total system VRAM: 4,164 MiB, ~1,980 MiB free headroom).
  - Guarantees zero VRAM oversubscription on the NVIDIA RTX 3060 6GB Laptop GPU with comfortable thermal and memory margins.
- Verified end-to-end bilingual model execution through Dify model runtime:
  - English prompt test returned verified output `Riyadh`.
  - Arabic prompt test returned verified output `الرياض`.
- Added reproducible automated acceptance test suite `tests/integration/test-stage-c.ps1` and in-container validator `tests/integration/verify_stage_c.py`.
- Added reproducible Stage C provisioning automation `scripts/provision-stage-c.ps1`.
- Verified strict network port isolation: 100% loopback containment (`127.0.0.1`), zero external port exposure.

## [0.3.0] — 2026-11-01

### Added
- Successfully completed and verified **Stage B (Dify v1.18.0 Local Deployment & Health Check)**.
- Deployed full Dify v1.18.0 container stack (16 containers total: API, Web, Celery Worker, Worker Beat, Websocket, PostgreSQL 15, Redis 6, Weaviate 1.39.13, Code Sandbox, Local Agent Sandbox, Agent Backend, Agent SSRF Proxy, Squid SSRF Proxy, Plugin Daemon, Nginx, Init Permissions).
- Enforced strict local loopback binding: Nginx reverse proxy mapped strictly to `127.0.0.1:80` and `127.0.0.1:443`; Plugin Daemon debugging port mapped strictly to `127.0.0.1:5003` via `docker-compose.override.yaml`.
- Validated zero host exposure for all internal services (PostgreSQL 5432, Redis 6379, Weaviate 8080/50051, Sandboxes 8194/5004, API 5001, Web 3000, Agent Backend 5050).
- Generated cryptographically secure tokens for `SECRET_KEY` (64-hex), `SANDBOX_API_KEY` (32-alphanumeric), `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN` (32-alphanumeric), `DIFY_AGENT_SERVER_SECRET_KEY` (unpadded Base64Url), and random database passwords.
- Configured Celery broker authentication (`CELERY_BROKER_URL`) and SSRF proxy allowlists (`host.docker.internal` and local subnets) for low-latency host Ollama connectivity.
- Executed Alembic database migrations cleanly on PostgreSQL.
- Verified Web UI operational at `http://127.0.0.1/` with administrator account creation and verified dashboard session.
- Measured container memory footprint at ~2.43 GiB total (~15.5% of WSL 16GB allocation), preserving 24+ GB RAM for host Windows and Ollama CUDA inference.
- Added reproducible automated provisioning script `scripts/provision-stage-b.ps1`.

## [0.2.0] — 2026-10-30

### Added
- Successfully completed and verified **Stage A (WSL2 & Docker Desktop Provisioning)**.
- Provisioned Windows Subsystem for Linux (WSL2) with Linux Kernel `6.18.54.1-1` and WSL package `3.0.3.0`.
- Implemented and applied host-protective resource configuration (`.wslconfig`) reserving 24GB RAM and 4 CPU threads for host Windows and Ollama (allocating 16GB RAM, 12 logical processors, and 8GB swap to containers).
- Installed Docker Desktop **v4.97.0** in officially recommended per-user mode for Windows user `hassa`.
- Verified Docker Engine daemon **v29.9.2** and Docker Compose **v5.6.1**.
- Verified Linux container runtime execution via `docker run --rm hello-world`.
- Confirmed host Ollama CUDA service remains operational on `http://127.0.0.1:11434` with model `qwen3.5:4b`.
- Added reproducible, privilege-separated provisioning automation scripts (`provision-wsl-elevated.ps1`, `provision-docker-user.ps1`, `launch-stage-a.ps1`).

## [0.1.0] — 2026-10-30

### Added
- Initialized official public Git repository linked to `https://github.com/a2sn2/local-rag-dify`.
- Established standardized project directory layout (`docs/`, `docker/`, `config/`, `scripts/`, `tests/`).
- Added strict `.gitignore` and `.gitattributes` to protect secrets, credentials, live database volumes, model weights, and private assessment logs.
- Added environment template `.env.example` incorporating Dify 1.18.0 security tokens (`SECRET_KEY`, `SANDBOX_API_KEY`, `DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN`).
- Created public architectural specification (`docs/architecture/system-architecture.md`) detailing Dify 1.18.0's 7 core services, 8 dependent components, and 1 initialization task.
- Created deployment roadmap (`docs/deployment/implementation-roadmap.md`) outlining the phased execution protocol (Stages 0 through E).
- Added Git workflow protocol (`docs/deployment/git-workflow.md`) implementing Conventional Commits and remote push verification.
- Added comprehensive security and data-exclusion policy (`docs/security/security-policy.md`).
- Documented verified hardware profile and measured benchmarks (`docs/assessments/hardware-profile.md`).

### Changed
- Corrected target Dify release from v1.14.2 to official pinned stable release **v1.18.0**.
- Updated hardware performance estimates to reflect actual measured metrics: 59.18 tokens/sec generation speed on `qwen3.5:4b` with 100% GPU offload on NVIDIA RTX 3060 Laptop GPU.
- Revised networking strategy from broad binding (`0.0.0.0`) to strict loopback binding (`127.0.0.1:80`) and internal Docker host-gateway routing.
- Reorganized private assessment reports into gitignored local storage (`docs/assessments/private/`) to protect host-identifying information in public repository.
