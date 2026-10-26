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
| `selftest/` | The PostgreSQL checks that `.github/workflows/fips-vm-test.yml` runs in the VM. |

The image is built every Monday by `.github/workflows/fips-vm-image.yml` and published to `ghcr.io/liquibase/fips-vm`.
