"""Aggregate release notes from Done Jira tickets in a Fix Version.

Extracts ``## Release note`` H2 blocks from Done tickets, applies the
four-state Affects Version rule for Bug issuetypes, and emits a structured
markdown report plus seven-bucket completeness summary to stdout.

Usage:
    python scripts/aggregate_release_notes.py --version "Community 5.0.4"

Exit codes:
    0  success (even if some tickets are flagged)
    1  Jira / auth / unexpected runtime failure
    2  pre-flight failure / user input error
"""

from __future__ import annotations

import argparse
import datetime
import re
import sys
from typing import Any

# ---------------------------------------------------------------------------
# Exit-code constants
# ---------------------------------------------------------------------------

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_PREFLIGHT = 2

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FEDERATED_PROJECTS: list[str] = [
    "TECHOPS",
    "SECURE",
    "NTT",
    "PD",
    "INT",
    "LSI",
    "CSOL",
    "LAI",
    "DAT",
]

# Board filter 24722 covers all federated projects — DO NOT enumerate project keys.
_JQL_TEMPLATE = 'filter = 24722 AND fixVersion = "{version}" AND status = Done'

# Heading aliases that signal the start of a release-note block (post-normalization).
_RELEASE_NOTE_ALIASES: frozenset[str] = frozenset(
    [
        "release note",
        "user benefit (release note)",
    ]
)

# ---------------------------------------------------------------------------
# ADF → Markdown visitor (T-007)
# ---------------------------------------------------------------------------


def _adf_nodes_to_markdown(nodes: list[dict], depth: int = 0) -> str:
    """Render a list of ADF nodes to markdown.

    Supported node types: paragraph, text (with marks), bulletList, orderedList,
    listItem, codeBlock, heading, hardBreak, inlineCard, blockCard.
    Unknown types emit ``[unsupported ADF: <type>]`` — they never raise.
    """
    parts: list[str] = []
    indent = "  " * depth

    for node in nodes:
        ntype = node.get("type", "")
        content = node.get("content", [])

        if ntype == "paragraph":
            inner = _adf_nodes_to_markdown(content, depth)
            parts.append(inner + "\n")

        elif ntype == "text":
            text = node.get("text", "")
            marks = node.get("marks", [])
            text = _apply_marks(text, marks)
            parts.append(text)

        elif ntype == "bulletList":
            parts.append(_render_list(content, depth, ordered=False))

        elif ntype == "orderedList":
            parts.append(_render_list(content, depth, ordered=True))

        elif ntype == "listItem":
            # listItem is rendered by the parent list renderer; reaching here
            # means an orphaned listItem — render its children inline.
            parts.append(_adf_nodes_to_markdown(content, depth))

        elif ntype == "codeBlock":
            lang = node.get("attrs", {}).get("language", "") or ""
            code_text = "".join(
                n.get("text", "") for n in content if n.get("type") == "text"
            )
            parts.append(f"```{lang}\n{code_text}\n```\n")

        elif ntype == "heading":
            level = node.get("attrs", {}).get("level", 2)
            # Never emit H2 (would collide with the section heading); shift down.
            effective_level = max(level, 3)
            hashes = "#" * effective_level
            heading_text = _adf_nodes_to_markdown(content, depth).strip()
            parts.append(f"{hashes} {heading_text}\n")

        elif ntype == "hardBreak":
            parts.append("  \n")

        elif ntype in ("inlineCard", "blockCard"):
            url = node.get("attrs", {}).get("url", "")
            parts.append(f"[{url}]({url})")

        else:
            parts.append(f"[unsupported ADF: {ntype}]")

    return "".join(parts)


def _apply_marks(text: str, marks: list[dict]) -> str:
    """Apply inline ADF marks to a text string, returning decorated markdown."""
    for mark in marks:
        mtype = mark.get("type", "")
        if mtype == "strong":
            text = f"**{text}**"
        elif mtype == "em":
            text = f"_{text}_"
        elif mtype == "code":
            text = f"`{text}`"
        elif mtype == "link":
            href = mark.get("attrs", {}).get("href", "")
            text = f"[{text}]({href})"
        # Other mark types (underline, strike, etc.) are silently dropped.
    return text


def _render_list(
    items: list[dict], depth: int, ordered: bool
) -> str:
    """Render a bulletList or orderedList ADF node to markdown."""
    lines: list[str] = []
    indent = "  " * depth
    for idx, item in enumerate(items):
        if item.get("type") != "listItem":
            continue
        prefix = f"{idx + 1}." if ordered else "-"
        # A listItem may contain paragraphs (inline text) and nested lists.
        # Inline text goes on the same line as the prefix; nested lists go
        # on subsequent lines (indented) so they render correctly in markdown.
        inline_parts: list[str] = []
        nested_parts: list[str] = []
        for child in item.get("content", []):
            if child.get("type") in ("bulletList", "orderedList"):
                nested = _render_list(
                    child.get("content", []),
                    depth + 1,
                    ordered=(child.get("type") == "orderedList"),
                )
                nested_parts.append(nested.rstrip("\n"))
            else:
                inline_parts.append(
                    _adf_nodes_to_markdown([child], depth).rstrip("\n")
                )
        item_text = " ".join(p.strip() for p in inline_parts if p.strip())
        lines.append(f"{indent}{prefix} {item_text}")
        for nested in nested_parts:
            lines.append(nested)
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# ADF H2 extractor (T-006)
# ---------------------------------------------------------------------------


def _normalize(s: str) -> str:
    """Normalize a heading string for alias matching."""
    return s.strip().lower().rstrip(":").strip()


def _heading_text(node: dict) -> str:
    """Extract plain text from a heading ADF node (ignores inline marks)."""
    return "".join(
        n.get("text", "")
        for n in node.get("content", [])
        if n.get("type") == "text"
    )


def _find_release_note_heading(content: list[dict]) -> int:
    """Return the index of the matching H2 release-note heading, or -1."""
    for i, node in enumerate(content):
        if node.get("type") == "heading" and node.get("attrs", {}).get("level") == 2:
            if _normalize(_heading_text(node)) in _RELEASE_NOTE_ALIASES:
                return i
    return -1


def _collect_section_nodes(content: list[dict], idx: int) -> list[dict]:
    """Return nodes from idx+1 up to (not including) the next heading of any level."""
    result: list[dict] = []
    for node in content[idx + 1 :]:
        if node.get("type") == "heading":
            break
        result.append(node)
    return result


def extract_release_note(issue: dict) -> str | None:
    """Extract the release note markdown block from an issue's ADF description.

    Returns None if the issue has no matching H2 (bucket: no_h2_no_skip).
    """
    description = (issue.get("fields") or {}).get("description")
    if not description:
        return None

    content = description.get("content", [])
    idx = _find_release_note_heading(content)
    if idx == -1:
        return None

    section_nodes = _collect_section_nodes(content, idx)
    if not section_nodes:
        return ""

    return _adf_nodes_to_markdown(section_nodes).strip()


# ---------------------------------------------------------------------------
# Bug Affects-Version four-state classifier (T-008)
# ---------------------------------------------------------------------------


def classify_affects_version(issue: dict) -> str:
    """Classify the Affects Version state of an issue.

    Returns one of: ``"populated"``, ``"unknown"``, ``"empty_with_skip"``,
    ``"empty_alone"``.

    Story and Task issuetypes short-circuit to ``"populated"`` — Affects
    Version logic is Bug-only.
    """
    fields = issue.get("fields") or {}
    issuetype = (fields.get("issuetype") or {}).get("name", "")

    if issuetype not in ("Bug",):
        return "populated"

    labels: set[str] = set(fields.get("labels") or [])
    versions = fields.get("versions")  # may be None (field absent) or list

    if versions is None:
        # Field absent — graceful degradation (TECHOPS-482 unmerged)
        return "empty_alone"

    if not versions:
        # Empty array
        if "skipReleaseNotes" in labels:
            return "empty_with_skip"
        return "empty_alone"

    names = {v.get("name") for v in versions}
    if names == {"Unknown"}:
        return "unknown"

    # Mixed Unknown + real versions → treat as populated
    return "populated"


# ---------------------------------------------------------------------------
# JQL fetcher (T-005)
# ---------------------------------------------------------------------------


def fetch_issues(client: Any, version: str) -> list[dict]:
    """Fetch all Done issues in a Fix Version via paginated JQL.

    Uses board filter 24722 — does NOT enumerate project keys.
    Returns a flat list of issue dicts.  Exits non-zero on unrecoverable errors.
    """
    jql = _JQL_TEMPLATE.format(version=version)
    fields = [
        "summary",
        "description",
        "issuetype",
        "labels",
        "versions",
        "project",
        "status",
    ]

    issues: list[dict] = []
    next_page_token: str | None = None

    while True:
        payload: dict[str, Any] = {
            "jql": jql,
            "fields": fields,
            "maxResults": 50,
        }
        if next_page_token:
            payload["nextPageToken"] = next_page_token

        try:
            resp = client.request("POST", "/rest/api/3/search/jql", json=payload)
        except RuntimeError as exc:
            error_text = str(exc)
            # Distinguish 4xx from other errors; 429 is already retried by JiraClient.
            if "-> 4" in error_text:
                print(
                    f"ERROR: Jira returned a client error fetching Fix Version "
                    f'"{version}": {error_text}',
                    file=sys.stderr,
                )
                sys.exit(EXIT_ERROR)
            raise

        if resp is None:
            break

        batch = resp.get("issues") or []
        issues.extend(batch)

        next_page_token = resp.get("nextPageToken")
        if not next_page_token:
            break

    return issues


# ---------------------------------------------------------------------------
# Pre-flight check (T-004)
# ---------------------------------------------------------------------------


def preflight_unknown_fix_version(client: Any) -> None:
    """Verify that Fix Version ``Unknown`` exists in all 9 federated projects.

    Exits with EXIT_PREFLIGHT (2) and an actionable error if any are missing.
    Exits with EXIT_ERROR (1) on Jira network / auth failures.
    """
    missing: list[str] = []

    for key in FEDERATED_PROJECTS:
        try:
            versions = client.request("GET", f"/rest/api/3/project/{key}/versions")
        except RuntimeError as exc:
            print(
                f"ERROR: Could not reach Jira to check Fix Versions for project "
                f"{key}: {exc}",
                file=sys.stderr,
            )
            sys.exit(EXIT_ERROR)

        if not any(v.get("name") == "Unknown" for v in (versions or [])):
            missing.append(key)

    if missing:
        missing_str = ", ".join(missing)
        print(
            f"ERROR: 'Unknown' Fix Version is missing in: {missing_str}",
            file=sys.stderr,
        )
        for key in missing:
            print(
                f"  Run: python3 jira/scripts/create_fix_versions.py "
                f"--project {key} --versions Unknown",
                file=sys.stderr,
            )
        sys.exit(EXIT_PREFLIGHT)


# ---------------------------------------------------------------------------
# Bucket counter + accumulator (T-009)
# ---------------------------------------------------------------------------


def _issue_key(issue: dict) -> str:
    return issue.get("key", "")


def _project_key(issue: dict) -> str:
    """Return the Jira project key for an issue (e.g. 'SECURE' from 'SECURE-1234')."""
    key = _issue_key(issue)
    return key.split("-")[0] if "-" in key else "UNKNOWN"


def accumulate_issues(
    issues: list[dict],
) -> tuple[list[dict], dict[str, int], dict[str, int]]:
    """Walk issues and compute buckets + entries + project counts for rendering.

    Returns:
        entries: list of dicts ready for render_notes_section()
        buckets: dict with seven bucket counts
        project_counts: dict mapping project key → total Done ticket count

    The invariant (per spec clarification) is:
        with_note_customer + skipped + no_h2_no_skip == total_done

    AV flag buckets (affects_version_empty_alone, affects_version_unknown) are
    OVERLAY counts on with_note_customer — they do NOT add to the sum.

    project_counts covers ALL Done tickets (not just those with notes) so the
    footer surfaces federated-project drift even when no ticket has a release note.
    """
    buckets: dict[str, int] = {
        "total_done": len(issues),
        "with_note_customer": 0,
        "with_note_internal": 0,  # always 0 in v1
        "skipped": 0,
        "no_h2_no_skip": 0,
        "affects_version_empty_alone": 0,
        "affects_version_unknown": 0,
    }

    entries: list[dict] = []
    project_counts: dict[str, int] = {}

    for issue in issues:
        fields = issue.get("fields") or {}
        labels: set[str] = set(fields.get("labels") or [])

        # Count every issue toward project totals (even skipped / no-H2).
        proj = _project_key(issue)
        project_counts[proj] = project_counts.get(proj, 0) + 1

        # skipReleaseNotes wins over everything else.
        if "skipReleaseNotes" in labels:
            buckets["skipped"] += 1
            continue

        # Attempt H2 extraction.
        note_md = extract_release_note(issue)

        if note_md is None:
            # No H2, no skip — flagged but not included in body.
            buckets["no_h2_no_skip"] += 1
            continue

        # Ticket has a release note; it goes into the customer-facing body.
        buckets["with_note_customer"] += 1

        # Determine AV overlay flags (Bugs only).
        av_state = classify_affects_version(issue)
        flags: list[str] = []

        if av_state == "empty_alone":
            buckets["affects_version_empty_alone"] += 1
            flags.append("empty Affects Version")
        elif av_state == "unknown":
            buckets["affects_version_unknown"] += 1
            flags.append("Unknown Affects Version")

        issuetype = (fields.get("issuetype") or {}).get("name", "")
        summary = fields.get("summary", "")

        entries.append(
            {
                "key": _issue_key(issue),
                "project": proj,
                "issuetype": issuetype,
                "summary": summary,
                "note_md": note_md,
                "flags": flags,
            }
        )

    return entries, buckets, project_counts


# ---------------------------------------------------------------------------
# Output renderer (T-010)
# ---------------------------------------------------------------------------

_ISSUETYPE_ORDER = {"Story": 0, "Task": 1, "Bug": 2}


def _sort_key(entry: dict) -> tuple[int, str]:
    """Sort key: issuetype group first, then issue key ascending."""
    order = _ISSUETYPE_ORDER.get(entry["issuetype"], 99)
    # Sort by project key + numeric part of issue key for stable natural sort.
    key = entry["key"]
    match = re.match(r"([A-Z]+)-(\d+)", key)
    if match:
        return (order, match.group(1), int(match.group(2)))
    return (order, key, 0)


def render_notes_section(entries: list[dict]) -> str:
    """Render the notes body: Stories/Tasks first, then Bugs, sorted by key."""
    if not entries:
        return "_No release notes found for this Fix Version._\n"

    sorted_entries = sorted(entries, key=_sort_key)
    parts: list[str] = []

    current_group: str | None = None
    for entry in sorted_entries:
        group = entry["issuetype"]
        if group != current_group:
            current_group = group
            parts.append(f"\n### {group}s\n")

        for flag in entry["flags"]:
            parts.append(f"[FLAG: {flag}]\n")

        parts.append(f"#### {entry['key']}: {entry['summary']}\n\n")
        if entry["note_md"]:
            parts.append(entry["note_md"] + "\n\n")

    return "".join(parts).lstrip("\n")


def render_completeness_report(buckets: dict[str, int], version_name: str) -> str:
    """Render the seven-bucket completeness table.

    The main table covers the three exclusive buckets that sum to total_done:
        with_note_customer + skipped + no_h2_no_skip == total_done

    A separate "Overlay flags" sub-section shows the AV flag counts, which
    are additional attributes ON with_note_customer tickets — they do NOT
    add to the sum.
    """
    total = buckets["total_done"]
    with_note = buckets["with_note_customer"]
    with_note_internal = buckets["with_note_internal"]
    skipped = buckets["skipped"]
    no_h2 = buckets["no_h2_no_skip"]
    av_empty = buckets["affects_version_empty_alone"]
    av_unknown = buckets["affects_version_unknown"]

    lines: list[str] = [
        f"## Release Notes Completeness — {version_name}",
        "",
        "| Bucket | Count |",
        "|---|---:|",
        f"| Total Done tickets in Fix Version | {total} |",
        f"| With release note (customer-facing) | {with_note} |",
        f"| With release note (internal-only) | {with_note_internal} |",
        f"| Skipped via `skipReleaseNotes` | {skipped} |",
        f"| Flagged: no H2 + no skip label | {no_h2} |",
        "",
        "**Completeness check:** "
        f"{with_note} (with note) + {skipped} (skipped) + {no_h2} (no H2) = "
        f"{with_note + skipped + no_h2} / {total} total",
        "",
        "### Overlay flags",
        "",
        "These counts are subsets of the _With release note_ row above.",
        "They flag tickets that need a closer look — they do **not** add to the sum.",
        "",
        "| Overlay flag | Count |",
        "|---|---:|",
        f"| Bugs: empty Affects Version (needs follow-up) | {av_empty} |",
        f"| Bugs: Affects Version = Unknown (needs investigation) | {av_unknown} |",
    ]

    return "\n".join(lines)


def render_output(
    version_name: str,
    entries: list[dict],
    buckets: dict[str, int],
    timestamp: str,
    project_counts: dict[str, int] | None = None,
) -> str:
    """Stitch all output sections into the final markdown string.

    project_counts covers ALL Done tickets (including skipped / no-H2) so the
    footer surfaces federated-project drift even when no ticket has a release note.
    If omitted, falls back to counting from entries only (backward-compatible).
    """
    total = buckets["total_done"]

    # Build project contribution footer.
    if project_counts is None:
        # Fallback: count from entries (used only in legacy / test callers that
        # haven't been updated to pass project_counts).
        project_counts = {}
        for entry in entries:
            proj = entry["project"]
            project_counts[proj] = project_counts.get(proj, 0) + 1

    footer_parts = [f"{k} ({v})" for k, v in sorted(project_counts.items())]
    footer = ", ".join(footer_parts) if footer_parts else "none"

    title_block = (
        f"# Release Notes — {version_name}\n\n"
        f"**Total Done tickets:** {total}  \n"
        f"**Generated:** {timestamp} UTC\n"
    )

    notes_body = render_notes_section(entries)
    completeness = render_completeness_report(buckets, version_name)

    return (
        title_block
        + "\n---\n\n"
        + notes_body
        + "\n---\n\n"
        + completeness
        + "\n\n"
        + f"**Projects encountered:** {footer}\n"
    )


# ---------------------------------------------------------------------------
# CLI entry point (T-003)
# ---------------------------------------------------------------------------


def main() -> int:
    """CLI entry point for aggregate_release_notes.

    Exit codes:
        0  success
        1  Jira / auth / unexpected runtime failure
        2  pre-flight failure / user input error
    """
    parser = argparse.ArgumentParser(
        description=(
            "Aggregate release notes from Done Jira tickets in a Fix Version.\n"
            "Output is markdown emitted to stdout."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--version",
        required=True,
        metavar="NAME",
        help='Jira Fix Version name, e.g. "Community 5.0.4", "Secure 5.2.0", "Platform 1.0.0", "MCP Changelog 1.0.0"',
    )

    args = parser.parse_args()
    version_name: str = args.version.strip()

    if not version_name:
        parser.error("--version cannot be empty")

    # Import here so tests can mock JiraClient before main() is called.
    try:
        from jira_client import JiraClient  # type: ignore[import]
    except ImportError:
        # Support running from the repo root (python jira/scripts/...)
        import importlib.util
        import os

        script_dir = os.path.dirname(os.path.abspath(__file__))
        spec = importlib.util.spec_from_file_location(
            "jira_client", os.path.join(script_dir, "jira_client.py")
        )
        module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(module)  # type: ignore[union-attr]
        JiraClient = module.JiraClient

    try:
        client = JiraClient()
    except KeyError as exc:
        print(
            f"ERROR: Missing required environment variable: {exc}\n"
            "Set JIRA_BASE_URL, JIRA_EMAIL, and JIRA_API_TOKEN.",
            file=sys.stderr,
        )
        return EXIT_ERROR

    # Pre-flight: Unknown Fix Version must exist in all federated projects.
    preflight_unknown_fix_version(client)

    # Fetch issues.
    try:
        issues = fetch_issues(client, version_name)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_ERROR

    if not issues:
        print(
            f'WARNING: No Done tickets found for Fix Version "{version_name}".',
            file=sys.stderr,
        )

    # Accumulate buckets, entries, and project counts.
    entries, buckets, project_counts = accumulate_issues(issues)

    # Render output.
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    output = render_output(version_name, entries, buckets, timestamp, project_counts)

    print(output)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
