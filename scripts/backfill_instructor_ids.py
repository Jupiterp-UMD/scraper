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
# Normalization and the denylist now happen inside unlinked_instructor_names(),
# so the Python implementations are no longer called here. They remain the
# source of truth for the scraper and are checked against the SQL ones by
# db/tests/name_parity.sql.

PAGE_SIZE = 1000

# Names per link_instructors_bulk() call. Sized against the statement timeout
# rather than against memory: each name costs a resolve_instructor(), so a
# batch has to finish inside the timeout PostgREST enforces on the call.
RESOLVE_BATCH = 250

# Resolved names per apply_instructor_ids() call. Each entry is one UPDATE
# predicate, not one statement, so this can be larger.
APPLY_BATCH = 500


def distinct_instructor_names(client) -> dict[str, dict]:
    """
    Every distinct `instructor_name` in `grades`, with one example context.

    The aggregation happens in the database (`unlinked_instructor_names`)
    rather than by paging 200k rows into Python to deduplicate them here. Still
    paged, because PostgREST caps a response at 1,000 rows and silently
    truncates past it, which would look like a suspiciously good match rate
    rather than an error.

    `variants` carries every raw spelling that normalizes to the same name.
    "Jonathan K. Lazar" and "Jonathan K Lazar" are one person written two ways,
    and the write-back has to update both -- keeping only the first spelling
    seen is how grade rows end up permanently unlinked.
    """
    names: dict[str, dict] = {}
    offset = 0

    while True:
        page = (
            client.rpc(
                "unlinked_instructor_names",
                {"page_limit": PAGE_SIZE, "page_offset": offset},
            )
            .execute()
            .data
        )
        if not page:
            break

        for row in page:
            names[row["name_norm"]] = {
                "raw": row["observed"],
                "variants": row["variants"],
                "context": {
                    "course_code": row["course_code"],
                    "term": row["term"],
                    "sec_code": row["sec_code"],
                    "instructor_source": row["instructor_source"],
                },
                "rows": row["row_count"],
            }

        offset += len(page)
        print(f"  {len(names)} distinct names so far")
        if len(page) < PAGE_SIZE:
            break

    return names


def resolve_all(client, names: dict[str, dict], create_missing: bool) -> dict[str, int]:
    """
    Run every distinct name through the SQL resolver, a batch at a time.

    One call per name meant ~14,000 round trips to resolve ~14,000 names, and
    the round trip was the expensive part: the resolution itself is a few
    milliseconds. `link_instructors_bulk` runs a whole batch server-side.

    A batch is one statement, so a failure rolls the batch back rather than
    leaving it half-applied. Re-running is free either way -- a name resolved
    on a previous pass comes back as an exact alias hit.
    """
    resolved: dict[str, int] = {}
    methods: Counter = Counter()
    items = list(names.items())

    for start in range(0, len(items), RESOLVE_BATCH):
        chunk = items[start : start + RESOLVE_BATCH]
        batch = [
            {
                "name_norm": normalized,
                "observed": info["raw"],
                "context": info["context"],
                "seen_term": info["context"].get("term"),
            }
            for normalized, info in chunk
        ]

        outcome = (
            client.rpc(
                "link_instructors_bulk",
                {
                    "batch": batch,
                    "p_source": SOURCE_REGISTRAR,
                    "p_create_if_missing": create_missing,
                },
            )
            .execute()
            .data
            or []
        )

        for entry in outcome:
            if entry["instructor_id"] is None:
                methods["queued"] += 1
            else:
                resolved[entry["name_norm"]] = entry["instructor_id"]
                methods["linked"] += 1

        done = min(start + RESOLVE_BATCH, len(items))
        print(f"  resolved {done}/{len(items)} names ({methods['linked']} linked, {methods['queued']} queued)")

    return resolved


def apply_ids(client, names: dict[str, dict], resolved: dict[str, int]) -> int:
    """
    Write `instructor_id` back onto the grade rows.

    Matched on the exact `instructor_name` strings rather than on the
    normalized form: `instructor_name` is what the column holds, and matching
    it directly uses `grades_instructor_idx` where a function of the column
    would not.

    Every spelling that normalized to a resolved name is sent, not just the one
    the aggregation happened to pick as representative. 14,045 raw spellings
    collapse to 13,958 names, and the 87 that differ only in punctuation or
    case belong to the same person -- updating one and not the others leaves
    real grade rows unlinked, which shows up as a professor page missing terms
    rather than as an error.
    """
    entries = [
        {"instructor_id": resolved[normalized], "variants": info["variants"]}
        for normalized, info in names.items()
        if normalized in resolved
    ]

    updated = 0
    for start in range(0, len(entries), APPLY_BATCH):
        chunk = entries[start : start + APPLY_BATCH]
        updated += client.rpc("apply_instructor_ids", {"batch": chunk}).execute().data or 0
        print(f"  wrote {min(start + APPLY_BATCH, len(entries))}/{len(entries)} names, {updated:,} rows so far")

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
