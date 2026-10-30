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

**Model selection:** By default this workflow uses `haiku`, the alias for the latest Haiku (~97% cheaper than Sonnet) which is sufficient for structured code review tasks. The model is set via `--model` in `claude_args`. Note: `#` comment lines in `claude_args` are parsed by `shell-quote` as comment characters and will cause all subsequent flags to be silently dropped ([upstream issue #802](https://github.com/anthropics/claude-code-action/issues/802)) — avoid using `#` comments inside `claude_args`. High-value repositories that need deeper reasoning can opt into Sonnet:

```yaml
jobs:
  claude-review:
    uses: liquibase/build-logic/.github/workflows/claude-code-review.yml@main
    with:
      model: 'sonnet'
```

| Model                         | Input      | Output     | Use case                              |
|-------------------------------|------------|------------|---------------------------------------|
| `haiku` (default, Haiku 5.5)  | $0.10/MTok | $0.50/MTok | Standard automated reviews            |
| `sonnet` (Sonnet 5.5)         | $2/MTok    | $10/MTok   | Complex repos needing deeper analysis |

The aliases resolve to the latest model the Claude Code CLI bundled in `claude-code-action` knows, so a new model arrives with the action bump, without a change here. Pass a full model ID to pin one.

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

**Model selection:** Defaults to `sonnet`, the latest Sonnet, since interactive tasks require stronger reasoning. Override with the `model` input if needed.

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

**Model selection:** By default uses `haiku`, the latest Haiku. Override with `model` input to use Sonnet for complex test suites.

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

The rule lists only `refs/heads/main`. A caller that pins a branch, tag or SHA instead of `@main` gets `401 Authentication failed`. The reason for any denied exchange is on the Console's authentication history page.

The rule is bound to one workspace: create it with `workspace_id`, not `applies_to_all_workspaces`. The workflows send no workspace ID, so a rule enabled in more than one workspace fails every exchange with `workspace_id_required`.

### Testing changes to these workflows

A caller pointed at a feature branch gets `401` from the production rule. Do not add branch refs to it: anyone who can push that branch name to build-logic can change the workflow on it, and every caller in both orgs that points at it would get a token. Use a separate test rule instead:

1. In the Console, create a test rule with the same issuer, service account, workspace, scope and lifetime as the production rule. Its condition lists the three workflows at `@refs/heads/<your-branch>` and pins the test caller repos, for example `claims.repository in ['liquibase/<test-repo>', 'Datical/<test-repo>']`.
2. On your branch, set `anthropic_federation_rule_id` in the three workflows to the test rule's ID.
3. In each test caller repo, point the callers at your branch (`uses: liquibase/build-logic/.github/workflows/claude-code-review.yml@<your-branch>`) on its default branch, then open a test PR that changes no workflow file. `claude-code-action` skips any PR that changes a workflow file, before it reaches the token exchange. Link the runs from your build-logic PR.
4. Before merging, put the production rule's ID back in the three workflows and archive the test rule. A merge that still names the test rule fails every caller, because the test rule accepts only your branch.

`claude-code-review.yml` and `claude-test-review.yml` run on the test PR itself. For `claude.yml`, mention `@claude` in a comment on the test PR. Because the callers point at your branch on the test repo's default branch, review comments, conversation comments and issues all reach it.

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
