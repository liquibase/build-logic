# Repository Guidelines

This repository centralizes reusable GitHub Actions that power Liquibase extension builds, tests, and releases. Changes here propagate to dozens of downstream projects, so favor incremental updates, strong validation, and backward compatibility.

## Project Structure & Module Organization
- `.github/workflows/` holds the reusable pipelines (e.g., `os-extension-test.yml`, `package.yml`, `extension-release-prepare.yml`) called via `uses: liquibase/build-logic/.github/workflows/{file}@ref`.
- `.github/actions/` contains composite setup actions such as `setup-aws-vault` and `setup-google-credentials`; extend these rather than duplicating boilerplate in workflows.
- `.github/*.sh` scripts sign, package, and upload artifacts—keep them POSIX-compliant and idempotent.
- `src/liquibase/` stores Debian package scaffolding consumed by the packaging workflows.
- `doc/` captures operational runbooks; update the paired markdown when workflow behavior changes.

## Build, Test, and Development Commands
- `brew install actionlint` and `actionlint .github/workflows/*.yml` to lint every workflow before opening a PR.
- For local smoke tests, run `act -W .github/workflows/os-extension-test.yml` with mocked secrets in `.secrets`; target smaller matrices to keep runs fast.
- When validating end-to-end behavior, point a calling repo to your branch (`uses: liquibase/build-logic/.github/workflows/os-extension-test.yml@feature/foo`) and trigger the workflow there.

## Coding Style & Naming Conventions
- Use two-space indentation in YAML; job and step ids are lower-kebab-case, environment variables remain UPPER_SNAKE_CASE.
- Shell scripts should target Bash (`#!/usr/bin/env bash`), enable `set -euo pipefail`, and prefer functions over inline repetition.
- Keep workflow inputs descriptive and defaulted; document new inputs at the top of each file.

## Testing Guidelines
- Treat every workflow change as production code: run `actionlint`, execute representative `act` scenarios, and capture logs from a consuming repository.
- Matrix expansions must maintain historical defaults; add new permutations behind opt-in inputs when possible.
- For packaging changes, dry-run against `src/liquibase` assets and verify generated artifacts remain in expected paths.

## Commit & Pull Request Guidelines
- Follow the existing history: either `TYPE: summary` (e.g., `fix: update deb signing`) or `{TICKET} :: summary` when referencing Jira (`DAT-20906 :: ...`).
- Squash local fixups before pushing; PR titles should mirror the commit headline and link to the upstream ticket or issue.
- Include a short checklist in the PR description: linters run, downstream repo tested (with link), docs updated. Attach failure screenshots or logs when addressing regressions.

## Security & Secrets Handling
- Never hard-code credentials; rely on AWS Secrets Manager (`/vault/liquibase`) and the GitHub App tokens already wired into composites.
- Review permission blocks whenever touching workflows—scope tokens with the minimal `permissions` set and audit any new `id-token` usage.
