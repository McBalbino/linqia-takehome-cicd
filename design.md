# CI/CD Design — Linqia Take-Home (Docker Hub)

A minimal, **working** CI/CD plan using **Docker Hub** as the public image registry. It covers linting, tests with coverage, **image build & push**, a **security scan**, and a mocked deployment that runs the image in GitHub Actions and reports back to the PR.

---

## 1) Objectives & Scope

- **CI** (on push/PR to `main`)
  - Lint Python code (**flake8**).
  - Run unit tests with coverage and **enforce a threshold (≥ 80%)**.
  - Build Docker image tagged with **branch** and **commit SHA**.
  - Push the image to **Docker Hub**.
  - **Security-scan** the pushed image with **Trivy** (SARIF upload + blocking table scan).
  - Upload test/coverage artifacts.
  - Comment on the PR with results and image links.

- **CD** (after successful CI)
  - Pull the exact image from Docker Hub (prefer `:<branch>`, fallback `:<sha>`).
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
  - `:<branch>` (e.g., `:main`)
  - `:<sha>` (immutable)
- **CD selection:** prefer `:<branch>`, fallback to `:<sha>`.

**Required GitHub Secrets**
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

### A) `test-matrix` (Python 3.10, 3.11, 3.12)
1. **Checkout**
2. **Setup Python** with **pip cache** (`actions/setup-python@v5`, `cache: pip`, `cache-dependency-path: requirements.txt`)
3. **Install**: `flake8 pytest pytest-cov` (+ project deps via `requirements.txt` if any)
4. **Lint**: flake8
   - Blocking syntax/undefined names
   - Soft style pass
5. **Tests**: `pytest -q`

### B) `coverage` (single version, 3.12)
1. **Setup Python** with pip cache
2. **Install**: `pytest pytest-cov`
3. **Run tests w/ coverage + JUnit**
   - outputs: `test-results.xml`, `coverage.xml`
4. **Parse & enforce coverage ≥ 80%**
5. **Upload artifacts**: `test-results.xml`, `coverage.xml`

### C) `docker` (needs: `test-matrix`, `coverage`)
1. **Docker Hub login**
2. **Build & push** with Buildx
   - tags: `:<branch>` and `:<sha>`
   - cache: `type=gha`
3. **Trivy security scan**
   - **SARIF** (non-blocking) → upload to **Code Scanning** + artifact
   - **Table scan (blocking)** with `exit-code: 1` on **HIGH/CRITICAL**
4. **PR comment** (image tags, coverage from prior job, artifacts, run URL)

**Quality gates (CI)**
- Lint/tests/coverage must pass before image build/push.
- Trivy table scan **blocks** on HIGH/CRITICAL (can be relaxed later if needed).

---

## 6) CD Workflow (Mock Deploy)

**Trigger**
- `on: workflow_run` for the CI workflow (types: `completed`), only when `conclusion == success`.

**Permissions**
- `contents: read`, `pull-requests: write`.

**Flow**
1. **Docker Hub login**
2. **Pull image** `docker.io/<user>/<repo>:<branch>`; if missing, pull `:<sha>`
3. **Mock deploy**
   - Run container; ENTRYPOINT already runs the module, so pass only `2 3`
   - Capture output and exit code; **assert** output is `5` and exit is `0`
4. **PR comment** (always, if a PR exists)
   - ✅/❌ status, pulled tag, output & exit code

---

## 7) Dockerfile 

```dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1     PIP_NO_CACHE_DIR=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

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
  - **SARIF** uploaded to Code Scanning (non-blocking)
  - **Blocking** table scan with `exit-code: 1` on HIGH/CRITICAL
- Future hardening (optional):
  - Pin base images; use `python:3.12-slim@sha256:<digest>`
  - Multi-stage build; non-root user
  - SBOM/provenance (Syft/CycloneDX, SLSA)
  - `pip-audit` for Python deps

---

## 9) Caching & Artifacts

- **pip cache** via `actions/setup-python@v5` + `requirements.txt`.
- **Buildx cache**: `type=gha`.
- **Artifacts**: `test-results.xml`, `coverage.xml`, `trivy-results.sarif`.

---

## 10) PR Comments

- **CI comment**: lint/tests ✅, coverage %, image tags (branch + sha), artifacts, run link.
- **CD comment**: deploy status, pulled tag, output & exit code.

(Implemented with `actions/github-script`.)

---

## 11) Branch Protection (optional)

- Require successful checks: `Lint & Test`, `Tests + Coverage`, `Build & Push`.
- Require PR review; disallow force-push to `main`.

---

## 12) Local Validation (optional)

```bash
pytest -q --cov=sample_app
docker build -t <user>/<repo>:dev .
docker run --rm <user>/<repo>:dev 2 3   # should print 5
```

---

## 13) Troubleshooting

- **Cannot push**: check `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` and repo/name.
- **CD can’t pull**: confirm CI pushed both `<branch>` and `<sha>` tags.
- **Container exit 2**: ensure ENTRYPOINT is `["python","-m","sample_app"]` and CD passes only `2 3`.
- **No PR comment**: ensure `pull-requests: write` and that a PR exists for the commit.

---

## 14) Future Improvements

- Aggregate matrix coverage into a single number.
- Multi-arch images (amd64/arm64).
- Pre-commit hooks (ruff/black/isort/mypy) if desired.
- Deploy to a real environment (e.g., ephemeral container or k8s job).

---

## 15) Acceptance Checklist

- [ ] CI runs on push/PR to `main`.
- [ ] Lint, tests, coverage (≥ 80%) enforced.
- [ ] Artifacts uploaded (JUnit + coverage).
- [ ] Docker image built & pushed to **Docker Hub** with `<branch>` + `<sha>` tags.
- [ ] Trivy scan run; **fails** on HIGH/CRITICAL; SARIF uploaded.
- [ ] CI posts a PR comment with results and image links.
- [ ] CD triggers only after successful CI, pulls same image, runs app, and comments status.
- [ ] `design.md`, `Dockerfile`, `ci.yml`, `cd.yml` present in repo.