"""Reusable Jira Cloud REST API client.

Handles auth, retries, rate limiting, and typed helpers for the operations used
across Liquibase Unified Workflow v0.2 setup.

Dry-run mode: set `dry_run=True` (constructor) or `JIRA_DRY_RUN=1` (env) to
intercept all mutating calls (POST/PUT/DELETE). Reads (GET) still hit the real
API so idempotence checks continue to work. Writes are logged and return
synthetic responses (`{"id": "<dryrun-N>", ...}`) so downstream logic proceeds.
"""

from __future__ import annotations

import itertools
import os
import sys
import time
from typing import Any

import requests
from dotenv import load_dotenv
from requests.auth import HTTPBasicAuth

load_dotenv()

_DRY_RUN_COUNTER = itertools.count(1)


def _synthesize_dry_run_response(method: str, path: str, body: dict | None) -> Any:
    """Fake a response shape matching what each real endpoint returns."""
    if method == "DELETE":
        return None
    if method == "PUT":
        # Most PUTs return 204 / null. Some (priority scheme) return {"updated": ...}.
        return None

    # POST — return synthetic create response. Shape varies by endpoint; provide
    # the common keys scripts depend on.
    n = next(_DRY_RUN_COUNTER)
    fake_id = f"dryrun-{n}"
    resp: dict[str, Any] = {"id": fake_id}

    if "/rest/api/3/project" in path and path.endswith("/project"):
        key = (body or {}).get("key", f"DRY{n}")
        resp.update({"id": 900000 + n, "key": key})
    elif "/issuetypescheme" in path and "project" not in path:
        resp["issueTypeSchemeId"] = str(900000 + n)
    elif "/rest/api/3/bulk/issues/move" in path:
        resp = {"taskId": fake_id}
    elif "/rest/api/3/bulk/queue" in path:
        resp = {"status": "COMPLETE", "progressPercent": 100}

    return resp


class JiraClient:
    def __init__(
        self,
        base_url: str | None = None,
        email: str | None = None,
        token: str | None = None,
        dry_run: bool | None = None,
    ) -> None:
        self.base_url = (base_url or os.environ["JIRA_BASE_URL"]).rstrip("/")
        self.auth = HTTPBasicAuth(
            email or os.environ["JIRA_EMAIL"],
            token or os.environ["JIRA_API_TOKEN"],
        )
        self.session = requests.Session()
        self.session.auth = self.auth
        self.session.headers.update(
            {"Accept": "application/json", "Content-Type": "application/json"}
        )
        if dry_run is None:
            dry_run = os.environ.get("JIRA_DRY_RUN", "").lower() in {
                "1",
                "true",
                "yes",
            }
        self.dry_run = dry_run
        if self.dry_run:
            print("[dry-run] JiraClient mutating calls will be logged, not executed")

    # POST endpoints that are semantically reads (body is a query, not a mutation).
    # These must pass through even in dry-run so idempotence / discovery keeps working.
    _READ_ONLY_POST_PATHS = ("/rest/api/3/search/jql",)

    def request(self, method: str, path: str, **kwargs: Any) -> Any:
        url = path if path.startswith("http") else f"{self.base_url}{path}"
        is_read_only_post = method.upper() == "POST" and any(
            path.startswith(p) for p in self._READ_ONLY_POST_PATHS
        )
        if self.dry_run and method.upper() != "GET" and not is_read_only_post:
            body = kwargs.get("json")
            print(f"[dry-run] {method} {path}")
            if body:
                preview = str(body)
                if len(preview) > 200:
                    preview = preview[:200] + "..."
                print(f"[dry-run]   body: {preview}")
            return _synthesize_dry_run_response(method.upper(), path, body)
        for attempt in range(5):
            r = self.session.request(method, url, **kwargs)
            if r.status_code == 429:
                time.sleep(2**attempt)
                continue
            if r.status_code >= 400:
                raise RuntimeError(f"{method} {url} -> {r.status_code}: {r.text}")
            return r.json() if r.content else None
        raise RuntimeError(f"Rate-limited after retries: {method} {url}")

    # --- Projects ---

    def create_project(self, payload: dict) -> dict:
        return self.request("POST", "/rest/api/3/project", json=payload)

    def get_project(self, key: str) -> dict:
        return self.request("GET", f"/rest/api/3/project/{key}")

    # --- Schemes ---

    def apply_workflow_scheme(self, project_id: str, scheme_id: str) -> None:
        self.request(
            "PUT",
            "/rest/api/3/workflowscheme/project",
            json={"projectId": project_id, "workflowSchemeId": scheme_id},
        )

    def apply_issue_type_scheme(self, project_id: str, scheme_id: str) -> None:
        self.request(
            "PUT",
            "/rest/api/3/issuetypescheme/project",
            json={"projectId": project_id, "issueTypeSchemeId": scheme_id},
        )

    def apply_issue_type_screen_scheme(self, project_id: str, scheme_id: str) -> None:
        self.request(
            "PUT",
            "/rest/api/3/issuetypescreenscheme/project",
            json={"projectId": project_id, "issueTypeScreenSchemeId": scheme_id},
        )

    def apply_field_configuration_scheme(
        self, project_id: str, scheme_id: str
    ) -> None:
        self.request(
            "PUT",
            "/rest/api/3/fieldconfigurationscheme/project",
            json={
                "projectId": project_id,
                "fieldConfigurationSchemeId": scheme_id,
            },
        )

    def apply_permission_scheme(self, project_key: str, scheme_id: int) -> None:
        self.request(
            "PUT",
            f"/rest/api/3/project/{project_key}/permissionscheme",
            json={"id": scheme_id},
        )

    # --- Priority scheme (async / quirky) ---

    def assign_priority_scheme(
        self, scheme_id: int, project_id: int, default_priority_id: int = 3
    ) -> None:
        """Returns HTTP 202. Atlassian has known issues persisting the add
        asynchronously; a UI fallback may still be required.
        """
        self.request(
            "PUT",
            f"/rest/api/3/priorityscheme/{scheme_id}",
            json={
                "projects": {"ids": {"add": [project_id]}},
                "defaultPriorityId": default_priority_id,
            },
        )

    # --- Versions ---

    def create_version(self, project_id: int, name: str) -> dict:
        return self.request(
            "POST",
            "/rest/api/3/version",
            json={"name": name, "projectId": project_id, "released": False},
        )

    # --- Groups ---

    def create_group(self, name: str) -> dict:
        return self.request("POST", "/rest/api/3/group", json={"name": name})

    def add_user_to_group(self, group_name: str, account_id: str) -> dict:
        return self.request(
            "POST",
            f"/rest/api/3/group/user?groupname={group_name}",
            json={"accountId": account_id},
        )

    def find_user(self, query: str) -> dict | None:
        results = self.request("GET", f"/rest/api/3/user/search?query={query}")
        return results[0] if results else None

    # --- Permission scheme ---

    def create_permission_scheme(self, payload: dict) -> dict:
        return self.request("POST", "/rest/api/3/permissionscheme", json=payload)

    def find_permission_scheme(self, name: str) -> dict | None:
        resp = self.request("GET", "/rest/api/3/permissionscheme")
        for s in resp.get("permissionSchemes", []):
            if s.get("name") == name:
                return s
        return None

    def get_permission_grants(self, scheme_id: int) -> list[dict]:
        """Returns all grants on a permission scheme with holder details expanded."""
        resp = self.request(
            "GET",
            f"/rest/api/3/permissionscheme/{scheme_id}/permission?expand=permissions",
        )
        return resp.get("permissions", [])

    def add_permission_grant(
        self, scheme_id: int, holder_type: str, holder_value: str, permission: str
    ) -> dict:
        return self.request(
            "POST",
            f"/rest/api/3/permissionscheme/{scheme_id}/permission",
            json={
                "holder": {"type": holder_type, "parameter": holder_value},
                "permission": permission,
            },
        )

    def remove_permission_grant(self, scheme_id: int, permission_id: int) -> None:
        self.request(
            "DELETE",
            f"/rest/api/3/permissionscheme/{scheme_id}/permission/{permission_id}",
        )

    # --- Issues ---

    def edit_issue(self, key: str, fields: dict) -> None:
        self.request(
            "PUT", f"/rest/api/3/issue/{key}", json={"fields": fields}
        )

    def transition_issue(self, key: str, transition_id: str) -> None:
        self.request(
            "POST",
            f"/rest/api/3/issue/{key}/transitions",
            json={"transition": {"id": transition_id}},
        )

    def get_issue(self, key: str, fields: str = "*all", expand: str = "") -> dict:
        q = f"?fields={fields}"
        if expand:
            q += f"&expand={expand}"
        return self.request("GET", f"/rest/api/3/issue/{key}{q}")

    def bulk_move(self, target_project_id: int, target_issue_type_id: int, keys: list[str]) -> str:
        resp = self.request(
            "POST",
            "/rest/api/3/bulk/issues/move",
            json={
                "sendBulkNotification": False,
                "targetToSourcesMapping": {
                    f"{target_project_id},{target_issue_type_id}": {
                        "issueIdsOrKeys": keys,
                        "inferClassificationDefaults": True,
                        "inferFieldDefaults": True,
                        "inferStatusDefaults": True,
                        "inferSubtaskTypeDefault": True,
                    }
                },
            },
        )
        return resp["taskId"]

    def wait_for_bulk_task(self, task_id: str, timeout: int = 120) -> dict:
        if self.dry_run or str(task_id).startswith("dryrun-"):
            return {"status": "COMPLETE", "progressPercent": 100, "taskId": task_id}
        deadline = time.time() + timeout
        while time.time() < deadline:
            task = self.request("GET", f"/rest/api/3/bulk/queue/{task_id}")
            if task["status"] in ("COMPLETE", "FAILED"):
                return task
            time.sleep(3)
        raise TimeoutError(f"Bulk task {task_id} did not finish in {timeout}s")

    # --- Boards (greenhopper private API) ---

    def set_board_columns(
        self,
        board_id: int,
        mapped_columns: list[dict],
        statistics_field_id: str | None = None,
    ) -> dict:
        """Update board columns via the private greenhopper endpoint.

        `statistics_field_id` controls Jira's "Column constraints" type
        (UI dropdown). Known values:
            "none_"               → constraints disabled (max stored but ignored)
            "issueCount_"         → enforce on raw issue count
            "issueCountExclSubs_" → enforce on issue count, excluding subtasks

        When omitted, the current value is read from the live board so we
        don't silently disable enforcement on a board that already has it
        turned on.
        """
        if statistics_field_id is None:
            current = self.request(
                "GET",
                f"/rest/greenhopper/1.0/rapidviewconfig/editmodel?rapidViewId={board_id}",
            )
            statistics_field_id = (
                current.get("rapidListConfig", {})
                .get("currentStatisticsField", {})
                .get("id", "none_")
            )
        return self.request(
            "PUT",
            "/rest/greenhopper/1.0/rapidviewconfig/columns",
            json={
                "currentStatisticsField": {"id": statistics_field_id},
                "rapidViewId": board_id,
                "mappedColumns": mapped_columns,
            },
        )

    def get_board_constraint_type(self, board_id: int) -> str:
        """Returns the current statistics field id (constraint type)."""
        resp = self.request(
            "GET",
            f"/rest/greenhopper/1.0/rapidviewconfig/editmodel?rapidViewId={board_id}",
        )
        return (
            (resp or {})
            .get("rapidListConfig", {})
            .get("currentStatisticsField", {})
            .get("id", "none_")
        )

    # Quick filters and swimlanes are READ-ONLY via API on Jira Cloud as of 2026.
    # Atlassian has retired the greenhopper write endpoints (POST/PUT/DELETE on
    # `/rapidviewconfig/quickFilter*` and `/rapidviewconfig/swimlane*` all return
    # 404), and the public Agile API exposes no write surface either (POST to
    # `/rest/agile/1.0/board/{id}/quickfilter` returns 405). Configure changes
    # via the Jira UI; use these helpers + the configure_board_filters.py
    # auditor to verify the live board against `config/board_filters.json`.

    def get_board_quick_filters(self, board_id: int) -> list[dict]:
        """Reads via the public Agile API. Normalises Agile's `jql` field to
        `query` so it lines up with `config/board_filters.json`.
        """
        resp = self.request(
            "GET",
            f"/rest/agile/1.0/board/{board_id}/quickfilter",
        )
        return [
            {
                "id": f["id"],
                "name": f["name"],
                "query": f.get("jql", ""),
                "description": f.get("description", ""),
                "position": f.get("position", 0),
            }
            for f in (resp or {}).get("values", [])
        ]

    def get_board_swimlanes(self, board_id: int) -> list[dict]:
        """Read swimlanes from the greenhopper edit model — the only supported
        read path on this tenant. Returned dicts include `isDefault`.
        """
        resp = self.request(
            "GET",
            f"/rest/greenhopper/1.0/rapidviewconfig/editmodel?rapidViewId={board_id}",
        )
        return (resp or {}).get("swimlanesConfig", {}).get("swimlanes", [])

    def get_board_swimlane_strategy(self, board_id: int) -> str:
        resp = self.request(
            "GET",
            f"/rest/greenhopper/1.0/rapidviewconfig/editmodel?rapidViewId={board_id}",
        )
        return (resp or {}).get("swimlanesConfig", {}).get("swimlaneStrategy", "")

    def get_board_columns_with_limits(self, board_id: int) -> list[dict]:
        """Returns column entries from `rapidListConfig.mappedColumns`, each
        carrying `name`, `min`, `max` (both strings — empty when unset),
        `mappedStatuses`, and `isKanPlanColumn`. Used to audit WIP limits.
        """
        resp = self.request(
            "GET",
            f"/rest/greenhopper/1.0/rapidviewconfig/editmodel?rapidViewId={board_id}",
        )
        return (resp or {}).get("rapidListConfig", {}).get("mappedColumns", [])

    def set_board_wip_limits(
        self,
        board_id: int,
        max_by_column_name: dict[str, int | str],
        constraint_type_id: str = "issueCount_",
    ) -> dict:
        """Update per-column WIP `max` values via the `/columns` endpoint
        and switch the constraint type so the modern Spaces UI actually
        enforces them.

        `/columns` is a whole-list PUT — it replaces the entire column
        configuration, not just the bits we care about. To avoid clobbering
        the live status mapping, we GET the current `mappedColumns`,
        rewrite `max` only on columns named in `max_by_column_name`, and
        PUT the resulting list back. Min values, status assignments, and
        Kanplan flags are preserved as read.

        `constraint_type_id` defaults to `issueCount_` because if the
        caller is setting WIP limits, they almost certainly want them
        enforced. The legacy Jira board respected `max` regardless; the
        modern Spaces UI only does when the constraint type is set.
        """
        current = self.get_board_columns_with_limits(board_id)
        rewritten: list[dict] = []
        for col in current:
            new_max = max_by_column_name.get(col["name"])
            rewritten.append(
                {
                    "name": col["name"],
                    "mappedStatuses": [
                        {"id": str(s["id"])}
                        for s in col.get("mappedStatuses", [])
                    ],
                    "min": col.get("min", ""),
                    "max": str(new_max) if new_max is not None else col.get("max", ""),
                    "isKanPlanColumn": col.get("isKanPlanColumn", False),
                }
            )
        return self.set_board_columns(
            board_id, rewritten, statistics_field_id=constraint_type_id
        )

    # --- Field config ---

    def set_field_required(
        self, field_config_id: int, field_id: str, required: bool, hidden: bool = False
    ) -> None:
        self.request(
            "PUT",
            f"/rest/api/3/fieldconfiguration/{field_config_id}/fields",
            json={
                "fieldConfigurationItems": [
                    {"id": field_id, "isRequired": required, "isHidden": hidden}
                ]
            },
        )

    # --- Screens ---

    def add_field_to_screen(self, screen_id: int, tab_id: int, field_id: str) -> dict:
        return self.request(
            "POST",
            f"/rest/api/3/screens/{screen_id}/tabs/{tab_id}/fields",
            json={"fieldId": field_id},
        )

    def remove_field_from_screen(self, screen_id: int, tab_id: int, field_id: str) -> None:
        self.request(
            "DELETE",
            f"/rest/api/3/screens/{screen_id}/tabs/{tab_id}/fields/{field_id}",
        )

    # --- Search helpers for idempotent bootstrap ---

    @staticmethod
    def _warn_if_truncated(resp: dict, label: str, page_size: int = 100) -> None:
        """Warn to stderr if a paginated /search response looks truncated.

        Jira Cloud paginated endpoints return isLast (True/False). If missing,
        fall back to comparing len(values) against the requested page size.
        """
        is_last = resp.get("isLast")
        values = resp.get("values", [])
        if is_last is False or (is_last is None and len(values) >= page_size):
            print(
                f"WARNING: {label} search returned {len(values)} results — "
                f"may be truncated at the page-size limit. "
                f"find_* lookup could miss existing entities and create duplicates.",
                file=sys.stderr,
            )

    def find_workflow(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/workflow/search?workflowName={name}&expand=statuses"
        )
        self._warn_if_truncated(resp, f"workflow={name}")
        for v in resp.get("values", []):
            if v.get("id", {}).get("name") == name:
                return v
        return None

    def find_workflow_scheme(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/workflowscheme?maxResults=100&queryString={name}"
        )
        self._warn_if_truncated(resp, f"workflow_scheme={name}")
        for v in resp.get("values", []):
            if v.get("name") == name:
                return v
        return None

    def find_issue_type_scheme(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/issuetypescheme?maxResults=100&queryString={name}"
        )
        self._warn_if_truncated(resp, f"issue_type_scheme={name}")
        for v in resp.get("values", []):
            if v.get("name") == name:
                return v
        return None

    def find_screen(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/screens?maxResults=100&queryString={name}"
        )
        self._warn_if_truncated(resp, f"screen={name}")
        for v in resp.get("values", []):
            if v.get("name") == name:
                return v
        return None

    def find_screen_scheme(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/screenscheme?maxResults=100&queryString={name}"
        )
        self._warn_if_truncated(resp, f"screen_scheme={name}")
        for v in resp.get("values", []):
            if v.get("name") == name:
                return v
        return None

    def find_issue_type_screen_scheme(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/issuetypescreenscheme?maxResults=100&queryString={name}"
        )
        self._warn_if_truncated(resp, f"issue_type_screen_scheme={name}")
        for v in resp.get("values", []):
            if v.get("name") == name:
                return v
        return None

    def find_field_configuration(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/fieldconfiguration?maxResults=100"
        )
        self._warn_if_truncated(resp, f"field_configuration={name}")
        for v in resp.get("values", []):
            if v.get("name") == name:
                return v
        return None

    def find_field_configuration_scheme(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/fieldconfigurationscheme?maxResults=100"
        )
        self._warn_if_truncated(resp, f"field_configuration_scheme={name}")
        for v in resp.get("values", []):
            if v.get("name") == name:
                return v
        return None

    def find_priority_scheme(self, name: str) -> dict | None:
        resp = self.request(
            "GET", f"/rest/api/3/priorityscheme?maxResults=100"
        )
        self._warn_if_truncated(resp, f"priority_scheme={name}")
        for v in resp.get("values", []):
            if v.get("name") == name:
                return v
        return None

    # --- Saved filters ---

    def find_filter_by_name(self, name: str) -> dict | None:
        """GET /rest/api/3/filter/search?filterName=<name>&expand=jql,description
        filterName is a substring (not exact) match on Jira's side, so we
        post-filter every page for exact-name equality and iterate until
        isLast is true (or we run out of values). Returns the matched
        filter dict or None.
        """
        start_at = 0
        while True:
            resp = self.request(
                "GET",
                f"/rest/api/3/filter/search?filterName={name}&expand=jql,description&startAt={start_at}",
            )
            values = resp.get("values", [])
            for v in values:
                if v.get("name") == name:
                    return v
            if resp.get("isLast", True):
                return None
            if not values:
                # Defensive: Jira said "more pages" but returned no rows. Avoid infinite loop.
                return None
            start_at += len(values)

    def create_filter(self, payload: dict) -> dict:
        """POST /rest/api/3/filter with {name, jql, description}.
        Returns the created filter dict including `id`. Filter is private
        to the caller until permissions are added.
        """
        return self.request("POST", "/rest/api/3/filter", json=payload)

    def update_filter(self, filter_id: str, payload: dict) -> dict:
        """PUT /rest/api/3/filter/{filter_id} — whole-object replace.
        Used only when live JQL diverges from config.
        """
        return self.request("PUT", f"/rest/api/3/filter/{filter_id}", json=payload)

    def get_filter_permissions(self, filter_id: str) -> list[dict]:
        """GET /rest/api/3/filter/{filter_id}/permission.
        Returns the current share-permission list. Used to compute the
        add-if-not-present diff.
        """
        return self.request("GET", f"/rest/api/3/filter/{filter_id}/permission")

    def add_filter_permission(self, filter_id: str, permission: dict) -> dict:
        """POST /rest/api/3/filter/{filter_id}/permission with a single
        API-shape permission payload. Project form:
        {"type": "project", "project": {"id": "<id>"}}. Group form (reserved):
        {"type": "group", "groupname": "<name>"}.

        The client expects API shape — *not* the config shape. The
        config-to-API transformation happens in manage_saved_filters.py
        via _to_api_permission(). No bulk endpoint exists — one call per permission.
        """
        return self.request(
            "POST",
            f"/rest/api/3/filter/{filter_id}/permission",
            json=permission,
        )

    # --- Creators for bootstrap ---

    def create_workflow_scheme(self, name: str, description: str, default_workflow_name: str) -> dict:
        return self.request(
            "POST",
            "/rest/api/3/workflowscheme",
            json={
                "name": name,
                "description": description,
                "defaultWorkflow": default_workflow_name,
            },
        )

    def create_issue_type_scheme(
        self, name: str, description: str, default_id: str, ids: list[str]
    ) -> dict:
        return self.request(
            "POST",
            "/rest/api/3/issuetypescheme",
            json={
                "name": name,
                "description": description,
                "defaultIssueTypeId": default_id,
                "issueTypeIds": ids,
            },
        )

    def create_screen(self, name: str, description: str) -> dict:
        return self.request(
            "POST",
            "/rest/api/3/screens",
            json={"name": name, "description": description},
        )

    def get_screen_tabs(self, screen_id: int) -> list[dict]:
        return self.request("GET", f"/rest/api/3/screens/{screen_id}/tabs")

    def create_screen_scheme(
        self, name: str, description: str, default_screen_id: int
    ) -> dict:
        return self.request(
            "POST",
            "/rest/api/3/screenscheme",
            json={
                "name": name,
                "description": description,
                "screens": {"default": default_screen_id},
            },
        )

    def create_issue_type_screen_scheme(
        self, name: str, description: str, mappings: list[dict]
    ) -> dict:
        return self.request(
            "POST",
            "/rest/api/3/issuetypescreenscheme",
            json={
                "name": name,
                "description": description,
                "issueTypeMappings": mappings,
            },
        )

    def create_field_configuration(self, name: str, description: str) -> dict:
        return self.request(
            "POST",
            "/rest/api/3/fieldconfiguration",
            json={"name": name, "description": description},
        )

    def create_field_configuration_scheme(
        self, name: str, description: str
    ) -> dict:
        return self.request(
            "POST",
            "/rest/api/3/fieldconfigurationscheme",
            json={"name": name, "description": description},
        )

    def create_priority_scheme(
        self,
        name: str,
        description: str,
        priority_ids: list[int],
        default_priority_id: int,
        project_ids: list[int] | None = None,
    ) -> dict:
        payload = {
            "name": name,
            "description": description,
            "priorityIds": priority_ids,
            "defaultPriorityId": default_priority_id,
        }
        if project_ids:
            payload["projectIds"] = project_ids
        return self.request("POST", "/rest/api/3/priorityscheme", json=payload)
