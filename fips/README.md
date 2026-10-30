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

| Workflow | When it runs |
| --- | --- |
| `fips-vm-image.yml` | Mondays, and on PRs that change the image. Builds the image, boots the sealed image to check it, and publishes it to `ghcr.io/liquibase/fips-vm` (not on PRs). |
| `fips-vm-test.yml` | PRs that change the action or `fips/`, and Mondays after the image build. Runs the self-test on the published image, Liquibase Community included. On runs from `main` only, because the vault roles trust it from `main`, it also tries Liquibase Secure with the licenses from the vault in FIPS mode and with FIPS off (reported, not enforced), and runs the guide's Secure job. |
| `fips-vm-laptop-test.yml` | PRs that change the laptop files. Runs `fips-vm up` with Lima on Linux. |

## Using the action in a job

- **Java:** steps in the VM use its own JDKs, Red Hat OpenJDK 17 and 21 (`JAVA_17_HOME`, `JAVA_21_HOME`). `fips-run` doesn't pass `PATH` or `JAVA_HOME`, so `actions/setup-java` doesn't reach the VM. Another JDK, such as IBM Semeru 21 for Db2, has to be added to `provision.sh`.
- **Maven cache:** only the runner's work directory is shared with the VM, so Maven in the VM doesn't see the runner's `~/.m2`. To cache dependencies, cache a folder under the work directory and point Maven at it, for example `actions/cache` with `path: ${{ runner.temp }}/m2` and `MAVEN_ARGS: -Dmaven.repo.local=${{ runner.temp }}/m2`.
- **Databases:** start them in the VM with `docker run` or `docker compose`, so tests reach them on `localhost`. Job `services:` containers run on the runner's Docker instead: the VM reaches their published ports at `10.0.2.2`, the runner's address on the VM's network.
- **Evidence:** the action's `image` output is the image with its digest. Keep it with the results, and pass `image: ghcr.io/liquibase/fips-vm@sha256:...` to rerun on the same build. Only the last 8 weekly builds are kept.
