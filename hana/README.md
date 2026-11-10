# SAP HANA for tests

SAP HANA has no shared test database. Jobs start SAP HANA, express edition in Docker on the runner with the `hana-express` action ([INT-2383](https://datical.atlassian.net/browse/INT-2383)). It is the same HANA 2.0 that on-premise customers run, it is free for tests, and nothing stays running or costs money between jobs.

## Using the action in a job

```yaml
jobs:
  hana:
    runs-on: ubuntu-latest # 16 GB of memory in a public repository; HANA needs about 12 GB
    steps:
      - id: hana
        uses: liquibase/build-logic/.github/actions/hana-express@main
        with:
          agree-to-sap-license: true

      - run: liquibase update --changelog-file=changelog.yaml
        env:
          LIQUIBASE_COMMAND_URL: ${{ steps.hana.outputs.url }}
          LIQUIBASE_COMMAND_USERNAME: ${{ steps.hana.outputs.username }}
          LIQUIBASE_COMMAND_PASSWORD: ${{ steps.hana.outputs.password }}
```

- **License:** `agree-to-sap-license: true` accepts SAP's license for the express edition. The image doesn't start without it.
- **Start time:** about 3 to 4 minutes, plus the image download (1.8 GB).
- **Runner:** Linux x64 with 16 GB of memory. In a private repository `ubuntu-latest` has 7 GB, which is not enough: use a larger runner.
- **Driver:** SAP's JDBC driver is `com.sap.cloud.db.jdbc:ngdbc` on Maven Central. Liquibase needs the `liquibase-hanadb` extension.
- **Databases:** `url` is the tenant database `HXE` (port 39041), the one to test against. `system-url` is the system database (port 39017).
- **User:** `SYSTEM`, with a password the action generates and masks, unless you pass `password`.

## TLS

HANA accepts TLS on its SQL ports. The action replaces the image's self-signed certificate with one that a client can fully verify:

- The certificate is for `localhost`, `127.0.0.1` and `10.0.2.2`, RSA 3072, signed by a CA made in the job. `extra-san` adds names.
- The CA's private key is deleted after signing, and the server's key exists only inside the container.
- `url` has `encrypt=true&validateCertificate=true` and the trust store, so the driver refuses a server it can't verify.
- Outputs for other clients: `ca-cert` (PEM) and `truststore` (PKCS12, password in `truststore-password`).

Measured on 2026-11-10 with image `2.00.088.00.20251110.1`: TLS 1.3, `TLS_AES_256_GCM_SHA384`.

## With the FIPS VM

HANA stays on the runner and the client runs in the FIPS VM ([fips/README.md](../fips/README.md)). The VM reaches the runner at `10.0.2.2`, which is in the certificate:

```yaml
      - id: hana
        uses: liquibase/build-logic/.github/actions/hana-express@main
        with:
          agree-to-sap-license: true
      - uses: liquibase/build-logic/.github/actions/fips-vm@main
        with:
          memory-mb: '3072' # HANA needs most of the runner's memory
      - shell: fips-run {0}
        run: openssl s_client -connect 10.0.2.2:39041 -CAfile "$CA_CERT" -verify_ip 10.0.2.2 </dev/null
        env:
          CA_CERT: ${{ steps.hana.outputs.ca-cert }}
```

For JDBC from the VM, use `jdbc:sap://10.0.2.2:39041/?encrypt=true&validateCertificate=true` with a trust store made from `ca-cert`.

## On a laptop

`.github/actions/hana-express/start.sh` works outside GitHub Actions on Linux x64 with Docker: `HANA_AGREE_TO_SAP_LICENSE=true HANA_PASSWORD=... ./start.sh`. The settings are at the top of the script. The image is x86-64 only, so it doesn't run on Apple Silicon.

## How it is tested

`hana-express-test.yml` runs on pull requests that touch the action and every Monday:

1. Liquibase 5 with `liquibase-hanadb` and `ngdbc` updates, rolls back and reads the status of `HXE` over TLS with certificate validation (`hana/selftest`).
2. A client that trusts another CA must be refused because of the certificate.
3. From the FIPS VM, OpenSSL in FIPS mode verifies the certificate and connects.
