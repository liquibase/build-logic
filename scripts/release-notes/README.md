# Release Notes Aggregator

`jira/scripts/aggregate_release_notes.py` — TECHOPS-498

Extracts `## Release note` H2 blocks from every Done ticket in a Jira Fix
Version and emits a markdown report with a seven-bucket completeness summary.
Output goes to stdout so you can redirect it to a file or pipe it directly.

---

## Prerequisites

- Python 3.11+
- `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN` in your environment
  (or in `jira/.env` — see `jira/docs/env.example`)
- The `Unknown` Fix Version must exist in all 9 federated projects
  (TECHOPS, SECURE, NTT, PD, INT, LSI, CSOL, LAI, DAT).  The script checks
  this at startup and prints a remediation command if any are missing.

---

## Usage

Run from the `jira/` directory:

```bash
python3 scripts/aggregate_release_notes.py --version "Community 5.0.4"
```

To save to a file:

```bash
python3 scripts/aggregate_release_notes.py --version "Community 5.0.4" > notes.md
```

**Exit codes**

| Code | Meaning |
|---:|---|
| 0 | Success (even if some tickets are flagged) |
| 1 | Jira / auth / unexpected runtime failure |
| 2 | Pre-flight failure — `Unknown` Fix Version missing or empty `--version` |

---

## Example Output

```markdown
# Release Notes — Community 5.0.4

**Total Done tickets:** 47
**Generated:** 2026-05-22 10:00:00 UTC

---

### Storys

#### SECURE-1234: Improve snapshot performance

Snapshot performance is improved by 40% on schemas with 500+ tables.

### Bugs

[FLAG: empty Affects Version]
#### DAT-9999: Fix NPE on empty changelog

Null pointer exception on empty changelogs is resolved.

---

## Release Notes Completeness — Community 5.0.4

| Bucket | Count |
|---|---:|
| Total Done tickets in Fix Version | 47 |
| With release note (customer-facing) | 42 |
| With release note (internal-only) | 0 |
| Skipped via `skipReleaseNotes` | 3 |
| Flagged: no H2 + no skip label | 2 |

**Completeness check:** 42 (with note) + 3 (skipped) + 2 (no H2) = 47 / 47 total

### Overlay flags

These counts are subsets of the _With release note_ row above.
They flag tickets that need a closer look — they do **not** add to the sum.

| Overlay flag | Count |
|---|---:|
| Bugs: empty Affects Version (needs follow-up) | 1 |
| Bugs: Affects Version = Unknown (needs investigation) | 0 |

**Projects encountered:** DAT (12), INT (2), NTT (4), PD (1), SECURE (28)
```

---

## Completeness Report — Bucket Guide

The completeness report is designed to account for every Done ticket with no
silent drops. The main table's three non-total buckets are **mutually exclusive**
and always sum to `total_done`:

| Bucket | What it means | Action |
|---|---|---|
| **Total Done** | All Done tickets in the Fix Version | Denominator — nothing to do |
| **With release note (customer-facing)** | Ticket had a valid `## Release note` H2 and appears in the notes body | Paste into release artifact |
| **With release note (internal-only)** | Tickets with `release-notes-internal` label — always 0 in v1 | Reserved for v2 |
| **Skipped via `skipReleaseNotes`** | Engineer applied the `skipReleaseNotes` label — intentional opt-out | No action |
| **Flagged: no H2 + no skip label** | Ticket has neither a release note nor an opt-out — likely a convention gap | Chase the engineer to add `## Release note` or `skipReleaseNotes` |

**Overlay flags** (shown in the sub-section below the main table) are additional
attributes on tickets already counted in "With release note (customer-facing)".
They do NOT add to the sum — they tell you which of those customer-facing tickets
need a closer look at Affects Version:

| Overlay flag | What it means | Action |
|---|---|---|
| **Bugs: empty Affects Version** | Bug has a release note but `Affects Version` is empty and no skip label | Release manager should confirm which version(s) are actually affected |
| **Bugs: Affects Version = Unknown** | Bug has a release note and `Affects Version = Unknown` sentinel | Engineer set `Unknown` intentionally — investigate and update before publishing |

---

## Troubleshooting

### Pre-flight failure: `Unknown` Fix Version missing

```
ERROR: 'Unknown' Fix Version is missing in: CSOL
  Run: python3 jira/scripts/create_fix_versions.py --project CSOL --versions Unknown
```

Run the printed command for each missing project, then re-run the aggregator.
This check exists to guarantee the four-state Affects Version classifier works
correctly once TECHOPS-482 merges.

### Empty output / zero tickets

```
WARNING: No Done tickets found for Fix Version "Community 5.0.4".
```

Verify the Fix Version name is spelled exactly as it appears in Jira
(case-sensitive). If the version exists but has no Done tickets, the script
exits 0 with an empty notes body and zeroed completeness table — that is
correct behaviour.

### `[unsupported ADF: <type>]` in the output

The ADF visitor does not yet render every node type. When it encounters an
unsupported type (e.g. `table`, `mediaSingle`, `panel`), it emits a visible
placeholder rather than silently dropping content:

```
[unsupported ADF: table]
```

If you see this in a published release note:

1. Note the ADF type name from the placeholder.
2. Open the source Jira ticket and simplify the release note section
   (remove the table/media and replace with plain text/list), **or**
3. File a TECHOPS ticket to add support for that node type in the script.

### Auth failure

```
ERROR: Missing required environment variable: 'JIRA_BASE_URL'
```

Ensure `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN` are set.
See `jira/docs/env.example` for the `.env` format.

---

## Related

- `jira/scripts/create_fix_versions.py` — pre-create Fix Versions (including `Unknown`)
- `jira/docs/release-runbook.md` — where this script fits in the release process
- `jira/docs/description-conventions.md` — `## Release note` H2 convention (TECHOPS-479)
- TECHOPS-498 — implementation ticket
- TECHOPS-479 — `## Release note` heading convention
- TECHOPS-478 — `skipReleaseNotes` label
- TECHOPS-482 — Affects Version four-state convention (in-flight)
