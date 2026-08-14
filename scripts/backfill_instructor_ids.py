#!/usr/bin/env python3
"""
Resolve `grades.instructor_name` to `grades.instructor_id` across the whole
grade table, then refresh the matviews.

    python3 scripts/backfill_instructor_ids.py --dry-run   # measure only
    python3 scripts/backfill_instructor_ids.py
    python3 scripts/backfill_instructor_ids.py --create-missing

Run `--dry-run` FIRST and read the match rate it prints. That number decides
how much manual work the rest of this migration actually carries, and it is
the one figure nobody can estimate in advance. If the queue comes back at ten
thousand entries, the plan is to raise the auto-accept confidence floor rather
than to triage ten thousand names by hand.

This is a script and not a migration on purpose. It touches ~210k rows and
tens of thousands of distinct names; a migration would hold one transaction
open for the duration and could not be resumed after an interruption. Here,
every name is independent and re-running is free - names already linked resolve
by exact alias hit on the second pass.

By default new instructors are NOT created. A sixteen-year-old registrar
spelling with no current section and nothing similar in the database is
exactly the case where a human should look before a professor page appears at
a permanent URL. `--create-missing` overrides that, and should only be used
after the queue has been triaged once and the remainder is understood.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter
from pathlib import Path

from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from instructor_registry import SOURCE_REGISTRAR  # noqa: E402
from names import is_denylisted, normalize_name  # noqa: E402

PAGE_SIZE = 1000


def distinct_instructor_names(client) -> dict[str, dict]:
    """
    Every distinct `instructor_name` in `grades`, with one example context.

    Paged rather than pulled in one request: PostgREST caps a response at
    1,000 rows by default and silently truncates past it, which would look
    like a suspiciously good match rate rather than an error.
    """
    names: dict[str, dict] = {}
    offset = 0

    while True:
        page = (
            client.table("grades")
            .select("instructor_name, course_code, term, sec_code, instructor_source")
            .not_.is_("instructor_name", "null")
            .is_("instructor_id", "null")
            .range(offset, offset + PAGE_SIZE - 1)
            .execute()
            .data
        )
        if not page:
            break

        for row in page:
            raw = row["instructor_name"]
            normalized = normalize_name(raw)
            if normalized is None or is_denylisted(raw):
                continue
            if normalized not in names:
                names[normalized] = {
                    "raw": raw.strip(),
                    "context": {
                        "course_code": row["course_code"],
                        "term": row["term"],
                        "sec_code": row["sec_code"],
                        "instructor_source": row["instructor_source"],
                    },
                    "rows": 0,
                }
            names[normalized]["rows"] += 1

        offset += len(page)
        print(f"  scanned {offset} unlinked grade rows, {len(names)} distinct names so far")
        if len(page) < PAGE_SIZE:
            break

    return names


def resolve_all(client, names: dict[str, dict], create_missing: bool) -> dict[str, int]:
    """Run every distinct name through the SQL resolver."""
    resolved: dict[str, int] = {}
    methods: Counter = Counter()

    for i, (normalized, info) in enumerate(names.items(), start=1):
        instructor_id = client.rpc(
            "link_instructor",
            {
                "observed": info["raw"],
                "source": SOURCE_REGISTRAR,
                "context": info["context"],
                "create_if_missing": create_missing,
                "seen_term": info["context"].get("term"),
            },
        ).execute().data

        if instructor_id is None:
            methods["queued"] += 1
        else:
            resolved[normalized] = instructor_id
            methods["linked"] += 1

        if i % 250 == 0:
            print(f"  resolved {i}/{len(names)} names ({methods['linked']} linked, {methods['queued']} queued)")

    return resolved


def apply_ids(client, names: dict[str, dict], resolved: dict[str, int]) -> int:
    """
    Write `instructor_id` back onto the grade rows.

    Matched on the exact `instructor_name` string rather than on the normalized
    form, because `instructor_name` is what the column actually holds and
    PostgREST cannot filter on a function of a column. Several raw spellings
    can normalize to the same key, so this groups them back out.
    """
    by_id: dict[int, list[str]] = {}
    for normalized, info in names.items():
        instructor_id = resolved.get(normalized)
        if instructor_id is not None:
            by_id.setdefault(instructor_id, []).append(info["raw"])

    updated = 0
    for instructor_id, raws in by_id.items():
        for raw in raws:
            response = (
                client.table("grades")
                .update({"instructor_id": instructor_id})
                .eq("instructor_name", raw)
                .is_("instructor_id", "null")
                .execute()
            )
            updated += len(response.data or [])
    return updated


def report(names: dict[str, dict], resolved: dict[str, int]) -> None:
    total_names = len(names)
    total_rows = sum(info["rows"] for info in names.values())
    linked_rows = sum(info["rows"] for k, info in names.items() if k in resolved)

    print()
    print("=" * 62)
    print(f"  distinct names      {total_names:>10,}")
    print(f"  resolved            {len(resolved):>10,}  ({_pct(len(resolved), total_names)})")
    print(f"  queued for a human  {total_names - len(resolved):>10,}")
    print()
    print(f"  grade rows affected {total_rows:>10,}")
    print(f"  rows that will link {linked_rows:>10,}  ({_pct(linked_rows, total_rows)})")
    print("=" * 62)
    print()
    print("The row percentage is the one that matters: a professor page shows")
    print("no grade data when its rows did not link, and every such failure is")
    print("silent - an empty section rather than an error.")


def _pct(part: int, whole: int) -> str:
    return f"{(100.0 * part / whole):.1f}%" if whole else "n/a"


def main() -> None:
    parser = argparse.ArgumentParser(description="Backfill grades.instructor_id")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Resolve and report the match rate without writing instructor_id",
    )
    parser.add_argument(
        "--create-missing",
        action="store_true",
        help="Create instructor records for names with no similar candidate at all",
    )
    parser.add_argument(
        "--skip-refresh",
        action="store_true",
        help="Do not refresh the materialized views afterwards",
    )
    args = parser.parse_args()

    load_dotenv()

    from db import get_supabase_client

    client = get_supabase_client()

    print("Collecting distinct instructor names from unlinked grade rows...")
    names = distinct_instructor_names(client)
    if not names:
        print("Nothing to do: every grade row with an instructor name is already linked.")
        return

    print(f"Resolving {len(names)} distinct names...")
    resolved = resolve_all(client, names, args.create_missing)
    report(names, resolved)

    if args.dry_run:
        print("--dry-run set; instructor_id not written.")
        print("Note that resolution itself is not read-only: confident matches")
        print("wrote alias rows and unresolved names were queued. That is")
        print("intentional and idempotent - re-running resolves them as exact hits.")
        return

    print("Writing instructor_id onto grade rows...")
    updated = apply_ids(client, names, resolved)
    print(f"Updated {updated:,} grade rows.")

    if args.skip_refresh:
        print("--skip-refresh set. The matviews are now STALE and the site will")
        print("serve pre-backfill numbers until refresh_grade_matviews() is run.")
        return

    print("Refreshing materialized views...")
    client.rpc("refresh_grade_matviews", {}).execute()
    print("Done.")


if __name__ == "__main__":
    main()
