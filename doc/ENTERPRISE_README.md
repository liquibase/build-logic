# 📓 Fossa 3rd Party Report Generation for Enterprise

1. Manually trigger the workflow named Trigger Enterprise-FOSSA 3rd Party License Report in the build-logic repository <https://github.com/liquibase/build-logic/tree/main/.github/workflows/trigger-enterprise-fossa-third-party-license-report.yml>
![](./doc/img/trigger-fossa-report-enterprise.png)
2. Provide the required input, `<version_number_for_3p_fossa_report_generation>` (e.g., 8.7.352). This value is used to organize reports within the Cloudflare R2 bucket `liquibase-org-assets` (TECHOPS-1320, migrated off the retired origin S3 bucket; same `enterprise_fossa_report/` key prefix).
3. This workflow will trigger a matrix of runs across the relevant repositories using the `trigger-enterprise-fossa-third-party-license-report.yml`
4. Each participating repository will invoke the reusable workflow: `generate-upload-enterprise-3p-fossa-report.yml`
5. The purpose of `generate-upload-enterprise-3p-fossa-report.yml` workflow is to:

    a. Upload individual reports to the R2 bucket path: `/enterprise_fossa_report/<version_number_for_3p_fossa_report_generation>/raw_reports/` in the `liquibase-org-assets` bucket for the team to review the individual reports. Runs without a version (push runs) skip this upload and only attach the report to the run as the `fossa-reports` artifact.

    b. Upload the combined report (excluding datical-service) to: `/enterprise_fossa_report/<version_number_for_3p_fossa_report_generation>/enterprise_report_<version_number_for_3p_fossa_report_generation>.csv`

    c. Upload the datical-service report separately to: `/enterprise_fossa_report/datical-service.csv` (written by the external Datical/datical-service repository dispatch, not by a workflow in this repository; not covered by TECHOPS-1320's build-logic changes)

6. **Note**: Some columns in the FOSSA-generated reports may be incomplete or require manual adjustment. This is due to the way FOSSA outputs certain metadata.
7. To exclude specific dependencies from the final report, add them to the file: `liquibase/build-logic/blob/main/.github/workflows/ignore_dependencies_fossa.txt`
8. Final report outputs:

    a. Combined report for all repositories (excluding datical-service): `enterprise_report_<version_number_for_3p_fossa_report_generation>.csv`

    b. Separate report for datical-service: `datical-service.csv`

## 🔎 Viewing and uploading Enterprise compliance reports

The reports no longer live in S3, so the AWS console path (liquibase-prod, S3, `liquibaseorg-origin`) is not used any more.

1. Browse the reports at <https://compliance-reports.liquibase.net/enterprise_fossa_report/>. The site is behind Cloudflare Access: only the readers in the `compliance_reports_readers` policy (same Terraform file as below) can open it.
2. Every Enterprise release, replace the license files in <https://compliance-reports.liquibase.net/enterprise_fossa_report/latest/> using the **Upload to this folder** form on that page. A file with the same name is replaced.

    a. `enterprise_licenses.csv`

    b. `dmc_licenses.csv`

3. These two files are served publicly, straight from `latest/`, so uploading them also updates the public copies that the customer Legal Notices page links to:

    a. <https://third-party-licenses.liquibase.com/enterprise_licenses.csv>

    b. <https://third-party-licenses.liquibase.com/dmc_licenses.csv>

4. Only the people listed as writers in `cloudflare/zero_trust_compliance_reports.tf` in the liquibase-infrastructure repository can upload or delete. To get write access, open a PR there that adds your email.

## 🪣 Storage of SBOMs for OSS and Pro on every release

   Find the Confluence Space here: <https://datical.atlassian.net/wiki/x/CQAkCwE>
