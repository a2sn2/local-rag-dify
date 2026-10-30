# Security & Data-Exclusion Policy — Public Repository Standard

**Target Repository:** `https://github.com/a2sn2/local-rag-dify` (PUBLIC)  
**Security Classification:** Public Codebase with Strict Local-Data Isolation  
**Last Updated:** October 30, 2026

---

## 1. Public Repository Content Exclusion Policy

Because this repository is publicly accessible on GitHub, all contributors and automation agents must adhere to strict data-exclusion protocols prior to any staging or commit action:

### Strictly Excluded Items:
1. **Actual Secrets & Environment Files:** `.env`, `.env.local`, `.env.production`, or any file containing active passwords or access keys.
2. **Authentication Credentials & Tokens:** GitHub Personal Access Tokens (PAT), SSH private keys, API keys, and session cookies.
3. **Machine-Specific Confidential Identifiers:** Host machine serial numbers, internal MAC addresses, Windows account usernames, and absolute user paths (use relative or generic placeholders like `%USERPROFILE%`).
4. **Local Hardware Diagnostics:** Unsanitized raw diagnostics containing personal data or host environment logs (retained strictly in `docs/assessments/private/` which is ignored by Git).
5. **Model Weights & Checkpoints:** GGUF binaries, PyTorch `.pt` files, safetensors, and Ollama blob files.
6. **Docker Volumes & Database Dumps:** Live PostgreSQL database files (`pgdata/`), Weaviate vector indexes, and Redis state files.
7. **Personal Documents & Knowledge Base Content:** Any real PDF, DOCX, TXT, or confidential business documents uploaded to Dify's knowledge base.

---

## 2. Loopback-Only & Network Containment Policy

1. **Localhost Web Binding:**
   - The Dify Nginx entrypoint must be bound strictly to `127.0.0.1:80` (or a designated non-privileged loopback port).
   - Binding Nginx or any Dify web interface to `0.0.0.0` is strictly forbidden to prevent unintended exposure to the local Wi-Fi or corporate network.
2. **Database Encapsulation:**
   - PostgreSQL (5432), Redis (6379), Weaviate (8080), and Sandboxes (8194, 5004) must remain unmapped to host interfaces, communicating exclusively through Docker's internal bridge network.
3. **Ollama Network Restriction:**
   - Ollama must not be broadly exposed to `0.0.0.0:11434` without explicit firewall filtering limiting inbound requests to the Docker internal gateway (`host.docker.internal` / virtual adapter subnet).

---

## 3. Sandbox Authentication & Token Hardening

- **Dify Sandbox Token (`SANDBOX_API_KEY`):** Must be replaced from the default value (`dify-sandbox`) with a cryptographically generated 32-character token.
- **Agent Local Sandbox Token (`DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN`):** Required for Dify 1.18.0; must be generated cryptographically and interpolated via `.env`.

---

## 4. Pre-Commit Review Checklist

Before creating any Git commit:
- [ ] Run `git status` to verify that no untracked secrets or unignored files are staged.
- [ ] Verify that `docs/assessments/private/` is uncommitted and listed in `.gitignore`.
- [ ] Inspect diffs (`git diff --staged`) to confirm all paths, URLs, and documentation are fully sanitized.
- [ ] Confirm no `.env` file is staged.
