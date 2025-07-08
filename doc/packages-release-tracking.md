# Release Tracking Workflows

This document describes the automated tracking workflows for Liquibase releases to Homebrew and SDKMAN package managers.

## Overview

The build system includes automated tracking for:

- Homebrew formula pull requests
- SDKMAN version releases

These workflows help maintain visibility of the release process and automatically close tracking issues once releases are available.

## Homebrew PR Tracking

### Workflow: `.github/workflows/homebrew-pr-tracking.yml`

This workflow tracks the status of Homebrew formula pull requests for Liquibase releases.

#### Process Flow

1. When a new Liquibase version is released, the `package.yml` workflow:
   - Creates a PR in Homebrew/homebrew-core to update the Liquibase formula
   - Creates a tracking issue in liquibase/liquibase repository
   - Adds a comment on the Homebrew PR linking to the tracking issue

2. The `homebrew-pr-tracking.yml` workflow:
   - Runs periodically to check the status of open Homebrew PRs
   - When a PR is merged, it:
     - Closes the corresponding tracking issue
     - Sends a Slack notification about the successful merge

#### Homebrew Tracking Details

- Location: liquibase/liquibase repository
- Label: `homebrew-tracking`
- Created by: package.yml workflow
- Closed by: homebrew-pr-tracking.yml workflow

## SDKMAN Release Tracking

### Workflow: `.github/workflows/sdkman-release-tracking.yml`

This workflow tracks the availability of new Liquibase versions on SDKMAN.

#### SDKMAN Process Flow

1. When a new Liquibase version is released, the `package.yml` workflow:
   - Uploads the release to SDKMAN
   - Creates a tracking issue in the appropriate repository
   - Labels the issue with `sdkman-tracking`

2. The `sdkman-release-tracking.yml` workflow:
   - Runs periodically to check SDKMAN for the new version
   - When the version is available, it:
     - Closes the corresponding tracking issue
     - Sends a Slack notification confirming availability

#### SDKMAN Tracking Details

- Location:
  - Production releases: liquibase/liquibase repository
  - Dry-run releases: build-logic repository
- Label: `sdkman-tracking`
- Created by: package.yml workflow
- Closed by: sdkman-release-tracking.yml workflow

## Notifications

Both workflows send notifications to Slack when:

- PRs are merged (Homebrew)
- Versions become available (SDKMAN)
- Any errors occur during tracking

## Troubleshooting

### Common Issues

1. **Tracking Issue Not Closed**
   - Check if the PR/version is actually merged/available
   - Verify the issue has the correct tracking label
   - Check workflow logs for any errors

2. **Missing Slack Notifications**
   - Verify Slack webhook configurations
   - Check workflow permissions and secrets

### Manual Intervention

If needed, you can:

1. Manually close tracking issues
2. Trigger workflows using workflow_dispatch
3. Check workflow runs for detailed logs and error messages

## Related Files

- `.github/workflows/package.yml` - Main packaging workflow
- `.github/workflows/homebrew-pr-tracking.yml` - Homebrew tracking workflow
- `.github/workflows/sdkman-release-tracking.yml` - SDKMAN tracking workflow
