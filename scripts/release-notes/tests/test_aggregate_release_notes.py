"""Tests for aggregate_release_notes.py.

Covers T-012 (H2 extractor), T-013 (ADF → markdown visitor), T-014 (classifier),
T-015 (bucket counter), T-016 (output renderer golden), T-017 (pre-flight), T-018
(JQL pagination).

All Jira calls are mocked — no real network access.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch, call

import pytest

# ---------------------------------------------------------------------------
# Environment stubs — must be set BEFORE importing the module under test.
# ---------------------------------------------------------------------------
os.environ.setdefault("JIRA_BASE_URL", "https://example.atlassian.net")
os.environ.setdefault("JIRA_EMAIL", "test@example.com")
os.environ.setdefault("JIRA_API_TOKEN", "test-token")

# Support running from repo root (python jira/...) or from jira/ directory.
from aggregate_release_notes import (  # noqa: E402
    EXIT_ERROR,
    EXIT_PREFLIGHT,
    FEDERATED_PROJECTS,
    _adf_nodes_to_markdown,
    _find_release_note_heading,
    _normalize,
    accumulate_issues,
    classify_affects_version,
    extract_release_note,
    fetch_issues,
    preflight_unknown_fix_version,
    render_completeness_report,
    render_notes_section,
    render_output,
)

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

FIXTURES_DIR = Path(__file__).parent / "fixtures" / "adf"


def _load_adf(name: str) -> dict:
    """Load an ADF doc fixture by filename (without .json)."""
    return json.loads((FIXTURES_DIR / f"{name}.json").read_text())


def _make_issue(
    key: str,
    *,
    issuetype: str = "Story",
    summary: str = "A summary",
    description: dict | None = None,
    labels: list[str] | None = None,
    versions: list[dict] | None = None,
    include_versions_key: bool = True,
) -> dict:
    """Build a minimal Jira issue dict for testing."""
    fields: dict[str, Any] = {
        "summary": summary,
        "issuetype": {"name": issuetype},
        "labels": labels or [],
        "project": {"key": key.split("-")[0]},
        "description": description,
    }
    if include_versions_key:
        fields["versions"] = versions if versions is not None else []
    return {"key": key, "fields": fields}


# ---------------------------------------------------------------------------
# T-012 — ADF H2 extractor tests
# ---------------------------------------------------------------------------


class TestExtractReleaseNote:
    def test_extract_canonical_h2(self) -> None:
        adf = _load_adf("canonical_h2")
        issue = _make_issue("DAT-1", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "crash" in result

    def test_extract_capital_n_alias(self) -> None:
        adf = _load_adf("capital_n_alias")
        issue = _make_issue("DAT-2", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "Capital N" in result

    def test_extract_trailing_colon_alias(self) -> None:
        adf = _load_adf("trailing_colon_alias")
        issue = _make_issue("DAT-3", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "colon" in result

    def test_extract_legacy_user_benefit_alias(self) -> None:
        adf = _load_adf("legacy_alias")
        issue = _make_issue("DAT-4", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "Legacy alias" in result

    def test_extract_no_h2_returns_none(self) -> None:
        adf = _load_adf("no_h2")
        issue = _make_issue("DAT-5", description=adf)
        assert extract_release_note(issue) is None

    def test_extract_stops_at_next_h2(self) -> None:
        """Content after a second H2 must not be captured."""
        adf = {
            "type": "doc",
            "version": 1,
            "content": [
                {"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": "Release note"}]},
                {"type": "paragraph", "content": [{"type": "text", "text": "In scope."}]},
                {"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": "Implementation"}]},
                {"type": "paragraph", "content": [{"type": "text", "text": "Out of scope."}]},
            ],
        }
        issue = _make_issue("DAT-6", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "In scope" in result
        assert "Out of scope" not in result

    def test_extract_stops_at_h3(self) -> None:
        """An H3 heading after the release note H2 must stop capture (any-level rule)."""
        adf = {
            "type": "doc",
            "version": 1,
            "content": [
                {"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": "Release note"}]},
                {"type": "paragraph", "content": [{"type": "text", "text": "Captured."}]},
                {"type": "heading", "attrs": {"level": 3}, "content": [{"type": "text", "text": "Sub-section"}]},
                {"type": "paragraph", "content": [{"type": "text", "text": "Not captured."}]},
            ],
        }
        issue = _make_issue("DAT-7", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "Captured" in result
        assert "Not captured" not in result

    def test_extract_h3_alone_not_matched(self) -> None:
        """An H3 release-note heading must NOT match (strict H2 only)."""
        adf = {
            "type": "doc",
            "version": 1,
            "content": [
                {"type": "heading", "attrs": {"level": 3}, "content": [{"type": "text", "text": "Release note"}]},
                {"type": "paragraph", "content": [{"type": "text", "text": "Body text."}]},
            ],
        }
        issue = _make_issue("DAT-8", description=adf)
        assert extract_release_note(issue) is None

    def test_extract_null_description_returns_none(self) -> None:
        issue = _make_issue("DAT-9", description=None)
        assert extract_release_note(issue) is None

    def test_extract_multi_paragraph(self) -> None:
        adf = _load_adf("multi_paragraph")
        issue = _make_issue("DAT-10", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "First paragraph" in result
        assert "Second paragraph" in result
        assert "Third paragraph" in result


# ---------------------------------------------------------------------------
# T-013 — ADF → markdown visitor tests
# ---------------------------------------------------------------------------


class TestAdfNodesToMarkdown:
    def test_paragraph_renders_text(self) -> None:
        nodes = [{"type": "paragraph", "content": [{"type": "text", "text": "Hello world."}]}]
        result = _adf_nodes_to_markdown(nodes)
        assert "Hello world." in result

    def test_bold_mark(self) -> None:
        nodes = [{"type": "text", "text": "bold", "marks": [{"type": "strong"}]}]
        assert "**bold**" in _adf_nodes_to_markdown(nodes)

    def test_italic_mark(self) -> None:
        nodes = [{"type": "text", "text": "italic", "marks": [{"type": "em"}]}]
        assert "_italic_" in _adf_nodes_to_markdown(nodes)

    def test_code_mark(self) -> None:
        nodes = [{"type": "text", "text": "code", "marks": [{"type": "code"}]}]
        assert "`code`" in _adf_nodes_to_markdown(nodes)

    def test_link_mark(self) -> None:
        nodes = [
            {
                "type": "text",
                "text": "link text",
                "marks": [{"type": "link", "attrs": {"href": "https://example.com"}}],
            }
        ]
        result = _adf_nodes_to_markdown(nodes)
        assert "[link text](https://example.com)" in result

    def test_extract_preserves_bold_italic_code(self) -> None:
        adf = _load_adf("marks_variety")
        issue = _make_issue("DAT-20", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "**bold**" in result
        assert "_italic_" in result
        assert "`code`" in result
        assert "[link text](https://example.com)" in result

    def test_bold_italic_combined(self) -> None:
        """Bold + italic marks on the same text node."""
        nodes = [{"type": "text", "text": "bold-italic", "marks": [{"type": "strong"}, {"type": "em"}]}]
        result = _adf_nodes_to_markdown(nodes)
        assert "bold-italic" in result
        assert "**" in result
        assert "_" in result

    def test_extract_preserves_bullet_list(self) -> None:
        adf = _load_adf("nested_bullets")
        issue = _make_issue("DAT-21", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "- Top-level item" in result
        # Nested item should be indented
        assert "  - Nested item" in result

    def test_extract_preserves_ordered_list(self) -> None:
        adf = _load_adf("ordered_list")
        issue = _make_issue("DAT-22", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "1. First step" in result
        assert "2. Second step" in result

    def test_extract_preserves_hyperlink(self) -> None:
        adf = _load_adf("marks_variety")
        issue = _make_issue("DAT-23", description=adf)
        result = extract_release_note(issue)
        assert "[link text](https://example.com)" in result

    def test_code_block_with_language(self) -> None:
        adf = _load_adf("code_block")
        issue = _make_issue("DAT-24", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "```sql" in result
        assert "SELECT" in result
        assert "```" in result

    def test_extract_unsupported_node_placeholder(self) -> None:
        adf = _load_adf("unsupported_node")
        issue = _make_issue("DAT-25", description=adf)
        result = extract_release_note(issue)
        assert result is not None
        assert "[unsupported ADF: table]" in result

    def test_hardbreak_renders(self) -> None:
        nodes = [
            {
                "type": "paragraph",
                "content": [
                    {"type": "text", "text": "line one"},
                    {"type": "hardBreak"},
                    {"type": "text", "text": "line two"},
                ],
            }
        ]
        result = _adf_nodes_to_markdown(nodes)
        assert "line one" in result
        assert "line two" in result
        assert "  \n" in result

    def test_inline_card_renders_url(self) -> None:
        nodes = [
            {
                "type": "inlineCard",
                "attrs": {"url": "https://example.com/page"},
            }
        ]
        result = _adf_nodes_to_markdown(nodes)
        assert "https://example.com/page" in result

    def test_heading_in_section_shifts_level(self) -> None:
        """A heading inside a release-note section must never emit H2."""
        nodes = [
            {
                "type": "heading",
                "attrs": {"level": 2},
                "content": [{"type": "text", "text": "Sub"}],
            }
        ]
        result = _adf_nodes_to_markdown(nodes)
        assert result.startswith("###")


# ---------------------------------------------------------------------------
# T-014 — Affects-Version classifier tests
# ---------------------------------------------------------------------------


class TestClassifyAffectsVersion:
    def test_classify_story_skips_affects_version(self) -> None:
        issue = _make_issue("DAT-30", issuetype="Story", versions=[])
        assert classify_affects_version(issue) == "populated"

    def test_classify_task_skips_affects_version(self) -> None:
        issue = _make_issue("DAT-31", issuetype="Task", versions=[])
        assert classify_affects_version(issue) == "populated"

    def test_classify_bug_populated(self) -> None:
        issue = _make_issue("DAT-32", issuetype="Bug", versions=[{"name": "5.0.3"}])
        assert classify_affects_version(issue) == "populated"

    def test_classify_bug_unknown_alone(self) -> None:
        issue = _make_issue("DAT-33", issuetype="Bug", versions=[{"name": "Unknown"}])
        assert classify_affects_version(issue) == "unknown"

    def test_classify_bug_empty_with_skip(self) -> None:
        issue = _make_issue(
            "DAT-34", issuetype="Bug", versions=[], labels=["skipReleaseNotes"]
        )
        assert classify_affects_version(issue) == "empty_with_skip"

    def test_classify_bug_empty_alone(self) -> None:
        issue = _make_issue("DAT-35", issuetype="Bug", versions=[])
        assert classify_affects_version(issue) == "empty_alone"

    def test_classify_bug_missing_field_graceful(self) -> None:
        """When versions key is absent (TECHOPS-482 unmerged), returns empty_alone."""
        issue = _make_issue("DAT-36", issuetype="Bug", include_versions_key=False)
        assert classify_affects_version(issue) == "empty_alone"

    def test_classify_bug_unknown_mixed_with_real(self) -> None:
        """Unknown + real version = populated (mixed rule D-DSGN-4)."""
        issue = _make_issue(
            "DAT-37",
            issuetype="Bug",
            versions=[{"name": "Unknown"}, {"name": "5.0.3"}],
        )
        assert classify_affects_version(issue) == "populated"


# ---------------------------------------------------------------------------
# T-015 — Bucket counter + tie-breaker tests
# ---------------------------------------------------------------------------


def _make_issue_with_adf(key: str, adf_name: str, **kwargs: Any) -> dict:
    adf = _load_adf(adf_name)
    return _make_issue(key, description=adf, **kwargs)


class TestAccumulateIssues:
    def test_bucket_skip_wins_over_h2(self) -> None:
        """skipReleaseNotes must beat H2 presence — lands in skipped only."""
        issue = _make_issue_with_adf(
            "DAT-40", "canonical_h2", issuetype="Story", labels=["skipReleaseNotes"]
        )
        entries, buckets, _ = accumulate_issues([issue])
        assert buckets["skipped"] == 1
        assert buckets["with_note_customer"] == 0
        assert len(entries) == 0

    def test_bucket_no_h2_no_skip_exclusive_from_av_flags(self) -> None:
        """Bug with no H2 and empty AV → no_h2_no_skip only (no AV flag applied)."""
        issue = _make_issue_with_adf("DAT-41", "no_h2", issuetype="Bug", versions=[])
        entries, buckets, _ = accumulate_issues([issue])
        assert buckets["no_h2_no_skip"] == 1
        assert buckets["affects_version_empty_alone"] == 0
        assert buckets["with_note_customer"] == 0

    def test_bucket_av_empty_overlay(self) -> None:
        """Bug with H2 + empty AV + no skip → with_note_customer AND affects_version_empty_alone."""
        issue = _make_issue_with_adf(
            "DAT-42", "canonical_h2", issuetype="Bug", versions=[]
        )
        entries, buckets, _ = accumulate_issues([issue])
        assert buckets["with_note_customer"] == 1
        assert buckets["affects_version_empty_alone"] == 1
        assert len(entries) == 1
        assert "empty Affects Version" in entries[0]["flags"]

    def test_bucket_av_unknown_overlay(self) -> None:
        """Bug with H2 + Unknown AV → with_note_customer AND affects_version_unknown."""
        issue = _make_issue_with_adf(
            "DAT-43", "canonical_h2", issuetype="Bug", versions=[{"name": "Unknown"}]
        )
        entries, buckets, _ = accumulate_issues([issue])
        assert buckets["with_note_customer"] == 1
        assert buckets["affects_version_unknown"] == 1
        assert "Unknown Affects Version" in entries[0]["flags"]

    def test_bucket_sum_invariant(self) -> None:
        """Core invariant: with_note_customer + skipped + no_h2_no_skip == total_done."""
        issues = [
            # with_note_customer (Story with H2)
            _make_issue_with_adf("DAT-50", "canonical_h2", issuetype="Story"),
            # with_note_customer + av_empty overlay (Bug with H2, empty AV)
            _make_issue_with_adf("DAT-51", "canonical_h2", issuetype="Bug", versions=[]),
            # with_note_customer + av_unknown overlay (Bug with H2, Unknown AV)
            _make_issue_with_adf(
                "DAT-52", "canonical_h2", issuetype="Bug", versions=[{"name": "Unknown"}]
            ),
            # skipped
            _make_issue_with_adf(
                "DAT-53", "canonical_h2", issuetype="Story", labels=["skipReleaseNotes"]
            ),
            # no_h2_no_skip
            _make_issue_with_adf("DAT-54", "no_h2", issuetype="Story"),
        ]
        entries, buckets, project_counts = accumulate_issues(issues)
        assert buckets["total_done"] == 5
        core_sum = (
            buckets["with_note_customer"]
            + buckets["skipped"]
            + buckets["no_h2_no_skip"]
        )
        assert core_sum == buckets["total_done"], (
            f"Invariant broken: {buckets['with_note_customer']} + "
            f"{buckets['skipped']} + {buckets['no_h2_no_skip']} != "
            f"{buckets['total_done']}"
        )

    def test_bucket_with_note_internal_always_zero(self) -> None:
        """v1 invariant: with_note_internal is always 0."""
        issues = [_make_issue_with_adf("DAT-60", "canonical_h2", issuetype="Story")]
        _, buckets, __ = accumulate_issues(issues)
        assert buckets["with_note_internal"] == 0

    def test_empty_input_all_zeros(self) -> None:
        entries, buckets, _ = accumulate_issues([])
        assert buckets["total_done"] == 0
        assert all(v == 0 for k, v in buckets.items() if k != "total_done")
        assert entries == []


# ---------------------------------------------------------------------------
# T-016 — Output renderer golden-file + determinism tests
# ---------------------------------------------------------------------------


class TestRenderOutput:
    def _build_mixed_entries_and_buckets(self) -> tuple[list[dict], dict]:
        """Build a fixture set covering all bucket states for golden-file testing."""
        issues = [
            # Story with H2 → with_note_customer
            _make_issue_with_adf("DAT-100", "canonical_h2", issuetype="Story", summary="Story fix"),
            # Task with H2 → with_note_customer
            _make_issue_with_adf("DAT-101", "canonical_h2", issuetype="Task", summary="Task improvement"),
            # Bug with H2 + populated AV → with_note_customer, no flag
            _make_issue_with_adf(
                "DAT-102", "canonical_h2", issuetype="Bug", summary="Bug fix A",
                versions=[{"name": "5.0.3"}],
            ),
            # Bug with H2 + empty AV → with_note_customer + av_empty overlay
            _make_issue_with_adf(
                "DAT-103", "canonical_h2", issuetype="Bug", summary="Bug fix B", versions=[]
            ),
            # Bug with H2 + Unknown AV → with_note_customer + av_unknown overlay
            _make_issue_with_adf(
                "DAT-104", "canonical_h2", issuetype="Bug", summary="Bug fix C",
                versions=[{"name": "Unknown"}],
            ),
            # Skipped
            _make_issue_with_adf(
                "DAT-105", "canonical_h2", issuetype="Story", summary="Internal",
                labels=["skipReleaseNotes"],
            ),
            # No H2, no skip
            _make_issue_with_adf("DAT-106", "no_h2", issuetype="Bug", summary="No note bug"),
        ]
        return accumulate_issues(issues)

    def test_render_notes_grouped_by_issuetype(self) -> None:
        entries, buckets, _proj_counts = self._build_mixed_entries_and_buckets()
        output = render_notes_section(entries)
        story_pos = output.find("### Storys")
        task_pos = output.find("### Tasks")
        bug_pos = output.find("### Bugs")
        assert story_pos != -1, "Story group heading missing"
        assert task_pos != -1, "Task group heading missing"
        assert bug_pos != -1, "Bug group heading missing"
        assert story_pos < bug_pos, "Stories must appear before Bugs"
        assert task_pos < bug_pos, "Tasks must appear before Bugs"

    def test_render_notes_sub_sorted_by_key(self) -> None:
        """Keys within each group must be ascending."""
        # Add two bugs in reverse key order to force a sort.
        issues = [
            _make_issue_with_adf(
                "DAT-200", "canonical_h2", issuetype="Bug", summary="Bug Z",
                versions=[{"name": "5.0.3"}],
            ),
            _make_issue_with_adf(
                "DAT-100", "canonical_h2", issuetype="Bug", summary="Bug A",
                versions=[{"name": "5.0.3"}],
            ),
        ]
        entries, _, __ = accumulate_issues(issues)
        output = render_notes_section(entries)
        pos_100 = output.find("DAT-100")
        pos_200 = output.find("DAT-200")
        assert pos_100 < pos_200, "DAT-100 should appear before DAT-200"

    def test_render_flag_empty_affects_version(self) -> None:
        issue = _make_issue_with_adf(
            "DAT-110", "canonical_h2", issuetype="Bug", versions=[]
        )
        entries, _, __ = accumulate_issues([issue])
        output = render_notes_section(entries)
        assert "[FLAG: empty Affects Version]" in output

    def test_render_flag_unknown_affects_version(self) -> None:
        issue = _make_issue_with_adf(
            "DAT-111", "canonical_h2", issuetype="Bug", versions=[{"name": "Unknown"}]
        )
        entries, _, __ = accumulate_issues([issue])
        output = render_notes_section(entries)
        assert "[FLAG: Unknown Affects Version]" in output

    def test_render_no_flag_when_populated(self) -> None:
        issue = _make_issue_with_adf(
            "DAT-112", "canonical_h2", issuetype="Bug", versions=[{"name": "5.0.3"}]
        )
        entries, _, __ = accumulate_issues([issue])
        output = render_notes_section(entries)
        assert "[FLAG:" not in output

    def test_render_completeness_report_table_shape(self) -> None:
        buckets = {
            "total_done": 7,
            "with_note_customer": 3,
            "with_note_internal": 0,
            "skipped": 2,
            "no_h2_no_skip": 2,
            "affects_version_empty_alone": 1,
            "affects_version_unknown": 1,
        }
        report = render_completeness_report(buckets, "Community 5.0.4")
        lines = report.split("\n")
        table_rows = [l for l in lines if l.strip().startswith("|") and "---" not in l]
        assert len(table_rows) >= 7, f"Expected at least 7 table rows, got {len(table_rows)}: {table_rows}"

    def test_render_completeness_buckets_sum_to_total(self) -> None:
        buckets = {
            "total_done": 10,
            "with_note_customer": 6,
            "with_note_internal": 0,
            "skipped": 2,
            "no_h2_no_skip": 2,
            "affects_version_empty_alone": 1,
            "affects_version_unknown": 0,
        }
        report = render_completeness_report(buckets, "Community 5.0.4")
        assert "6 (with note) + 2 (skipped) + 2 (no H2) = 10 / 10 total" in report

    def test_render_projects_encountered_footer(self) -> None:
        issues = [
            _make_issue_with_adf("SECURE-1", "canonical_h2", issuetype="Story", summary="S1"),
            _make_issue_with_adf("DAT-1", "canonical_h2", issuetype="Bug", versions=[{"name": "5.0.3"}], summary="D1"),
        ]
        entries, buckets, project_counts = accumulate_issues(issues)
        output = render_output("Community 5.0.4", entries, buckets, "2026-05-22 10:00:00", project_counts)
        assert "SECURE (1)" in output
        assert "DAT (1)" in output

    def test_render_deterministic(self) -> None:
        """Two calls with same inputs (modulo timestamp) produce identical notes + table."""
        entries, buckets, _proj_counts = self._build_mixed_entries_and_buckets()
        out1 = render_output("Community 5.0.4", entries, buckets, "2026-05-22 10:00:00")
        out2 = render_output("Community 5.0.4", entries, buckets, "2026-05-22 10:00:00")
        assert out1 == out2

    def test_render_heading_present(self) -> None:
        entries, buckets, _proj_counts = self._build_mixed_entries_and_buckets()
        output = render_output("Community 5.0.4", entries, buckets, "2026-05-22 10:00:00")
        assert "# Release Notes — Community 5.0.4" in output

    def test_render_completeness_heading_present(self) -> None:
        entries, buckets, _proj_counts = self._build_mixed_entries_and_buckets()
        output = render_output("Community 5.0.4", entries, buckets, "2026-05-22 10:00:00")
        assert "## Release Notes Completeness — Community 5.0.4" in output

    def test_render_overlay_section_present(self) -> None:
        entries, buckets, _proj_counts = self._build_mixed_entries_and_buckets()
        output = render_output("Community 5.0.4", entries, buckets, "2026-05-22 10:00:00")
        assert "### Overlay flags" in output

    def test_render_empty_version_zero_buckets(self) -> None:
        buckets = {
            "total_done": 0,
            "with_note_customer": 0,
            "with_note_internal": 0,
            "skipped": 0,
            "no_h2_no_skip": 0,
            "affects_version_empty_alone": 0,
            "affects_version_unknown": 0,
        }
        report = render_completeness_report(buckets, "Community 5.0.4")
        assert "0" in report


# ---------------------------------------------------------------------------
# T-016 — Golden-file test
# ---------------------------------------------------------------------------


GOLDEN_DIR = Path(__file__).parent / "fixtures" / "golden"


class TestGoldenFile:
    def test_render_golden_file(self) -> None:
        """Compare full render output against committed golden file."""
        issues = [
            _make_issue_with_adf("DAT-100", "canonical_h2", issuetype="Story", summary="Story fix"),
            _make_issue_with_adf("DAT-101", "canonical_h2", issuetype="Task", summary="Task improvement"),
            _make_issue_with_adf(
                "DAT-102", "canonical_h2", issuetype="Bug", summary="Bug fix A",
                versions=[{"name": "5.0.3"}],
            ),
            _make_issue_with_adf(
                "DAT-103", "canonical_h2", issuetype="Bug", summary="Bug fix B", versions=[]
            ),
            _make_issue_with_adf(
                "DAT-105", "canonical_h2", issuetype="Story", summary="Internal",
                labels=["skipReleaseNotes"],
            ),
            _make_issue_with_adf("DAT-106", "no_h2", issuetype="Bug", summary="No note bug"),
        ]
        entries, buckets, project_counts = accumulate_issues(issues)
        actual = render_output("Community 5.0.4", entries, buckets, "2026-05-22 10:00:00", project_counts)

        golden_path = GOLDEN_DIR / "output_mixed.md"
        if not golden_path.exists():
            # First run: write the golden file.
            GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
            golden_path.write_text(actual)
            pytest.skip("Golden file written on first run — re-run to compare")

        expected = golden_path.read_text()
        assert actual == expected, (
            "Output does not match golden file. "
            "If the change is intentional, delete "
            f"{golden_path} and re-run to regenerate."
        )


# ---------------------------------------------------------------------------
# T-017 — Pre-flight check tests
# ---------------------------------------------------------------------------


class TestPreflightUnknownFixVersion:
    def _make_client(self, present_projects: list[str]) -> MagicMock:
        """Return a mock client where the listed projects have Unknown Fix Version."""
        client = MagicMock()

        def _get(path: str) -> list:
            key = path.split("/project/")[1].split("/")[0]
            if key in present_projects:
                return [{"name": "Unknown", "id": "99"}]
            return []

        client.request.side_effect = lambda method, path: _get(path)
        return client

    def test_preflight_unknown_present_in_all(self) -> None:
        client = self._make_client(FEDERATED_PROJECTS)
        # Must return without calling sys.exit.
        preflight_unknown_fix_version(client)

    def test_preflight_unknown_missing_in_some(self, capsys: pytest.CaptureFixture) -> None:
        present = [p for p in FEDERATED_PROJECTS if p != "CSOL"]
        client = self._make_client(present)
        with pytest.raises(SystemExit) as exc_info:
            preflight_unknown_fix_version(client)
        assert exc_info.value.code == EXIT_PREFLIGHT
        captured = capsys.readouterr()
        assert "CSOL" in captured.err
        assert "create_fix_versions.py" in captured.err

    def test_preflight_missing_multiple(self, capsys: pytest.CaptureFixture) -> None:
        present = [p for p in FEDERATED_PROJECTS if p not in ("CSOL", "LAI")]
        client = self._make_client(present)
        with pytest.raises(SystemExit) as exc_info:
            preflight_unknown_fix_version(client)
        assert exc_info.value.code == EXIT_PREFLIGHT
        captured = capsys.readouterr()
        assert "CSOL" in captured.err
        assert "LAI" in captured.err

    def test_preflight_jira_error_exit_1(self, capsys: pytest.CaptureFixture) -> None:
        """Network/auth failure → sys.exit(1), distinct from pre-flight exit 2."""
        client = MagicMock()
        client.request.side_effect = RuntimeError("Connection refused")
        with pytest.raises(SystemExit) as exc_info:
            preflight_unknown_fix_version(client)
        assert exc_info.value.code == EXIT_ERROR


# ---------------------------------------------------------------------------
# T-018 — JQL pagination + error-handling tests
# ---------------------------------------------------------------------------


def _make_jira_page(issues: list, next_token: str | None = None) -> dict:
    resp: dict[str, Any] = {"issues": issues}
    if next_token:
        resp["nextPageToken"] = next_token
    return resp


class TestFetchIssues:
    def _issue_stubs(self, count: int, prefix: str = "DAT") -> list[dict]:
        return [{"key": f"{prefix}-{i}", "fields": {}} for i in range(1, count + 1)]

    def test_fetch_paginates_all_pages(self) -> None:
        """3 pages × 50 issues each → flat list of 150."""
        page1 = _make_jira_page(self._issue_stubs(50), next_token="tok-2")
        page2 = _make_jira_page(self._issue_stubs(50, "NTT"), next_token="tok-3")
        page3 = _make_jira_page(self._issue_stubs(50, "INT"))

        client = MagicMock()
        client.request.side_effect = [page1, page2, page3]
        result = fetch_issues(client, "Community 5.0.4")
        assert len(result) == 150
        assert client.request.call_count == 3

    def test_fetch_empty_version(self) -> None:
        """0 issues → empty list, no exception, no exit."""
        client = MagicMock()
        client.request.return_value = _make_jira_page([])
        result = fetch_issues(client, "Secure 99.0.0")
        assert result == []

    def test_fetch_single_page(self) -> None:
        issues = self._issue_stubs(5)
        client = MagicMock()
        client.request.return_value = _make_jira_page(issues)
        result = fetch_issues(client, "Community 5.0.4")
        assert len(result) == 5
        assert client.request.call_count == 1

    def test_fetch_raises_on_unrecoverable_4xx(self, capsys: pytest.CaptureFixture) -> None:
        """A 403 response should print an error and exit 1."""
        client = MagicMock()
        client.request.side_effect = RuntimeError(
            "POST https://example.atlassian.net/rest/api/3/search/jql -> 403: Forbidden"
        )
        with pytest.raises(SystemExit) as exc_info:
            fetch_issues(client, "Community 5.0.4")
        assert exc_info.value.code == EXIT_ERROR
        captured = capsys.readouterr()
        assert "Jira returned a client error" in captured.err

    def test_fetch_non_4xx_runtime_error_propagates(self) -> None:
        """Errors without '-> 4' in message should propagate as RuntimeError."""
        client = MagicMock()
        client.request.side_effect = RuntimeError("Connection refused")
        with pytest.raises(RuntimeError, match="Connection refused"):
            fetch_issues(client, "Community 5.0.4")

    def test_fetch_includes_correct_fields(self) -> None:
        """The JQL payload must request the required fields and use filter 24722."""
        client = MagicMock()
        client.request.return_value = _make_jira_page([])
        fetch_issues(client, "Community 5.0.4")
        call_kwargs = client.request.call_args
        payload = call_kwargs[1]["json"] if call_kwargs[1] else call_kwargs[0][2]
        assert "filter = 24722" in payload["jql"]
        assert 'fixVersion = "Community 5.0.4"' in payload["jql"]
        # Must NOT enumerate project keys
        for proj in FEDERATED_PROJECTS:
            assert f"project = {proj}" not in payload["jql"]

    def test_fetch_none_response_terminates(self) -> None:
        """If client returns None, loop terminates without error."""
        client = MagicMock()
        client.request.return_value = None
        result = fetch_issues(client, "Community 5.0.4")
        assert result == []


# ---------------------------------------------------------------------------
# Normalize helper
# ---------------------------------------------------------------------------


class TestNormalize:
    def test_strip_whitespace(self) -> None:
        assert _normalize("  Release note  ") == "release note"

    def test_lowercase(self) -> None:
        assert _normalize("Release Note") == "release note"

    def test_strip_trailing_colon(self) -> None:
        assert _normalize("Release note:") == "release note"

    def test_combined(self) -> None:
        assert _normalize("  Release Note:  ") == "release note"


# ---------------------------------------------------------------------------
# Integration smoke — end-to-end with mocked client
# ---------------------------------------------------------------------------


class TestMainHappyPath:
    def test_main_stdout_contains_notes_and_report(self, capsys: pytest.CaptureFixture) -> None:
        """End-to-end: mocked client returns one issue; output has notes + report.

        JiraClient is imported inside main() via importlib (to support running from
        any cwd), so we inject a mock module into sys.modules before calling main().
        """
        adf = _load_adf("canonical_h2")
        mock_issues = [
            {
                "key": "DAT-1",
                "fields": {
                    "summary": "Fix the thing",
                    "description": adf,
                    "issuetype": {"name": "Story"},
                    "labels": [],
                    "versions": [],
                    "project": {"key": "DAT"},
                },
            }
        ]
        mock_client = MagicMock()
        # pre-flight: all projects have Unknown; search returns issues
        mock_client.request.side_effect = lambda method, path, **kw: (
            [{"name": "Unknown"}]
            if method == "GET" and "/versions" in path
            else _make_jira_page(mock_issues)
        )

        mock_jira_module = MagicMock()
        mock_jira_module.JiraClient.return_value = mock_client

        sys.argv = ["aggregate_release_notes.py", "--version", "Community 5.0.4"]
        # Inject mock into sys.modules so the dynamic import inside main() picks it up.
        old_module = sys.modules.get("jira_client")
        sys.modules["jira_client"] = mock_jira_module
        try:
            from aggregate_release_notes import main
            exit_code = main()
        finally:
            if old_module is None:
                sys.modules.pop("jira_client", None)
            else:
                sys.modules["jira_client"] = old_module

        assert exit_code == 0
        captured = capsys.readouterr()
        assert "Release Notes — Community 5.0.4" in captured.out
        assert "Release Notes Completeness" in captured.out
