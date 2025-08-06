# Package Verification Workflows

This document describes the automated verification workflows for Liquibase package availability in external package managers like Homebrew and SDKMAN.

## Overview

The build system includes automated verification for:

- **Homebrew** formula pull requests and package availability
- **SDKMAN** package availability and version synchronization
- **Debian packages** (.deb) availability at repo.liquibase.com
- **RPM packages** (.rpm) availability at repo.liquibase.com

These workflows help maintain visibility of the release process and automatically verify that packages are available after deployment.

## Workflow: `.github/workflows/verify-package-availability.yml`

This workflow verifies the availability of Liquibase packages across different package managers after a release.

### Trigger Conditions

The workflow runs:

- **After Linux packaging workflow completes** (`workflow_run`)
- **Daily at midnight UTC** via scheduled cron (`schedule`)
- **Manual dispatch** for testing (`workflow_dispatch`)

## Homebrew Package Verification

### Homebrew Verification Overview

The Homebrew verification process tracks pull requests submitted to the `Homebrew/homebrew-core` repository and verifies when they are merged.

### Detailed Homebrew Process Flow

1. **Placeholder Branch Detection**
   - Checks for placeholder branches starting with `ci-oss-homebrew-package-check-*` in the liquibase/liquibase repository
   - Extracts the Homebrew PR number from the branch name
   - Only proceeds with verification if a placeholder branch exists

2. **Homebrew PR Status Check**
   - Queries the GitHub API to check the status of the Homebrew PR
   - Uses the PR number extracted from the placeholder branch
   - Checks if the PR is still open or has been closed/merged

3. **Cleanup and Notification**
   - If PR is closed/merged:
     - Deletes the placeholder branch
     - Sends success notification to Slack
   - If PR is still open:
     - Keeps the placeholder branch
     - Sends pending notification to Slack

### Homebrew Technical Details

- **Repository**: `Homebrew/homebrew-core`
- **API**: GitHub REST API for PR status checks
- **Tracking**: Placeholder branches in liquibase/liquibase repository
- **Notification**: Slack notifications for status updates

## SDKMAN Package Verification

### SDKMAN Verification Overview

The SDKMAN verification process checks if the latest Liquibase version is available on SDKMAN after deployment.

### Detailed SDKMAN Process Flow

1. **Placeholder Branch Detection**
   - Checks for the `ci-oss-sdkman-package-check` branch in the liquibase/liquibase repository
   - Only proceeds with verification if the placeholder branch exists

2. **SDKMAN CLI Installation**
   - Installs SDKMAN CLI on the runner
   - Initializes SDKMAN environment for package queries

3. **Version Comparison**
   - Fetches the latest GitHub release version
   - Queries SDKMAN for available Liquibase versions using `sdk list liquibase`
   - Checks if the GitHub version exists in SDKMAN using exact match (`grep -w`)

4. **Cleanup and Notification**
   - If version is available on SDKMAN:
     - Deletes the placeholder branch
     - Sends success notification to Slack
   - If version is not available:
     - Keeps the placeholder branch
     - Sends pending notification to Slack

### SDKMAN Technical Details

- **API**: SDKMAN CLI (`sdk list liquibase`)
- **Version Check**: Exact word matching with `grep -w`
- **Tracking**: Placeholder branch `ci-oss-sdkman-package-check`
- **Notification**: Slack notifications for availability status

## Version Detection Logic

### For Scheduled/Manual Runs

When the workflow runs on schedule or manual dispatch:

```bash
# Fetch latest GitHub release
LATEST_VERSION=$(curl -s "https://api.github.com/repos/liquibase/liquibase/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
```

### For Workflow Run Triggers

When triggered by the Linux packaging workflow completion, the version is determined from the completed workflow context.

## Notification System

### Slack Notifications

The workflow sends notifications to Slack for:

#### Homebrew Notifications

- **Success**: When Homebrew PR is merged and package is available
- **Pending**: When Homebrew PR is still under review

#### SDKMAN Notifications

- **Success**: When SDKMAN package is available and matches GitHub version
- **Pending**: When SDKMAN package is not yet available

### Notification Details

- **Channel**: Uses `LIQUIBASE_PACKAGE_DEPLOY_STATUS_WEBHOOK` secret
- **Format**: Color-coded messages (green for success, yellow for pending)
- **Content**: Version information and package manager status

## Placeholder Branch System

### Purpose

Placeholder branches serve as triggers and state indicators for package verification:

### Homebrew Placeholder Branches

- **Format**: `ci-oss-homebrew-package-check-{PR_NUMBER}`
- **Created by**: Main packaging workflow when Homebrew PR is submitted
- **Deleted when**: Homebrew PR is merged or closed

### SDKMAN Placeholder Branch

- **Name**: `ci-oss-sdkman-package-check`
- **Created by**: Main packaging workflow after SDKMAN deployment
- **Deleted when**: SDKMAN package is verified as available

## Debian Package Verification

### Debian Package Overview

The Debian package verification process checks if the latest Liquibase version is available as a .deb package at repo.liquibase.com after deployment.

### Debian Package Process Flow

1. **Version Detection**
   - Fetches the latest Liquibase version from GitHub releases API
   - Uses the version to construct the expected package path

2. **AWS Credentials Configuration**
   - Configures AWS credentials for S3 access using vault secrets
   - Uses `LIQUIBASE_VAULT_OIDC_ROLE_ARN` for vault access
   - Applies production S3 access role for bucket operations

3. **Primary S3 Check**
   - Verifies package existence directly in S3 bucket: `s3://repo.liquibase.com/pool/main/l/liquibase/liquibase_{VERSION}_all.deb`
   - Uses `aws s3 ls` command for efficient existence check
   - Follows Debian repository pool structure conventions

4. **Fallback URL Check**
   - If S3 check fails, attempts verification via public URL
   - Checks: `https://repo.liquibase.com/pool/main/l/liquibase/liquibase_{VERSION}_all.deb`
   - Uses HTTP HEAD request to avoid downloading the package

5. **Notification**
   - Sends Slack notification with package availability status
   - Always runs to ensure notifications are sent regardless of check results

### Debian Package Technical Details

- **Storage**: S3-backed Nexus repository at repo.liquibase.com
- **Path Structure**: `/pool/main/l/liquibase/` (Debian repository conventions)
- **Package Format**: `liquibase_{VERSION}_all.deb`
- **Verification**: Direct S3 access with public URL fallback

## RPM Package Verification

### RPM Package Overview

The RPM package verification process checks if the latest Liquibase version is available as a .rpm package at repo.liquibase.com after deployment.

### RPM Package Process Flow

1. **Version Detection**
   - Fetches the latest Liquibase version from GitHub releases API
   - Uses the version to construct the expected package path

2. **AWS Credentials Configuration**
   - Configures AWS credentials for S3 access using vault secrets
   - Uses `LIQUIBASE_VAULT_OIDC_ROLE_ARN` for vault access
   - Applies production S3 access role for bucket operations

3. **Primary S3 Check**
   - Verifies package existence directly in S3 bucket: `s3://repo.liquibase.com/yum/noarch/liquibase-{VERSION}-1.noarch.rpm`
   - Uses `aws s3 ls` command for efficient existence check
   - Follows YUM repository structure conventions

4. **Fallback URL Check**
   - If S3 check fails, attempts verification via public URL
   - Checks: `https://repo.liquibase.com/yum/noarch/liquibase-{VERSION}-1.noarch.rpm`
   - Uses HTTP HEAD request to avoid downloading the package

5. **Notification**
   - Sends Slack notification with package availability status
   - Always runs to ensure notifications are sent regardless of check results

### RPM Package Technical Details

- **Storage**: S3-backed Nexus repository at repo.liquibase.com
- **Path Structure**: `/yum/noarch/` (YUM repository conventions)
- **Package Format**: `liquibase-{VERSION}-1.noarch.rpm`
- **Verification**: Direct S3 access with public URL fallback
