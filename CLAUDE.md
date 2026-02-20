# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the Liquibase build-logic repository containing reusable GitHub Actions workflows for building, testing, and releasing Liquibase extensions. It provides centralized CI/CD logic to maintain consistency across thousands of Liquibase repositories.

## Key Architecture

### Reusable Workflows Structure
- **Location**: `.github/workflows/`
- **Purpose**: DRY (Don't Repeat Yourself) approach to CI/CD across all Liquibase extensions
- **Usage Pattern**: Called from other repositories using `uses: liquibase/build-logic/.github/workflows/{workflow}.yml@main`

### Critical Workflows

#### Extension Lifecycle
1. **os-extension-test.yml** - Builds and tests open-source extensions across Java/OS matrix
2. **pro-extension-test.yml** - Tests Pro extensions with license key support
3. **extension-release-prepare.yml** - Prepares release artifacts
4. **extension-release-published.yml** - Publishes to Maven Central
5. **extension-automated-release.yml** - Automated release via Sonatype Central Portal API

#### Package Management
- **package.yml** - Creates Linux packages (deb/rpm)
- **verify-package-availability.yml** - Verifies package availability in Homebrew, SDKMAN, and repo.liquibase.com

#### Quality & Security
- **sonar-scan.yml** - Sonar code coverage scan for PRs and pushes (auto-detects context)
- **sonar-coverage-merge.yml** - Merges unit/integration test coverage and runs Sonar scan (liquibase/liquibase-pro)
- **codeql.yml** - Security scanning
- **owasp-scanner.yml** - Vulnerability scanning
- **fossa_ai.yml** - License compliance and AI-generated code scanning

### Helper Scripts
- `.github/get_draft_release.sh` - Retrieves draft release information
- `.github/sign_artifact.sh` - Signs artifacts for release
- `.github/upload_asset.sh` - Uploads assets to releases
- `.github/upload_zip.sh` - Handles zip file uploads

## Development Commands

### Testing Workflows Locally
Since these are reusable workflows, they cannot be tested directly. Test them by:
1. Creating a test branch in build-logic
2. Updating a calling repository to use your test branch: `uses: liquibase/build-logic/.github/workflows/{workflow}.yml@your-branch`
3. Triggering the workflow in the calling repository

### Validating Workflow Syntax
```bash
# Install actionlint for GitHub Actions validation
brew install actionlint

# Validate all workflows
actionlint .github/workflows/*.yml

# Validate specific workflow
actionlint .github/workflows/os-extension-test.yml
```

### Understanding Workflow Dependencies
Workflows use specific Maven configurations. Extensions calling these workflows must have:
- Jacoco plugin configured for coverage
- Surefire plugin for unit tests
- Failsafe plugin for integration tests (if using `runIntegrationTests: true`)
- Maven release plugin configured with appropriate SCM settings

## Token Strategy

### Available Tokens
1. **GITHUB_TOKEN** - Default, single-repo operations
2. **GitHub App Tokens** - Cross-repo operations (use `LIQUIBASE_GITHUB_APP_ID` and `LIQUIBASE_GITHUB_APP_PRIVATE_KEY`)
3. **PATs** - Only for GPM access (`LIQUIBOT_PAT_GPM_ACCESS`)

### AWS Vault Integration
Many workflows use AWS Secrets Manager via OIDC:
- Role: `LIQUIBASE_VAULT_OIDC_ROLE_ARN`
- Region: `us-east-1`
- Secret path: `/vault/liquibase`

## Version Management

### Releasing build-logic
When releasing a new version:
1. Create a new branch/tag
2. Update all self-references from `@main` to `@new-version` in workflow files
3. Test thoroughly in consuming repositories
4. Create release

### Version Bump PRs
- Automatically created after extension releases
- Title: "Version bump after release"
- Auto-merged nightly by `liquibase-infrastructure` repository

## Package Verification System

### Placeholder Branches
Used to track package deployment status:
- **Homebrew**: `ci-oss-homebrew-package-check-{PR_NUMBER}`
- **SDKMAN**: `ci-oss-sdkman-package-check`

These branches are automatically deleted when packages are verified as available.

## Common Workflow Parameters

### os-extension-test.yml
- `java`: Java versions array (default: `"[11, 17, 21]"`)
- `os`: Operating systems array (default: `'["ubuntu-latest", "windows-latest"]'`)
- `nightly`: Boolean for master-SNAPSHOT testing
- `skipSonar`: Skip SonarQube analysis
- `runIntegrationTests`: Enable integration test execution

### package.yml
- `groupId`: Maven groupId (e.g., `org.liquibase`)
- `artifactId`: Maven artifactId (e.g., `liquibase`)
- `version`: Package version
- `dry_run`: Test run without deployment

## Required Extension Configuration

### Maven POM Requirements
Extensions must meet Sonatype requirements and include:
- Complete POM metadata (developers, SCM, licenses)
- Jacoco plugin for coverage reporting
- Surefire plugin for unit tests
- Artifact generation (jar, pom, javadoc, sources)

### Docker Test Harness
For `lth-docker.yml` workflow:
- Docker Compose file at `src/test/resources/docker-compose.yml`

## Debugging Tips

1. **Workflow failures**: Check the calling repository's workflow run logs
2. **Token issues**: Verify secrets are properly configured in the calling repository
3. **Package verification**: Check placeholder branches in liquibase/liquibase repository
4. **Sonar issues**: Ensure Jacoco is properly configured and generating reports

## Important Notes

- Never modify workflows that are actively being used without testing
- Always maintain backward compatibility when updating workflows
- Slack notifications use `LIQUIBASE_PACKAGE_DEPLOY_STATUS_WEBHOOK` for package status
- AWS credentials are managed through OIDC, not static keys