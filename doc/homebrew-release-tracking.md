# Release Tracking Workflows

This document describes the automated tracking workflows for Liquibase releases to Homebrew package managers.

## Overview

The build system includes automated tracking for:

- Homebrew formula pull requests

This workflows help maintain visibility of the release process and automatically close tracking issues once release is available.

## Homebrew PR Tracking

### Workflow: `.github/workflows/homebrew-pr-tracking.yml`

This workflow tracks the status of Homebrew formula pull requests for Liquibase releases.

#### Process Flow

1. When a new Liquibase version is released, the `package.yml` workflow:
   - Creates a PR in Homebrew/homebrew-core to update the Liquibase formula
   - Captures the PR details using an improved GraphQL query with proper variable usage
   - Creates a tracking issue in liquibase/liquibase repository with:
     - Standard `homebrew-tracking` label
     - PR-specific label (e.g., `PR-12345`) containing the PR number for easy identification
   - Issue body contains PR URL, version, and creation timestamp

2. The `homebrew-pr-tracking.yml` workflow:
   - Runs daily at midnight UTC via scheduled cron
   - Finds open tracking issues with `homebrew-tracking` label
   - Extracts PR number from the PR-specific label (e.g., `PR-12345`)
   - Checks the status of the corresponding Homebrew PR
   - If PR is closed/merged:
     - Closes the tracking issue
     - Sends Slack notification about successful closure
   - If PR is still open, logs status and waits for next scheduled run

#### Tracking Details

- Location: liquibase/liquibase repository
- Labels: 
  - `homebrew-tracking` (for identification)
  - `PR-{number}` (for PR number extraction)
- Created by: package.yml workflow
- Checked by: homebrew-pr-tracking.yml workflow (daily at midnight UTC)
- Closed by: homebrew-pr-tracking.yml workflow

#### Efficiency Features

- No runner waste: Uses scheduled execution instead of long-running jobs
- 24-hour minimum age: Only checks PRs that have had time to be processed
- Batch processing: Handles multiple tracking issues in a single run

## Notifications

The workflow send notifications to Slack when:

- Issue is closed (Homebrew)
- Any errors occur during tracking

## Troubleshooting

### Common Issues

1. **Homebrew Tracking Issue Not Closed**
   - Check if the PR is actually merged
   - Verify the issue has the correct tracking label
   - Check workflow logs for any errors

2. **Missing Slack Notifications**
   - Verify Slack webhook configurations
   - Check workflow permissions and secrets

### Manual Intervention

If needed, you can:

1. Manually close Homebrew tracking issues
2. Trigger workflows using workflow_dispatch
3. Check workflow runs for detailed logs and error messages

## Related Files

- `.github/workflows/package.yml` - Main packaging workflow
- `.github/workflows/homebrew-pr-tracking.yml` - Homebrew tracking workflow
