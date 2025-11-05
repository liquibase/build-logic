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
    secrets: inherit
```

**What it does:**
- Reviews code changes in the PR
- Checks for code quality and best practices
- Identifies potential bugs or issues
- Evaluates performance and security concerns
- Comments on the PR with constructive feedback

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
    secrets: inherit
```

**What it does:**
- Responds to natural language requests in comments
- Can read code, review changes, answer questions
- Has access to repository context and CI/CD results
- Can interact with GitHub API via `gh` CLI

## Requirements

### Organization-Level Secrets

These workflows require the following organization-level secret:
- `LIQUIBASE_VAULT_OIDC_ROLE_ARN` - AWS IAM role for accessing Secrets Manager

### AWS Secrets Manager

The Anthropic API key must be stored in AWS Secrets Manager at `/vault/liquibase` with the key `ANTHROPIC_API_KEY`.

## Permissions

Both workflows require the following permissions:
- `contents: read` - Read repository code
- `pull-requests: write` - Comment on PRs
- `issues: write` - Comment on issues (claude.yml only)
- `id-token: write` - AWS OIDC authentication
- `actions: read` - Read CI/CD results (claude.yml only)

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
