# retry-test

Run a test command with a **bounded retry** so transient CI failures self-heal
without firing false-negative alerts. The command is retried up to
`max-attempts` times; the step only exits non-zero **after the final attempt
fails**, so downstream failure notifications fire only for genuine failures.

Built for whole-suite test runs (e.g. Liquibase Spock specs under a JUnit
Platform `@Suite`) where Surefire's per-test `rerunFailingTestsCount` is not
available, so the whole suite is re-run.

## Why a shared action

Previously each test-harness workflow carried its own inline bash retry loop
(~33 copies). This centralizes the retry behavior so the attempt count, warning
format, and logging live in one place and new workflows inherit retry by calling
the action. See TECHOPS-734 / TECHOPS-645.

## Security: how values are passed

⚠️ **Do not interpolate untrusted `${{ }}` values into `command`.** User-
controllable data (test selectors, DB coordinates) and secrets must be passed
through the dedicated **inputs** below. Each input is mapped 1:1 to an
environment variable that your `command` references as a **quoted shell
variable** (e.g. `-Dtest="$TEST_CLASSES"`). Because the values travel as
discrete inputs/env vars and are never spliced into the command string, this
follows GitHub's [script-injection hardening guidance](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections)
and stays safe even if a value contains shell metacharacters or newlines.

The retry warning is emitted as a **static** `::warning::` annotation; the
(possibly user-controlled) target is printed on a separate plain `echo`, so a
CR/LF in it cannot inject workflow commands.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `command` | yes | — | Static shell snippet to run. Reference values via the exported vars below. |
| `max-attempts` | no | `2` | Positive integer; total attempts before failing. |
| `target` | no | `''` | Label logged on retry (e.g. `postgresql-13`). |
| `working-directory` | no | `.` | Directory to run the command in. |
| `test-classes` | no | `''` | Exported as `$TEST_CLASSES`. |
| `commercial-version` | no | `''` | Exported as `$COMMERCIAL_VERSION`. |
| `community-version` | no | `''` | Exported as `$COMMUNITY_VERSION`. |
| `use-pro-artifacts` | no | `''` | Exported as `$USE_PRO_ARTIFACTS`. |
| `db-name` | no | `''` | Exported as `$DB_NAME`. |
| `db-version` | no | `''` | Exported as `$DB_VERSION`. |
| `db-username` | no | `''` | Exported as `$DB_USERNAME`. |
| `db-password` | no | `''` | Exported as `$DB_PASSWORD`. |
| `db-url` | no | `''` | Exported as `$DB_URL`. |
| `maven-opts` | no | `''` | Exported as `$MAVEN_OPTS`. |
| `jdk-java-options` | no | `''` | Exported as `$JDK_JAVA_OPTIONS` (applied to the JVM). |

## Examples

### Cloud DB Maven run (AWS/Azure/GCP/Oracle style)

```yaml
- name: AWS RDS postgresql-13 Test Run
  if: ${{ steps.setup.outputs.databasePlatform == 'postgresql' && steps.setup.outputs.databaseVersion == '13' }}
  uses: liquibase/build-logic/.github/actions/retry-test@<sha>
  with:
    target: postgresql-13
    test-classes: ${{ needs.setup.outputs.testClasses }}
    commercial-version: ${{ needs.setup.outputs.proVersion }}
    db-username: ${{ env.TH_DB_ADMIN }}
    db-password: ${{ env.TH_DB_PASSWD }}
    db-url: ${{ env.TH_PGRESURL_13 }}
    command: >-
      mvn -PuseProArtifacts -DuseProArtifacts=true
      -Dliquibase-commercial.version="$COMMERCIAL_VERSION"
      -Dtest="$TEST_CLASSES" -DconfigFile=/harness-config-cloud.yml
      -DdbName=postgresql -DdbVersion=13 -Dprefix=aws
      -DdbUsername="$DB_USERNAME" -DdbPassword="$DB_PASSWORD" -DdbUrl="$DB_URL" test
```

### automation-runner.sh (main/advanced, PRO vs COMMUNITY)

```yaml
- name: ${{ matrix.database }} Test Run
  uses: liquibase/build-logic/.github/actions/retry-test@<sha>
  with:
    target: ${{ matrix.database }}
    db-name: ${{ matrix.database }}
    test-classes: ${{ needs.setup.outputs.testClasses }}
    use-pro-artifacts: ${{ needs.setup.outputs.useProArtifacts }}
    commercial-version: ${{ needs.setup.outputs.proVersion }}
    community-version: ${{ needs.setup.outputs.communityVersion }}
    command: >-
      if [ "$USE_PRO_ARTIFACTS" = "true" ]; then
        OPTS="-PuseProArtifacts -DuseProArtifacts=true -Dliquibase-commercial.version=$COMMERCIAL_VERSION";
      else
        OPTS="-Dliquibase-core.version=$COMMUNITY_VERSION";
      fi;
      ./src/test/resources/automation-runner.sh "$DB_NAME" "$TEST_CLASSES" "$OPTS"
```

### Snowflake (extra JVM options)

```yaml
- name: Snowflake Test Run
  uses: liquibase/build-logic/.github/actions/retry-test@<sha>
  with:
    target: snowflake
    commercial-version: ${{ needs.setup.outputs.proVersion }}
    db-url: ${{ env.TH_SNOW_URL_GH }}&private_key_file=/tmp/snowflake_private_key.p8
    jdk-java-options: "--add-opens=java.base/java.nio=org.apache.arrow.memory.core,ALL-UNNAMED"
    command: >-
      mvn -PuseProArtifacts -DuseProArtifacts=true
      -Dliquibase-commercial.version="$COMMERCIAL_VERSION"
      -Dtest=LiquibaseHarnessSuiteTest -DconfigFile=/harness-config-cloud.yml
      -DdbName=snowflake -DdbUrl="$DB_URL" -DrollbackStrategy=rollbackByTag test
```

> Pin to a commit SHA (`@<sha>`) per the org GitHub Actions policy, not `@main`.
