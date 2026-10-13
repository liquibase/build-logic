# Claude Code Workflows

This directory contains reusable workflows for integrating Anthropic's Claude Code AI assistant into repository workflows.

## Available Workflows

### 1. `claude-code-review.yml` - Automatic PR Code Review

Automatically reviews pull requests using Claude Code and provides feedback via PR comments.

**Triggers:** Pull request opened or synchronized

**Usage:**
```yaml
# .github/workflows/claude-code-review.yml
name: Claude Code Review
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  claude-review:
    uses: liquibase/build-logic/.github/workflows/claude-code-review.yml@main
```

**Bot PR exclusion:** Bot-authored PRs (dependabot, renovate, etc.) are excluded from auto-review by default. The reusable workflow exposes an optional `allowed_bots` input (default: `""`) that is passed through to `claude-code-action`. To allow specific bots, pass `allowed_bots` from the caller workflow:

```yaml
jobs:
  claude-review:
    uses: liquibase/build-logic/.github/workflows/claude-code-review.yml@main
    with:
      allowed_bots: 'dependabot[bot]'
```

Humans can still `@claude` on any bot PR via the `claude.yml` mention workflow if a review is needed.

**Model selection:** By default this workflow uses `claude-haiku-4-5` (~75% cheaper than Sonnet) which is sufficient for structured code review tasks. The model is set via `--model` in `claude_args`. Note: `#` comment lines in `claude_args` are parsed by `shell-quote` as comment characters and will cause all subsequent flags to be silently dropped ([upstream issue #802](https://github.com/anthropics/claude-code-action/issues/802)) — avoid using `#` comments inside `claude_args`. High-value repositories that need deeper reasoning can opt into Sonnet:

```yaml
jobs:
  claude-review:
    uses: liquibase/build-logic/.github/workflows/claude-code-review.yml@main
    with:
      model: 'claude-sonnet-4-6'
```

| Model                        | Input      | Output   | Use case                              |
|------------------------------|------------|----------|---------------------------------------|
| `claude-haiku-4-5` (default) | $0.80/MTok | $4/MTok  | Standard automated reviews            |
| `claude-sonnet-4-6`          | $3/MTok    | $15/MTok | Complex repos needing deeper analysis |

**What it does:**
- Reviews code changes in the PR with a rigorous senior-reviewer persona (see the
  [NTT-572 prompt hardening write-up](./NTT-572-pr-review-prompt-hardening.md))
- Runs a two-pass review: pass 1 for correctness and safety, pass 2 for
  maintainability and repo standards (CLAUDE.md)
- Works through an explicit checklist (correctness, error handling, security, tests,
  API/contract stability, concurrency/resources, repo standards) internally - the
  checklist is a thinking aid and is deliberately not written into the review
- Labels every finding by severity: `[Critical]` / `[Major]` / `[Minor]` / `[Nit]`.
  This set is closed - there is no `[Positive]` or equivalent label
- Comments only on defects: no praise, approval or "this is correct" comments, and no
  "Positive Findings" / "Strengths" sections
- Ends each review with a 0-100% production-readiness confidence score and justification
- Does not default to "LGTM"; it must justify approval against the checklist
- Applies false-positive guards so added rigor does not flood PRs with noise
- Collapses its own prior comments as OUTDATED once a new review has been posted -
  both the PR-level summaries and the inline review comments - so a busy PR shows only
  the latest review expanded. A failed or timed-out review leaves the previous one
  visible

### 2. `claude.yml` - @claude Mention Handler

Responds to @claude mentions in issues, PR comments, and PR reviews to provide AI-powered assistance.

**Triggers:** Issue comments, PR review comments, issues, PR reviews

**Usage:**
```yaml
# .github/workflows/claude.yml
name: Claude Code
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  issues:
    types: [opened, assigned]
  pull_request_review:
    types: [submitted]

jobs:
  claude:
    # Only run when @claude is mentioned
    if: |
      (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'pull_request_review' && contains(github.event.review.body, '@claude')) ||
      (github.event_name == 'issues' && (contains(github.event.issue.body, '@claude') || contains(github.event.issue.title, '@claude')))
    uses: liquibase/build-logic/.github/workflows/claude.yml@main
```

**Model selection:** Defaults to `claude-sonnet-4-6` since interactive tasks require stronger reasoning. Override with the `model` input if needed.

**What it does:**
- Responds to natural language requests in comments
- Can read code, review changes, answer questions
- Has access to repository context and CI/CD results
- Can interact with GitHub API via `gh` CLI

### 3. `claude-test-review.yml` - Automatic PR Test Quality Review

Reviews test files changed in a PR and flags low-value or problematic tests.

**Triggers:** Pull request opened or synchronized (test files only)

**Usage:**
```yaml
# .github/workflows/claude-test-review.yml
name: Claude Test Review
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  claude-test-review:
    uses: liquibase/build-logic/.github/workflows/claude-test-review.yml@main
```

**Model selection:** By default uses `claude-haiku-4-5`. Override with `model` input to use Sonnet for complex test suites.

**What it does:**
- Reviews only test files changed in the PR
- Flags bogus, tautological, or brittle tests
- Identifies over-mocking, missing assertions, and async anti-patterns
- Silent pass (no comment) when no issues are found

## Requirements

### Authentication: workload identity federation

The workflows authenticate to the Claude API with [workload identity federation](https://platform.claude.com/docs/en/manage-claude/wif-providers/github-actions), not a stored API key. `claude-code-action` exchanges the job's GitHub OIDC token for a short-lived Claude API token. Nothing is read from AWS Secrets Manager and the workflows use no secrets, so `secrets: inherit` is not needed (existing callers that pass it are unaffected).

The federation rule in the Claude Console (**Settings → Workload identity**) accepts a token only when both of these hold:

- `job_workflow_ref` is one of the three workflows in this directory at `refs/heads/main`.
- `repository_owner_id` is the `liquibase` org (`438548`) or the `Datical` org (`1992825`). build-logic is public, so any repository on GitHub can call these workflows; this claim is what limits the rule to our callers. The numeric ID is used because it survives an org rename.

A caller that pins a branch, tag or SHA instead of `@main` gets `401 Authentication failed` until that ref is added to the rule. The reason for any denied exchange is on the Console's authentication history page.

### Testing changes to these workflows

Because the rule accepts only `refs/heads/main`, a caller pointed at a feature branch gets `401` until the branch is allowed:

1. In the Console, add the three workflows at `@refs/heads/<your-branch>` to the `job_workflow_ref` list in the rule's condition.
2. In a caller repo, open a test PR that points the caller at your branch (`uses: liquibase/build-logic/.github/workflows/claude-code-review.yml@<your-branch>`), and link the runs from your build-logic PR.
3. Remove the branch refs from the rule once your PR merges.

`claude-code-review.yml` and `claude-test-review.yml` run on the test PR itself. For `claude.yml`, mention `@claude` in a **review comment** on the test PR: `pull_request_review` and `pull_request_review_comment` run the caller workflow from the PR, whereas a plain PR conversation comment (`issue_comment`) and `issues` events always run it from the caller's default branch.

## Permissions

All three workflows require the following permissions:
- `contents: read` - Read repository code
- `pull-requests: write` - Comment on PRs
- `issues: write` - Comment on issues, and collapse a review workflow's own stale comments
- `id-token: write` - GitHub OIDC token, exchanged for the Claude GitHub App token and, through workload identity federation, for the Claude API token
- `actions: read`, `checks: read`, `statuses: read` - Read CI/CD results for the `mcp__github_ci__*` tools

A called workflow cannot raise the permissions its caller passes down, so a caller with its own `permissions:` block must grant all of these, `id-token: write` included, or the run fails at startup:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write
  actions: read
  checks: read
  statuses: read
```

## Configuration

### Repository-Specific Instructions

Create a `CLAUDE.md` file in your repository root to provide Claude with repository-specific context, coding standards, and conventions. This file will be automatically loaded by Claude.

Example `CLAUDE.md`:
```markdown
# Repository Guidelines

## Code Style
- Use TypeScript strict mode
- Follow ESLint configuration
- Write comprehensive tests

## Architecture
- Follow MVC pattern
- Keep controllers thin
- Use dependency injection
```

## Related

- LAI-51: Evaluate AI Code Reviewers for PR Workflow Integration
- [Claude Code Documentation](https://docs.claude.com/en/docs/claude-code)
- [Claude Code GitHub Action](https://github.com/anthropics/claude-code-action)
