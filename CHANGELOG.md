# Changelog — Local RAG Project

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

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
