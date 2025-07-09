# Release Tracking Workflows

This document describes the automated tracking workflows for Liquibase releases to Homebrew and SDKMAN package managers.

## Overview

The build system includes automated tracking for:

- Homebrew formula pull requests
- SDKMAN version releases

These workflows help maintain visibility of the release process and provide notifications when releases are available.

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

#### Key Improvements

- **Fixed GraphQL Query**: Uses proper variable declaration and usage to avoid GitHub API errors
- **PR Number Labeling**: Uses labels to store PR numbers for reliable tracking
- **Simplified Logic**: Focuses on the first open tracking issue (assumes one active release at a time)
- **Daily Schedule**: Reduces API calls while ensuring timely closure
- Closed by: homebrew-pr-tracking.yml workflow

#### Efficiency Features

- No runner waste: Uses scheduled execution instead of long-running jobs
- 24-hour minimum age: Only checks PRs that have had time to be processed
- Batch processing: Handles multiple tracking issues in a single run

## SDKMAN Release Tracking

### Workflow: `.github/workflows/sdkman-release-tracking.yml`

This workflow checks the availability of new Liquibase versions on SDKMAN and sends Slack notifications.

#### Process Flow

1. When a new Liquibase version is released, the `package.yml` workflow:
   - Uploads the release to SDKMAN
   - Calls the `sdkman-release-tracking.yml` workflow to check availability

2. The `sdkman-release-tracking.yml` workflow:
   - Checks the SDKMAN website for the specified version
   - Sends a Slack notification with the result (available or not yet available)

#### Features

- No tracking issues created (simplified approach)
- Direct check against https://sdkman.io/sdks/ website
- Immediate Slack notification with status
- Can be triggered manually via workflow_dispatch

## Notifications

Both workflows send notifications to Slack when:

- PRs are merged (Homebrew)
- Versions are checked for availability (SDKMAN)
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

3. **SDKMAN Check Fails**
   - Check if the SDKMAN website is accessible
   - Verify the version format matches expectations

### Manual Intervention

If needed, you can:

1. Manually close Homebrew tracking issues
2. Trigger workflows using workflow_dispatch
3. Check workflow runs for detailed logs and error messages

## Related Files

- `.github/workflows/package.yml` - Main packaging workflow
- `.github/workflows/homebrew-pr-tracking.yml` - Homebrew tracking workflow
- `.github/workflows/sdkman-release-tracking.yml` - SDKMAN tracking workflow
