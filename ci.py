"""
Post-scrape sanity checks.

The original version asserted a fixed row count per table, which worked while
every table was a nightly snapshot rebuilt from Testudo. Two things changed:

  * `instructors` is no longer replaced wholesale from PlanetTerp. It
    accumulates - from Testudo scrapes and from sixteen years of registrar
    grade exports - and reviews will eventually reference it with
    `on delete cascade`. A *shrinking* instructor table is now a data-loss
    signal, which is exactly what CI should catch and what a fixed floor of
    13,000 never would.

  * Instructor names are resolved rather than matched by string. A Testudo
    format change that breaks name parsing does not reduce any row count; it
    quietly fills `instructor_match_queue` while professor pages start showing
    no grade data. That failure is silent by construction, so it needs its own
    check.

So the thresholds here are of two kinds: absolute floors for the snapshot
tables, and non-decrease checks against the previous run for the accumulating
ones.
"""

from db import get_supabase_client
import json
import os
from pathlib import Path

import requests

# Where the previous run's counts are kept. In CI this is restored from the
# actions cache; locally it is just a file. A missing file is not a failure -
# the first run has nothing to compare against and only records a baseline.
COUNTS_FILE = Path(os.environ.get("CI_COUNTS_FILE", ".ci-counts.json"))

# Snapshot tables: rebuilt from Testudo every run, so an absolute floor is the
# right check and a big drop means the scrape broke.
ABSOLUTE_FLOORS = {
    "courses": 2000,
    "sections": 6000,
}

# Accumulating tables: compared against the previous run instead. The
# tolerance allows for genuine small corrections (a merged duplicate
# instructor, a corrected grade file) without allowing a wholesale delete.
NON_DECREASING = {
    "instructors": 0.98,
    "grades": 0.999,
}

# `active_instructors` legitimately swings between terms - far fewer people
# teach in the summer - so it gets a floor rather than a non-decrease check.
ACTIVE_INSTRUCTORS_FLOOR = 1000

# An unresolved queue this large means name parsing has broken, not that a few
# genuinely ambiguous professors turned up. Tune once the first backfill has
# shown what normal looks like.
MATCH_QUEUE_CEILING = int(os.environ.get("MATCH_QUEUE_CEILING", "500"))


def send_alert(subject: str, detail: str):
    """
    Sends an alert by opening a GitHub issue and tagging Andrew (@atcupps).
    This should be modified with a rotation if more people join.
    """
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        print("GITHUB_TOKEN is not set.")
        exit(1)
    repo = "jupiterp-umd/scraper"
    title = f"Scraper CI: {subject}"
    body = f"@atcupps {detail}"
    assignees = ["atcupps"]

    url = f"https://api.github.com/repos/{repo}/issues"

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json"
    }

    data = {
        "title": title,
        "body": body,
        "assignees": assignees
    }

    response = requests.post(url, headers=headers, json=data)
    if response.status_code != 201:
        print("Failed to create GitHub issue.")
        print(response.json())
        exit(1)


def count_rows(client, table: str) -> int:
    response = client.table(table).select("*", count="exact").limit(1).execute()
    return response.count or 0


def load_previous() -> dict:
    if not COUNTS_FILE.exists():
        return {}
    try:
        return json.loads(COUNTS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        print(f"Could not read {COUNTS_FILE}; treating this as a first run.")
        return {}


def verify_supabase_populated():
    client = get_supabase_client()
    previous = load_previous()
    current = {}
    failures = []

    for table, floor in ABSOLUTE_FLOORS.items():
        count = count_rows(client, table)
        current[table] = count
        print(f"{table}: {count} rows (floor {floor})")
        if count < floor:
            failures.append(f"`{table}` has {count} rows, below the floor of {floor}.")

    for table, ratio in NON_DECREASING.items():
        count = count_rows(client, table)
        current[table] = count
        before = previous.get(table)
        if before is None:
            print(f"{table}: {count} rows (no previous run to compare against)")
            continue
        floor = int(before * ratio)
        print(f"{table}: {count} rows (was {before}, floor {floor})")
        if count < floor:
            failures.append(
                f"`{table}` dropped from {before} to {count} rows, below the "
                f"{ratio:.1%} non-decrease threshold. This table accumulates and "
                f"should never shrink materially - check for an accidental "
                f"truncate before doing anything else."
            )

    count = count_rows(client, "active_instructors")
    current["active_instructors"] = count
    print(f"active_instructors: {count} rows (floor {ACTIVE_INSTRUCTORS_FLOOR})")
    if count < ACTIVE_INSTRUCTORS_FLOOR:
        failures.append(
            f"`active_instructors` has {count} rows, below {ACTIVE_INSTRUCTORS_FLOOR}. "
            f"Since this view is now keyed on instructor_id via section_instructors, "
            f"a collapse here usually means reconcile_instructors() failed rather "
            f"than that nobody is teaching."
        )

    queued = (
        client.table("instructor_match_queue")
        .select("id", count="exact")
        .is_("resolved_at", "null")
        .limit(1)
        .execute()
        .count
        or 0
    )
    current["instructor_match_queue_open"] = queued
    print(f"instructor_match_queue: {queued} unresolved (ceiling {MATCH_QUEUE_CEILING})")
    if queued > MATCH_QUEUE_CEILING:
        failures.append(
            f"`instructor_match_queue` has {queued} unresolved entries, above "
            f"{MATCH_QUEUE_CEILING}. A spike here means instructor names stopped "
            f"parsing - most likely a Testudo markup change. Professor pages will "
            f"be silently missing grade data until it is fixed."
        )

    _check_matview_freshness(client, failures)

    try:
        COUNTS_FILE.write_text(json.dumps(current, indent=2))
    except OSError as error:
        print(f"Could not record counts to {COUNTS_FILE}: {error}")

    if failures:
        print()
        for failure in failures:
            print(f"FAIL: {failure}")
        send_alert(
            f"{len(failures)} check(s) failed",
            "\n\n".join(f"- {failure}" for failure in failures),
        )
        exit(1)

    print("Successfully verified all tables.")


def _check_matview_freshness(client, failures: list):
    """
    A materialized view that was never refreshed after an ingest has no
    symptom: the site serves the previous term's numbers and looks entirely
    healthy. The refresh is recorded per ingest so that this can be checked.
    """
    latest = (
        client.table("grade_ingests")
        .select("term, source_file, ingested_at, matviews_refreshed_at")
        .order("ingested_at", desc=True)
        .limit(1)
        .execute()
        .data
    )
    if not latest:
        return

    ingest = latest[0]
    if ingest.get("matviews_refreshed_at") is None:
        failures.append(
            f"The most recent grade ingest ({ingest['source_file']}, term "
            f"{ingest['term']}) has no recorded matview refresh. "
            f"`instructor_grades` and `course_instructor_grades` are stale, and "
            f"the site is serving pre-ingest numbers while looking healthy. "
            f"Run `call refresh_grade_matviews();`."
        )


if __name__ == "__main__":
    verify_supabase_populated()
