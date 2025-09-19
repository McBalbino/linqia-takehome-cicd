# CI/CD Design — Linqia Take‑Home (Docker Hub)

A minimal, **working** CI/CD plan using **Docker Hub** as the public image registry. It covers linting, tests with coverage, image build & push, a high‑signal security scan, and a mocked deployment that runs the image in GitHub Actions and reports back to the PR.

---

## 1) Objectives & Scope

- **CI** (on push/PR to `main`)
  - Lint Python code (**flake8**).
  - Run unit tests with coverage and **enforce a threshold (≥ 80%)**.
  - Build Docker image tagged with the **sanitized branch name** and **commit SHA**.
  - Push the image to **Docker Hub**.
  - **Security scan** the image with **Trivy** (SARIF upload + blocking table scan).
  - Upload test/coverage artifacts.
  - Comment on the PR with results and image links.

- **CD** (after successful CI)
  - Pull the exact image from Docker Hub (prefer `:<sanitized-branch>`, fallback `:<sha>`).
  - **Mock deploy** by running the container so it prints `5` for args `2 3`.
  - Comment back to the PR with deployment status.

**Out of scope:** real infra, environments, secret rotation. Kept intentionally simple.

---

## 2) Repo & Runtime Assumptions

- Python package in `sample_app/` with CLI entrypoint.
- Tests in `tests/`.
- A `requirements.txt` (can be empty) exists to enable pip caching and Docker build.
- **Dockerfile** sets the entrypoint to the module:
  ```dockerfile
  ENTRYPOINT ["python", "-m", "sample_app"]
  ```
  Therefore `docker run IMAGE 2 3` prints `5`.

---

## 3) Registry & Tagging (Docker Hub)

- **Registry:** `docker.io`
- **Image repo:** `docker.io/<DOCKERHUB_USERNAME>/<github-repo-name>`
- **Tags produced in CI:**
  - `:<sanitized-branch>` (e.g., `:main`; PR refs like `2/merge` are converted to `2-merge`)
  - `:<sha>` (immutable)
- **Sanitization rule (CI & CD use the same):**
  - Lowercase, replace any char not in `[a-z0-9._-]` with `-`, trim dashes, limit length.
- **CD selection:** prefer `:<sanitized-branch>`, fallback to `:<sha>`.

**GitHub Secrets**
- `DOCKERHUB_USERNAME` — Docker Hub username.
- `DOCKERHUB_TOKEN` — Docker Hub **access token**.

---

## 4) Files in Repo

```
design.md
Dockerfile
.github/workflows/ci.yml
.github/workflows/cd.yml
```

Optional: `.dockerignore` (ignores `.git`, `.github`, caches, etc.).

---

## 5) CI Workflow (GitHub Actions)

**Trigger**
- `on: push` and `on: pull_request` to `main`.

**Permissions**
- `contents: read`, `pull-requests: write`, `security-events: write`, `packages: write`.

**Job topology**
```
test-matrix (3.10, 3.11, 3.12)
            └─> coverage (3.12, artifacts, threshold)
                               └─> docker (build & push, Trivy scans, PR comment)
```

### 5.1 Lint & Test (matrix)
1. **Checkout**
2. **Setup Python** with **pip cache** (`actions/setup-python@v5`, `cache: pip`, `cache-dependency-path: requirements.txt`)
3. **Install**: `flake8 pytest pytest-cov` (+ project deps via `requirements.txt` if any)
4. **Lint**: flake8 (blocking E9/F63/F7/F82, then soft style pass)
5. **Tests**: `pytest -q`

### 5.2 Coverage (3.12) + Artifacts
1. **Install**: `pytest pytest-cov`
2. **Run tests w/ coverage + JUnit**
   ```bash
   pytest -q --maxfail=1 --disable-warnings      --junitxml=test-results.xml      --cov=sample_app --cov-report=xml --cov-report=term
   ```
3. **Parse & enforce coverage ≥ 80%**
4. **Upload artifacts**: `test-results.xml`, `coverage.xml`

### 5.3 Build & Push + Security
1. **Docker Hub login**
2. **Derive repo + compute sanitized branch tag**
3. **Build & push** (Buildx cache: `type=gha`)
   - Tags: `:<sanitized-branch>` and `:<sha>`
4. **Trivy security scans**
   - **SARIF** (non‑blocking) → upload to **Code Scanning** + artifact
   - **Table scan (blocking)** with `exit-code: 1` on **HIGH,CRITICAL**

### 5.4 PR Comment (CI)
- Post a summary with Python versions, coverage %, image tags, Trivy status, artifacts, run URL.

**Failure policy**
- Lint/tests/coverage must pass before image build/push.
- Blocking Trivy scan fails CI on serious vulns.

---

## 6) CD Workflow (Mock Deploy)

**Trigger**
- `on: workflow_run` for the CI workflow (types: `completed`), only when `conclusion == success`.

**Flow**
1. **Compute the same sanitized branch tag** from `workflow_run.head_branch`; keep `head_sha` as fallback.
2. **Docker Hub login**
3. **Pull image** `docker.io/<user>/<repo>:<sanitized-branch>` or fallback to `:<sha>`
4. **Mock deploy**
   - `docker run --rm IMAGE 2 3`
   - Assert output is `5` and exit code is `0`
5. **PR comment (CD)** — ✅/❌ status, pulled image tag, output snippet

---

## 7) Dockerfile (final)

```dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1     PIP_NO_CACHE_DIR=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt || true

COPY sample_app ./sample_app

# Run the CLI module by default; `docker run IMAGE 2 3` → prints 5
ENTRYPOINT ["python", "-m", "sample_app"]
```

Optional `.dockerignore`:
```dockerignore
.git
.github
__pycache__/
*.py[cod]
.env
venv/
dist/
build/
```

---

## 8) Security

- **Image scanning**: Trivy after push
  - **SARIF** uploaded to Code Scanning (non‑blocking)
  - **Blocking** table scan with `exit-code: 1` on HIGH/CRITICAL
- Future hardening (optional):
  - Pin base image digest
  - Multi‑stage build & non‑root user
  - SBOM/provenance (Syft/CycloneDX, SLSA)
  - `pip-audit` for Python deps

---

## 9) Caching & Artifacts

- **pip cache** via `actions/setup-python@v5` + `requirements.txt`.
- **Buildx cache**: `type=gha`.
- **Artifacts**: `test-results.xml`, `coverage.xml`, `trivy-results.sarif`.

---

## 10) PR Comments

- **CI comment**: lint/tests ✅, coverage %, image tags (sanitized branch + sha), artifacts, run link.
- **CD comment**: deploy status, pulled tag, output & exit code.

---

## 11) Branch Protection (optional)

- Require successful checks (Lint & Test, Coverage, Build & Push) before merge.
- Require PR review; disallow force‑push to `main`.

---

## 12) Local Validation (optional)

```bash
pytest -q --cov=sample_app
docker build -t <user>/<repo>:dev .
docker run --rm <user>/<repo>:dev 2 3   # should print 5
```

---

## 13) Troubleshooting

- **Invalid Docker tag** (`2/merge`): sanitize branch before tagging (see §3).
- **Denied push**: confirm `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` and namespace.
- **No PR comment**: ensure a PR exists (CI) or PR is resolvable from `workflow_run` (CD).
- **Coverage not found**: ensure `--cov=sample_app` and that `coverage.xml` is generated.

---

## 14) Future Improvements

- Aggregate matrix coverage into a single number.
- Multi‑arch images (amd64/arm64).
- Pre‑commit hooks (black/isort/ruff/mypy) if desired.
- Deploy to a real environment (e.g., ephemeral container or k8s job).

---

## 15) Acceptance Checklist

- [ ] CI runs on push/PR to `main`.
- [ ] Lint, tests, coverage (≥ 80%) enforced.
- [ ] Artifacts uploaded (JUnit + coverage).
- [ ] Docker image built & pushed to **Docker Hub** with `<sanitized-branch>` + `<sha>` tags.
- [ ] Trivy scan: SARIF uploaded; blocking table scan enforced.
- [ ] CI posts a PR comment with results and image links.
- [ ] CD triggers only after successful CI, pulls same image, runs app, and comments status.
- [ ] `design.md`, `Dockerfile`, `ci.yml`, `cd.yml` present in repo.