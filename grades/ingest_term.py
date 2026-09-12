"""
Per-term ingest: parse one new registrar file, improve its instructor
attribution using Testudo, resolve every name to an instructor id, and refresh
the materialized views.

    python3 main.py ingest-term "./data/UMCP grade distribution Spring 2026.csv"

The plain `ingest` command remains what it was and is the right tool for
loading the historical archive in bulk. This one does three extra things that
only make sense for a term recent enough that Testudo still has it online:

  1. Where the registrar left the instructor blank, ask Testudo who was
     scheduled to teach that exact section, instead of carrying the lead
     section's instructor forward. Recorded as the `testudo` provenance tier,
     which ranks above `lead` and below `reported`.

  2. Resolve every instructor name to an `instructor_id`, queueing anything
     ambiguous rather than guessing.

  3. Refresh the matviews, and record that it happened. A matview that is
     never refreshed has no symptom - the site serves last term's numbers and
     looks healthy - so `ci.py` fails when the newest ingest has no refresh
     recorded against it.

Two caveats worth carrying into the UI rather than losing here:

  * Testudo lists the *scheduled* instructor, who is not always the person who
    taught the course or assigned the grades. Better than a carried guess,
    worse than a registrar attribution, hence its own tier.
  * Testudo only keeps a few years of past terms online. This improves data
    from here forward; it cannot retroactively fix 2011.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

# The scraper's Testudo code and the shared name helpers live one directory up.
# `grades/` is otherwise self-contained and is kept that way, so the path
# change is explicit rather than hidden in a package __init__.
#
# APPENDED, never inserted at the front: both directories contain a `db.py`,
# and `grades/db.py` - which never deletes - must keep winning over the
# scraper's, which is built around delete-then-insert.
_SCRAPER_ROOT = Path(__file__).resolve().parent.parent
if str(_SCRAPER_ROOT) not in sys.path:
    sys.path.append(str(_SCRAPER_ROOT))

from parse import SOURCE_LEAD, SOURCE_REPORTED  # noqa: E402

SOURCE_TESTUDO = "testudo"

# reported > testudo > lead > course. A row is only ever upgraded, never
# downgraded: a name the registrar printed is not replaced by Testudo's guess.
_PRECEDENCE = {SOURCE_REPORTED: 3, SOURCE_TESTUDO: 2, SOURCE_LEAD: 1, "course": 0}


def testudo_instructor_map(term: int, course_codes: list[str]) -> dict[tuple[str, str], list[str]]:
    """
    Scrape Testudo for one term and index instructors by (course_code, sec_code).

    Imported lazily so that `--print-output` and `verify` still run on a
    machine without beautifulsoup4 installed, matching how `grades/db.py`
    defers its supabase import.
    """
    from sections import scrape_sections

    sections = scrape_sections(str(term), course_codes)
    index: dict[tuple[str, str], list[str]] = {}
    for section in sections:
        key = (section["course_code"], section["sec_code"])
        index[key] = section.get("instructors") or []
    return index


def apply_testudo_attribution(
    records: list[dict],
    instructor_map: dict[tuple[str, str], list[str]],
) -> dict[str, int]:
    """
    Upgrade carried attributions to Testudo's scheduled instructor.

    Only rows the registrar did not name are touched, and only where their
    current attribution is weaker than `testudo`. A section Testudo lists with
    two instructors takes the first: the grade table holds one name per row,
    and picking the first is what the registrar's own exports do.
    """
    from names import is_denylisted, normalize_name

    counts = {"upgraded": 0, "unmatched": 0, "denylisted": 0}

    for record in records:
        # `instructor` is what the registrar printed on THIS row. Non-null
        # means a real attribution that must not be overwritten.
        if record.get("instructor"):
            continue

        current = record.get("instructor_source")
        if _PRECEDENCE.get(current, -1) >= _PRECEDENCE[SOURCE_TESTUDO]:
            continue

        names = instructor_map.get((record["course_code"], record["sec_code"]))
        if not names:
            counts["unmatched"] += 1
            continue

        chosen = next((n for n in names if not is_denylisted(n)), None)
        if chosen is None:
            counts["denylisted"] += 1
            continue

        record["instructor_name"] = chosen.strip()
        record["instructor_source"] = SOURCE_TESTUDO
        record["_instructor_norm"] = normalize_name(chosen)
        counts["upgraded"] += 1

    return counts


def resolve_instructor_ids(client, records: list[dict], term: int) -> dict[str, int]:
    """
    Resolve every distinct instructor name in this term's rows to an id.

    Distinct names, not rows: a large lecture lists the same professor across
    thirty sections. `create_if_missing` is true because this term's Testudo
    scrape has already created records for everyone currently teaching, so a
    name still unknown here came from the registrar and is a real person the
    scrape simply did not see.
    """
    from instructor_registry import SOURCE_REGISTRAR
    from names import is_denylisted, normalize_name

    counts = {"linked": 0, "queued": 0}
    seen: dict[str, int | None] = {}

    for record in records:
        raw = record.get("instructor_name")
        if not raw or is_denylisted(raw):
            continue
        normalized = normalize_name(raw)
        if normalized is None:
            continue

        if normalized not in seen:
            source = (
                SOURCE_TESTUDO
                if record.get("instructor_source") == SOURCE_TESTUDO
                else SOURCE_REGISTRAR
            )
            instructor_id = client.rpc(
                "link_instructor",
                {
                    "observed": raw.strip(),
                    "source": source,
                    "context": {
                        "course_code": record["course_code"],
                        "sec_code": record["sec_code"],
                        "term": term,
                    },
                    "create_if_missing": True,
                    "seen_term": term,
                },
            ).execute().data
            seen[normalized] = instructor_id
            counts["linked" if instructor_id is not None else "queued"] += 1

        record["instructor_id"] = seen[normalized]

    return counts


def refresh_matviews(client, term: int, digest: str) -> int:
    """
    Rebuild the instructor rollups and record that it happened.

    Returns elapsed milliseconds. The refresh runs `concurrently`, so reads are
    served from the previous contents throughout and the site does not stall
    behind an ingest.
    """
    started = time.monotonic()
    client.rpc("refresh_grade_matviews", {}).execute()
    elapsed_ms = int((time.monotonic() - started) * 1000)

    client.table("grade_ingests").update(
        {
            "matviews_refreshed_at": "now()",
            "matview_refresh_ms": elapsed_ms,
        }
    ).eq("term", term).eq("file_sha256", digest).execute()

    return elapsed_ms
