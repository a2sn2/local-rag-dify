# Git Workflow and Synchronization Protocol

**Official Repository:** `https://github.com/a2sn2/local-rag-dify`  
**Default Branch:** `main`  
**Standard:** Conventional Commits v1.0.0

---

## 1. Core Engineering Workflow

All changes follow a disciplined 7-step engineering cycle:

```
[Plan] ──> [Implement] ──> [Validate] ──> [Commit] ──> [Push] ──> [Verify Remote] ──> [Report]
```

1. **Plan:** Review scope, assess security impact, and identify files to be modified.
2. **Implement:** Execute changes locally, maintaining documentation integrity.
3. **Validate:** Inspect changes, verify tests, and confirm no secrets or sensitive data are staged.
4. **Commit:** Stage approved files explicitly (`git add <file>`) with meaningful conventional commit messages.
5. **Push:** Push commits to `origin/main` (or dedicated feature branches).
6. **Verify Remote:** Query GitHub remote to verify the commit hash is registered and synchronized.
7. **Report:** Deliver concise report with commit hash, modified files, and verification proof.

---

## 2. Commit Message Conventions

We enforce the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>(<scope>): <short imperative description>

[optional detailed body explaining technical reasoning]

[optional footer referencing stage or issue]
```

### Approved Commit Types:
- `feat`: A new feature or component addition (e.g., `feat(rag): add bilingual chunking strategy`).
- `fix`: A bug fix or security correction (e.g., `fix(network): restrict nginx binding to 127.0.0.1`).
- `docs`: Documentation creation or updates (e.g., `docs(arch): document dify 1.18.0 container topology`).
- `chore`: Maintenance, repository setup, or configuration (e.g., `chore(git): initialize stage 0 repository scaffolding`).
- `security`: Security hardening, secret exclusion, or firewall adjustments.
- `test`: Adding or running integration and evaluation tests.

---

## 3. Remote Synchronization & Safety Invariants

1. **Explicit Staging Only:** Never run `git add .` or `git add -A`. Always stage specific, reviewed files (`git add README.md`, `git add docs/`).
2. **Never Force-Push:** Do not run `git push --force` or `--force-with-lease` on shared public branches.
3. **Remote Verification:** After pushing, run `git ls-remote origin` or `git rev-parse origin/main` to confirm the remote repository reflects the local HEAD commit.
4. **Failure Recovery:** If a push fails due to network or authentication issues:
   - Do NOT discard local changes.
   - Report the exact error output to the user.
   - Maintain working tree integrity until connectivity or authentication is restored.
