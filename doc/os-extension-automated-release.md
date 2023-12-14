# :slot_machine: Automated OS Extension Release Workflow

## :eyeglasses: Overview

This GitHub Actions workflow automates the release process for Liquibase OS extensions. It includes security vulnerability checks, dependency updates using Dependabot, and the release of new versions.

## :gun: Workflow Trigger

The workflow is triggered by an external event using the `workflow_call` event. The calling workflow is `liquibase/liquibase/.github/workflows/release-extensions.yml`

```yaml
on:
  workflow_call:
    inputs:
      version:
        description: 'Version to release (4.26.0, 4.26.1, etc.)'
        required: true
        type: string
      repositories:
        description: 'Comma separated list of repositories to release'
        required: false
        default: '["liquibase-bigquery","liquibase-cache","liquibase-cassandra", ...]'
        type: string
```

## :construction_worker: Jobs

All jobs are executed in parallel, one runner per each extension.

### :space_invader: Check Security Vulnerabilities

Check Security Vulnerabilities

```yaml
  check-security-vulnerabilities:
    runs-on: ubuntu-latest
    name: Check Security Vulnerabilities
    strategy:
      matrix:
        repository: ${{ fromJson(inputs.repositories) }}
```

### :lock: Run Extensions Dependabot

This job installs Dependabot CLI and runs it to check and update dependencies

```yaml
  run-extensions-dependabot:
    needs: check-security-vulnerabilities
    runs-on: ubuntu-latest
    name: Dependabot
    strategy:
      matrix:
        repository: ${{ fromJson(inputs.repositories) }}
```

### :arrows_counterclockwise: Update pom.xml

This job updates the `pom.xml` file for the specified repositories. It is responsible for updating the extension version and the `liquibase.version` to match the liquibase release version

```yaml
  update-pom:
    needs: check-security-vulnerabilities
    runs-on: ubuntu-latest
    name: Update pom.xml
    # ...
```

### :bookmark: Release Draft Releases

This job releases draft releases for the specified repositories. When the `pom.xml` is updated, the regular extension workflow is triggered and draft releases are created with the corresponding artifacts. Once the draft is ready, this job will release the draft and create the Nexus staging repository

```yaml
  release-draft-releases:
    needs: update-pom
    runs-on: ubuntu-latest
    name: Release Draft
    strategy:
      matrix:
        repository: ${{ fromJson(inputs.repositories) }}
```

### :closed_umbrella: Close Nexus Staging

This job closes Nexus staging repositories. Manual intervention is needed here. Nexus repositories are closed but not released.

```yaml
  create-and-close-nexus-stagging:
    needs: release-draft-releases
    runs-on: ubuntu-latest
    name: Nexus
    steps:
      - name: Wait for Sonatype Nexus
        run: sleep 60
```

## :gift: Build artifacts

2 files are generated:

1. `published_drafts.txt`: A list of the released drafts
2. `closed_nexus_repos.txt`: A list of the closed Nexus repositories

