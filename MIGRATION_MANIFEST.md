# Local RAG System — Comprehensive Migration Manifest

**Project:** Dify v1.18.0 + Ollama + JAIB Custom Theme  
**Current Git Commit:** `e4345bc79f323c2a297371d3c01bf03875dc9350`  
**Repository:** `https://github.com/a2sn2/local-rag-dify`  
**Branch:** `main`  
**Generated Date:** 2026-11-08T00:06:00+03:00  
**Security Status:** Encrypted / Sanitized (Zero secrets, keys, or credentials exposed)  

---

## 1. System Specifications & Runtime Versions

| Component | Verified Version | Notes / Role |
| :--- | :--- | :--- |
| **Operating System** | Windows 11 Pro / Enterprise (`10.0.26300.9818`) | Host OS |
| **WSL2 Subsystem** | Kernel `6.18.54.1-1`, WSL `3.0.3.0` | Linux backend for Docker Desktop |
| **Docker Desktop** | `29.9.2` (build `a82e528`) | Container platform |
| **Docker Compose** | `v5.6.1` | Multi-container orchestration |
| **Dify Platform** | `v1.18.0` | Orchestration, RAG Knowledge Base & Workflows |
| **Ollama Native** | `v0.40.15` | Local LLM & Embedding runtime on Windows |
| **Python Runtime** | `3.12` with `cryptography 50.0.2` | Backup encryption and decryption engine |
| **Git for Windows** | `2.55.0.windows.5` | Version control |

---

## 2. Ollama Models Inventory

Ollama models are stored outside the project workspace in the user directory (`%USERPROFILE%\.ollama\models`).

| Model Name | Model ID | Digest / SHA-256 | Size | Parameters / Dimensions |
| :--- | :--- | :--- | :--- | :--- |
| **`bge-m3:latest`** | `790764642607` | `sha256:daec91ffb5dd0c27411bd71f29932917c49cf529a641d0168496c3a501e3062c` | 1.2 GB | 1024-dimensional dense text embedding |
| **`qwen3.5:4b`** | `d8b0f5e9760c` | `sha256:a9d0a3e1d8c91732a3812becd31f8d4a8ff57414903f226306069f0437e2ac50` | 3.3 GB | 4-billion parameter bilingual chat model |

**Storage Directory on Host:** `C:\Users\hassa\.ollama\models` (Total Size: **4.17 GB**)

---

## 3. Fresh Encrypted Backup Archive

This backup was generated using authenticated AES-256-GCM encryption with PBKDF2-HMAC-SHA256 (100,000 iterations) via `scripts/backup-local-rag.ps1`.

- **Backup File Path:** `backups\backup_20261107_235138.enc`
- **File Size:** `3,642,940 bytes` (~3.47 MB)
- **SHA-256 Checksum:** `961D29655EAB069D9CC2C7298A789C012AB1DF3582453D2140F9E76129193404`
- **Cipher / AEAD:** AES-256-GCM with 128-bit authentication tag
- **Integrity Status:** Verified via `verify-backup.ps1` (Authentication tag intact, checksums match)
- **Restoration Test:** Verified via `test-isolated-restore.ps1` (100% pass across PostgreSQL, Weaviate, and Dify Storage)

---

## 4. Required Configuration & Secrets Inventory

> **SECURITY NOTICE:** Secret values, API keys, database passwords, and encryption passphrases must NEVER be committed to Git or exposed in logs. Only file paths and their cryptographic hashes are documented here for verification.

| Configuration File | Source Path | Size (Bytes) | SHA-256 Checksum | Purpose / Contents |
| :--- | :--- | :--- | :--- | :--- |
| **Dify Runtime Environment** | `docker\dify\.env` | `10,830` | `95F4F73097F0E917FFB27B4B0440F488B485BBCE2CE5BE9E31DECA1F4023FA9A` | DB creds, SECRET_KEY, Weaviate API key, ports |
| **Backup Passphrase Key** | `.secrets\backup.key` | `37` | `00874EC534468081737B4AD3B6D900F4A80EFBCDC9BC6679343409094047EA57` | PBKDF2 passphrase for backup encryption/decryption |
| **Docker Compose Main** | `docker\dify\docker-compose.yaml` | `57,695` | `DF2A2DB361A82E92C0803B30A243D15767C3F5CBB818596EC57D05AD3E507F0D` | Main microservices configuration (15 services) |
| **Docker Compose Override** | `docker\dify\docker-compose.override.yaml` | `442` | `14DC08849C5C05147937B63FC2FE4958D74E615520CD4EFC0487A7F1D46A2DF9` | Mounts custom `local-rag/dify-web:1.18.0-jaib` image |
| **Compose Template** | `docker\dify\docker-compose-template.yaml` | `57,355` | `452CE4FE3D2FB0EA9ABCF97F556248943A5AC05580E3BFCD725BD83B3FE9E7D8` | Base template with port 5003 secured |
| **Middleware Compose** | `docker\dify\docker-compose.middleware.yaml` | `12,157` | `828424A63A806EE5D3CD3DF55925BDC65A53BDAD9C486FEE37B8317C2D208B5E` | Middleware compose with port 5003 secured |

---

## 5. JAIB Branding & Custom Frontend Artifacts

All operational branding code is tracked in Git, ensuring reproducible builds on the destination machine.

| Artifact Path | Size (Bytes) | SHA-256 Checksum | Tracking Status | Role |
| :--- | :--- | :--- | :--- | :--- |
| `themes\jaib\docker\Dockerfile.jaib-web` | `1,976` | `7C749F01573E544D066623E981C880EF0C9265A45021D3E5018B1D701B548B29` | Tracked in Git | Air-gapped custom web container buildfile |
| `themes\jaib\css\jaib-theme.css` | `27,429` | `C111559182AC7371F0CC1CFD1DBF73844228D47EE3E28D1DE40EA1460E4D6C86` | Tracked in Git | Static CSS overrides for JAIB red and typography |
| `themes\jaib\assets\logo.svg` | `1,084` | `AB5EA27E9D9AD7D832C6504F54015DE12BF1D637E5864F615BB4B1F8D9FEC6FE` | Tracked in Git | Pure vector SVG logo (Light mode) |
| `themes\jaib\assets\logo-dark.svg` | `1,108` | `B9968421FAA72455558294B12307926D19A8C5A67251EE6417D77C2FC71E2E20` | Tracked in Git | Pure vector SVG logo (Dark mode) |
| `themes\jaib\assets\favicon.ico` | `775` | `5C8DA08F3E6294447E41DEA908EE5747428E5F4108AC6A50D86E33E56910DCD0` | Tracked in Git | Official JAIB browser favicon |
| `Jaib Theme\All.png` | `1,540,269` | `B36FC25ED1C8770058BC8097494F598333933C1FEDACA34F7792863AF413A24B` | Git-Ignored | Full raw brand reference sheet |
| `Jaib Theme\jaib_visual_identity_interactive.html` | `38,665` | `870FD1653F4373FA409737FF7988BC10B3B4800A58ECC6CD57E3FA026C4E1700` | Git-Ignored | Interactive branding reference tool |
| `Jaib Theme\PromptEngineer.txt` | `30,345` | `5CD1D09241DCB1EE7F84AEBE3FD3549A181B82EF6191B2EBFD6F1F03D698DC0F` | Git-Ignored | Brand prompts and styling specifications |
| `Jaib Theme\README - شرح مجلد هوية JAIB.docx` | `20,630` | `9CEBDE159373E998BB580B1ABBCD7C9F168BD05AC83BD4B02B1AF00547BF46B0` | Git-Ignored | Arabic documentation for JAIB brand identity |

---

## 6. Live Persistent Volumes & Bind Mounts Inventory

All primary Dify persistent data resides in bind mounts under `docker\dify\volumes\`.

| Bind Mount Directory | Raw Size | Key Contents | Backed Up In Archive |
| :--- | :--- | :--- | :--- |
| `docker\dify\volumes\db\` | ~88.8 MB | PostgreSQL 15 database (`dify` db, accounts, datasets) | Yes (`dify_database.sql`) |
| `docker\dify\volumes\weaviate\` | ~13.3 MB | Weaviate vector LSM stores, HNSW index files | Yes (`weaviate_volume.tar.gz` & `weaviate_objects.json`) |
| `docker\dify\volumes\app\storage\` | ~0.14 MB | Uploaded knowledge files, tenant private RSA keys | Yes (`storage_volume.tar.gz`) |
| `docker\dify\volumes\plugin_daemon\` | ~190.2 MB | Installed plugin binaries, manifests, virtual environments | Yes (`plugin_daemon_volume.tar.gz`) |
| `docker\dify\volumes\redis\` | ~0.02 MB | Redis `dump.rdb` persistence and session state | Yes (`dump.rdb`) |
| `docker\dify\volumes\sandbox\` | ~1.1 KB | Code execution sandbox temporary data | Automatically initialized |

---

## 7. Operational Scripts Inventory

| Script | Size (Bytes) | SHA-256 Checksum | Purpose |
| :--- | :--- | :--- | :--- |
| `scripts\backup-local-rag.ps1` | `17,552` | `E4F561559AF41044ECC768CBFB83517BB0A34614C3C8747ADFA5DEB98B1ABF67` | Complete encrypted backup automation |
| `scripts\restore-local-rag.ps1` | `9,713` | `19E238F2375AEDDDDEAC5B018C6962AA16604DC34DCE2A754CFED4B68E0CA7EA` | Production restoration script |
| `scripts\verify-backup.ps1` | `7,325` | `F09827CC596749CDFCDB0247E7144057E6F73F1E09F43A4E444B956B8B747A54` | Non-destructive backup integrity check |
| `scripts\test-isolated-restore.ps1` | `20,323` | `B23F1D376136A1BFCD69AB492EB22E6DB47D02A52B9A7B1C2A5FDEFB218F1012` | Isolated sandbox disaster recovery test |
| `scripts\start-local-rag.ps1` | `5,809` | `161CD645BA2DA5EBE4F4C6771E16C8113067386A6E8B68B81A2F7BD37DF49F79` | Platform startup and health check |
| `scripts\stop-local-rag.ps1` | `5,029` | `679D3D39E222DE42B856E2E54DED94D405CECCAE615B25876423E23089737EBB` | Graceful shutdown (preserves volumes) |
| `scripts\apply-jaib-theme.ps1` | `3,412` | `2B779E6EF7C5660F36E1C91A2EA78CC034FF64F51AE3EF3E148C4198A0CA71C4` | Builds and activates JAIB theme container |
| `scripts\backup_crypto.py` | `5,210` | `4D805DDE9C83C793871ADF18504EC0E7A10A2B66254299246F8103106B0B1874` | Cryptographic engine for AES-256-GCM |

---

## 8. Verification & Restoration Evidence

The latest encrypted backup `backup_20261107_235138.enc` was tested end-to-end via `scripts\test-isolated-restore.ps1`:
- **Decryption:** Authenticated AES-256-GCM successfully unpacked 3,642,873 bytes.
- **Relational Integrity:**
  - 172 PostgreSQL tables restored without errors.
  - 1 Administrator Account preserved.
  - 3 Knowledge Datasets preserved.
  - 9 Knowledge Documents preserved.
  - 40 Completed Segments preserved.
  - 3 RAG Apps / Chatflows preserved.
- **Vector Database Integrity:**
  - Weaviate vector engine restored all 3 classes.
  - Dense vectors and HNSW indices online with 100% certainty on GraphQL retrieval.
- **Dify Storage:**
  - 1 Tenant Private Encryption Key (`*.pem`) verified.
  - 22 Uploaded document files verified.
- **Production Isolation:**
  - 100% isolated test; production containers and live database were completely untouched.

