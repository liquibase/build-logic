# SAP HANA for tests

SAP HANA has no shared test database. Jobs start SAP HANA, express edition in Docker on the runner with the `hana-express` action ([INT-2383](https://datical.atlassian.net/browse/INT-2383)). It is the same HANA 2.0 that on-premise customers run, it is free for tests, and nothing stays running or costs money between jobs.

## Using the action in a job

```yaml
jobs:
  hana:
    runs-on: blacksmith-2vcpu-ubuntu-2404 # 8 GB; see "Runner" below
    steps:
      - id: hana
        uses: liquibase/build-logic/.github/actions/hana-express@<commit SHA> # main
        with:
          agree-to-sap-license: true

      - run: liquibase update --changelog-file=changelog.yaml
        env:
          LIQUIBASE_COMMAND_URL: ${{ steps.hana.outputs.url }}
          LIQUIBASE_COMMAND_USERNAME: ${{ steps.hana.outputs.username }}
          LIQUIBASE_COMMAND_PASSWORD: ${{ steps.hana.outputs.password }}
```

- **License:** `agree-to-sap-license: true` accepts SAP's license for the express edition. The image doesn't start without it.
- **Start time:** 3 to 4 minutes on `ubuntu-latest`, 5 to 6 on Blacksmith, image download (1.8 GB) included. The database itself starts in 150 to 171 seconds.
- **Runner:** Linux x64 with 8 GB of memory or more. Measured on 2026-11-12 in 20 starts on Blacksmith: the runner used 5.2 GB at most while HANA started, and HANA 3.2 to 4.4 GB once running.
  - In a private or internal repository (liquibase-pro, liquibase-pro-tests), use `blacksmith-2vcpu-ubuntu-2404`: 2 vCPU, 8 GB, $0.004 a minute, so about $0.06 for a 15-minute job. Tested there 10 times. Leave about 2 GB for the job's own work; `blacksmith-4vcpu-ubuntu-2404` (16 GB, $0.008 a minute) if it needs more.
  - In a public repository such as this one, `ubuntu-latest` has 16 GB and costs nothing.
- **Pinning:** use the action at a commit SHA, as for any shared action. The default image is pinned by digest, because SAP re-pushes its tags.
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

The action turns off HANA's client PKI (`[communication] sslclientpki = false`). With it on, HANA makes a certificate of its own 30 to 50 seconds after it starts and serves that one instead: a client then fails certificate validation, and whether it does depended on how soon it connected (4 of 10 starts failed).

## With the FIPS VM

HANA stays on the runner and the client runs in the FIPS VM ([fips/README.md](../fips/README.md)). The VM reaches the runner at `10.0.2.2`, which is in the certificate:

```yaml
      - id: hana
        uses: liquibase/build-logic/.github/actions/hana-express@<commit SHA> # main
        with:
          agree-to-sap-license: true
      - uses: liquibase/build-logic/.github/actions/fips-vm@<commit SHA> # main
        with:
          memory-mb: '3072' # HANA needs about 5 GB of the runner's memory
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
3. From the FIPS VM, OpenSSL in FIPS mode verifies the certificate and connects (TLS 1.3, `TLS_AES_256_GCM_SHA384`).
