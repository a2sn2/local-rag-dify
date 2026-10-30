# Changelog — Local RAG Project

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

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
