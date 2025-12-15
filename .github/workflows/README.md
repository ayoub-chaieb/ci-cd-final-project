# CI Workflow — GitHub Actions (`.github/workflows/workflow.yaml`)
This directory will contain all the GitHub Action workflows you create in the CI/CD Tools and Practices Final Project.

**Status:** ✅ Implemented — automated CI that lints and tests the Python service on every push and pull request to `main`.

This repository contains a GitHub Actions workflow that continuously validates your Python code quality and unit tests. The pipeline enforces style and correctness using **flake8** and test coverage using **nose**.

---

## What this workflow does (high level)

Triggered on:

* `push` to `main`
* `pull_request` targeting `main`

Job: `build` (single job)

* Runs on `ubuntu-latest`
* Uses container image `python:3.9-slim` for a clean, reproducible environment
* Steps:

  1. Checkout the repo (`actions/checkout@v3`)
  2. Install project dependencies from `requirements.txt`
  3. Run **flake8** linting (two passes: hard errors + style/complexity rules)
  4. Run unit tests with **nose**, collecting coverage for the `app` package

All steps are strict: any non-zero exit code (lint or tests fail) will mark the workflow as failed.

---

## `workflow.yaml` (reference)

```yaml
name: CI workflow

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: python:3.9-slim
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt
      - name: Lint with flake8
        run: |
          flake8 service --count --select=E9,F63,F7,F82 --show-source --statistics
          flake8 service --count --max-complexity=10 --max-line-length=127 --statistics
      - name: Run unit tests with nose
        run: |
          nosetests -v --with-spec --spec-color --with-coverage --cover-package=app
```

---

## How to run the same checks locally

Run the exact commands locally to reproduce the CI checks:

1. Create & activate a virtual environment (recommended)

```bash
python3 -m venv .venv
source .venv/bin/activate
```

2. Upgrade pip and install dependencies

```bash
python -m pip install --upgrade pip
pip install -r requirements.txt
```

3. Lint with flake8 (same commands used by CI)

```bash
flake8 service --count --select=E9,F63,F7,F82 --show-source --statistics
flake8 service --count --max-complexity=10 --max-line-length=127 --statistics
```

4. Run tests with nose (and coverage)

```bash
nosetests -v --with-spec --spec-color --with-coverage --cover-package=app
```

Alternative (docker): if you prefer the exact container environment used by CI:

```bash
docker run --rm -v "$PWD":/src -w /src python:3.9-slim bash -lc \
  "python -m pip install --upgrade pip && pip install -r requirements.txt && \
   flake8 service --count --select=E9,F63,F7,F82 --show-source --statistics && \
   flake8 service --count --max-complexity=10 --max-line-length=127 --statistics && \
   nosetests -v --with-spec --spec-color --with-coverage --cover-package=app"
```

---

## Expected behavior / failure modes

* **flake8** first command (`--select=E9,F63,F7,F82`) targets fatal errors and likely crashes; its failure usually indicates syntax/runtime issues or import-time errors.
* **flake8** second command enforces style and complexity (max complexity = 10, max line length = 127). Violations produce non-zero exit code and fail the workflow.
* **nosetests** returns non-zero when tests fail or an error occurs. Coverage output is shown in the logs.

If the workflow fails on CI, reproduce locally with the commands above to iterate quickly.

---

## Adding speed & robustness (recommended enhancements)

1. **Cache pip dependencies** to avoid re-installing every run:

```yaml
- name: Cache pip
  uses: actions/cache@v4
  with:
    path: ~/.cache/pip
    key: ${{ runner.os }}-pip-${{ hashFiles('**/requirements.txt') }}
    restore-keys: |
      ${{ runner.os }}-pip-
```

2. **Upload coverage/artifacts** for visibility:

* Use `actions/upload-artifact` to store coverage reports.
* Use `codecov/codecov-action` to upload coverage to Codecov.

3. **Break into matrix or parallel jobs**

* Run lint and tests in separate jobs to get faster feedback and clearer status.

4. **Use `pytest` for richer test features** (optional, if migrating from `nose`).

---

## Badge (status) for README

Add a status badge to the repository README (replace `<owner>` and `<repo>`):

```markdown
![CI](https://github.com/ayoub-chaieb/ci-cd-final-project/actions/workflows/workflow.yaml/badge.svg)
```

This will show the latest build status for that workflow file.

---

## Troubleshooting tips

* If `flake8` cannot be found: ensure `requirements.txt` contains `flake8` or install it globally in the container/venv.
* If `nosetests` fails to import modules: check `PYTHONPATH` or package layout (`setup.py` / `src` layout) so tests can `import app`.
* If tests pass locally but fail in CI:

  * Compare Python versions and dependency versions.
  * Check for environment-specific behavior (missing env vars, file system permissions).
* To debug in CI quickly: add a step to print `python --version`, `pip list`, and `pwd` to confirm environment contents.

---

## Summary (what this workflow demonstrates)

* Implemented an automated CI workflow using **GitHub Actions** to enforce:

  * Deterministic test environment with Docker container (Python 3.9)
  * Code quality checks (flake8 with strict rules)
  * Unit testing with coverage (nose)
* Implemented reproducible, local workflows to mirror CI execution
* Knowledgeable about caching, artifacts, and splitting CI into independent jobs for faster feedback

