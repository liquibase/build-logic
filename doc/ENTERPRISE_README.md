# 📓 Fossa 3rd Party Report Generation for Enterprise

1. Manually trigger the workflow named Trigger Enterprise-FOSSA 3rd Party License Report in the build-logic repository <https://github.com/liquibase/build-logic/tree/main/.github/workflows/trigger-enterprise-fossa-third-party-license-report.yml>.
2. Provide the required input, `<version_number_for_3p_fossa_report_generation>` (e.g., 8.7.352). This value is used to organize reports within the S3 bucket.
3. This workflow will trigger a matrix of runs across the relevant repositories using the `trigger-enterprise-fossa-third-party-license-report.yml`
4. Each participating repository will invoke the reusable workflow: `generate-upload-enterprise-3p-fossa-report.yml`
5. The purpose of `generate-upload-enterprise-3p-fossa-report.yml` workflow is to:

    a. Upload individual reports to the S3 bucket path: `/enterprise_fossa_report/raw_reports/` in our AWS s3 bucket under prod account for the team to review the individual reports.

    b. Upload the combined report (excluding datical-service) to: `/enterprise_fossa_report/<version_number_for_3p_fossa_report_generation>`

    c. Upload the datical-service report separately to: `/enterprise_fossa_report/datical-service.csv`

6. **Note**: Some columns in the FOSSA-generated reports may be incomplete or require manual adjustment. This is due to the way FOSSA outputs certain metadata.
7. To exclude specific dependencies from the final report, add them to the file: `liquibase/build-logic/blob/main/.github/workflows/ignore_dependencies_fossa.txt`
8. Final report outputs:

    a. Combined report for all repositories (excluding datical-service): `enterprise_report_<version_number_for_3p_fossa_report_generation>.csv`

    b. Separate report for datical-service: `datical-service.csv`

## 🪣 Storage of SBOMs for OSS and Pro on every release

   Find the Confluence Space here: <https://datical.atlassian.net/wiki/x/CQAkCwE>
