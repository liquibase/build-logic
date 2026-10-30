# FIPS VM

A FIPS-mode AlmaLinux 9 VM for testing Liquibase with FIPS 140-3: Docker, Red Hat OpenJDK 17 and 21, and Maven 3.9,
with `/proc/sys/crypto/fips_enabled` set to `1`. INT-2303.

- **Developer guide:** [FIPS test environment](https://datical.atlassian.net/wiki/spaces/TE/pages/5892636673)
- **GitHub Actions:** `.github/actions/fips-vm`. Steps with `shell: fips-run {0}` run inside the VM.
- **Laptop:** `fips/fips-vm up` creates the same VM with Lima.

| File | What it does |
| --- | --- |
| `provision.sh` | Installs everything and turns FIPS mode on. Both the CI image and the laptop VM use it. |
| `lima.yaml` | Lima template that `fips-vm up` uses. |
| `fips-vm` | Laptop command: `up`, `shell`, `run`, `status`, `stop`, `delete`. |
| `selftest/` | The checks the test workflows run in the VM: PostgreSQL with docker compose and Testcontainers, and in `liquibase/` a changelog, `save-licenses.sh`, which reads the licenses from the vault, and `try-licenses.sh`, which tries them with Liquibase Secure. |
| `rhel/` | The same self-test on real RHEL 9 in AWS, for releases (see below). |

| Workflow | When it runs |
| --- | --- |
| `fips-vm-image.yml` | Mondays, and on PRs that change the image. Builds the image, boots the sealed image to check it, and publishes it to `ghcr.io/liquibase/fips-vm` (not on PRs). |
| `fips-vm-test.yml` | PRs that change the action or `fips/`, and Mondays after the image build. Runs the self-test on the published image, Liquibase Community included. On runs from `main` only, because the vault roles trust it from `main`, it also tries Liquibase Secure with the licenses from the vault in FIPS mode and with FIPS off (reported, not enforced), and runs the guide's Secure job. |
| `fips-vm-laptop-test.yml` | PRs that change the laptop files. Runs `fips-vm up` with Lima on Linux. |
| `fips-rhel-test.yml` | By hand from `main`, for each release. Runs the self-test on real RHEL 9 in AWS. |

## Using the action in a job

- **Java:** steps in the VM use its own JDKs, Red Hat OpenJDK 17 and 21 (`JAVA_17_HOME`, `JAVA_21_HOME`). `fips-run` doesn't pass `PATH` or `JAVA_HOME`, so `actions/setup-java` doesn't reach the VM. Another JDK, such as IBM Semeru 21 for Db2, has to be added to `provision.sh`.
- **Maven cache:** only the runner's work directory is shared with the VM, so Maven in the VM doesn't see the runner's `~/.m2`. To cache dependencies, cache a folder under the work directory and point Maven at it, for example `actions/cache` with `path: ${{ runner.temp }}/m2` and `MAVEN_ARGS: -Dmaven.repo.local=${{ runner.temp }}/m2`.
- **Databases:** start them in the VM with `docker run` or `docker compose`, so tests reach them on `localhost`. Job `services:` containers run on the runner's Docker instead: the VM reaches their published ports at `10.0.2.2`, the runner's address on the VM's network.
- **Evidence:** the action's `image` output is the image with its digest. Keep it with the results, and pass `image: ghcr.io/liquibase/fips-vm@sha256:...` to rerun on the same build. Only the last 8 weekly builds are kept.

## Real RHEL 9 for releases

AlmaLinux 9 is built from the same sources as RHEL 9 and covers daily and nightly runs. Each release is also
checked on real RHEL 9 (INT-2446): `fips-rhel-test.yml` runs `rhel/run.sh`, which:

1. Starts an on-demand `m7i.xlarge` from Red Hat's hourly AMI of the newest RHEL 9 minor release, in the dev
   account's test-harness VPC. The license is in the hourly price, about $0.26 an hour.
2. Passes `provision.sh`, the `rhel/` scripts and the self-test in its user data. The instance installs everything,
   reboots into FIPS mode and runs `rhel/checks.sh`: the same checks as `fips-vm-test.yml`'s self-test, plus a check
   that the host is RHEL 9.
3. Reads the results from the instance's serial console, writes them to the job summary, and terminates the
   instance, also when something fails. The instance stops itself, and so terminates, an hour after each boot.

A run takes about 10 minutes. Nothing connects to the instance: its security group has no inbound rule and it has
no SSH key.

### Testing a Liquibase Secure release

With a `version` (a release, `6.0.1`, or an RC, `6.0.1-RC1`) the run also tests that archive from
`repo.liquibase.com` (`releases/secure/` or `non-releases/secure/`; `package: liquibase-secure-fips` once that
archive exists):

- `run.sh` reads the published `.sha256`, and the instance checks the archive against it before unpacking it.
- On its first boot, before FIPS mode is on, the instance reads the CI license itself (`rhel/secure.sh`). Its role,
  `fips-rhel-instance`, may only assume `vault-grouped-pro-license-file`, which lists it in `aws_roles`. The license
  never passes through GitHub, the runner or the user data.
- The checks run `liquibase --version`, then `license status` and `update` with FIPS off for Liquibase, which must
  work, and in FIPS mode, which is reported, not enforced, until license files verify in FIPS mode (INT-2438).
  `require-fips-license: true` makes the FIPS-mode run a check.

Runs without a version get no instance role.

### Who runs it

- **By hand:** Actions, **FIPS RHEL test**, from `main` (the `fips-rhel` environment admits no other branch).
- **Releases:** liquibase-pro's `secure-release-orchestrator.yml` and `rc-release-orchestrator.yml` call it after
  publishing, with the released version. It runs in liquibase-pro's own `fips-rhel` environment.
- **From a laptop**, with dev account credentials: `fips/rhel/run.sh`, with the settings at the top of the script.
  It tests the local files, committed or not. Set `FIPS_RHEL_SUBNET_IDS` and `FIPS_RHEL_SECURITY_GROUP_ID` if your
  credentials can't read `/fips-rhel/config/*` in SSM.

The role `github-actions-fips-rhel` trusts this workflow from `main`, in the `fips-rhel` environment of build-logic
or liquibase-pro, and may only start `m7i.xlarge` instances tagged `managed_by=fips-rhel` (with `fips-rhel-instance`
at most), read their console and terminate them. The roles, the security group and both environments are in
liquibase-infrastructure: `dev-account/fips-rhel.tf`, `test-automation/fips-rhel-config.tf` and
`github/liquibase/repos/{public,internal}/fips-rhel-environment.tf`.
