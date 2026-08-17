"""
Instructor identity, from the scraper's side.

Jupiterp used to get its instructor list from PlanetTerp, wholesale, nightly.
It now owns that list: instructors originate from Testudo section scrapes and
from sixteen years of registrar grade exports, and every observed spelling of a
name becomes an alias pointing at one instructor record.

The matching itself is NOT implemented here. It lives in SQL
(`resolve_instructor` / `link_instructor`, db/migrations/0007) and is called
through PostgREST, so that the nightly section scrape and the one-off grade
backfill cannot possibly disagree about who a name refers to. A name resolved
one way by one and another way by the other produces a duplicate instructor
whose grade history is split across two professor pages, which is both the most
likely failure of this migration and the most tedious to undo.

What lives here is the surrounding workflow: deduplicating names before they
reach the database, keeping `section_instructors` in step with each scrape, and
reporting how much ended up in the human queue.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Iterable

from names import is_denylisted, normalize_name

if TYPE_CHECKING:  # pragma: no cover
    from supabase import Client

# PostgREST rejects very large request bodies, and a smaller batch makes a
# failed request identifiable rather than "something in these 4000 rows".
CHUNK_SIZE = 500

# Source label recorded on aliases and queue entries. Constrained by a check
# constraint in 0002, so a typo here fails loudly rather than silently
# inserting an unfilterable row.
SOURCE_TESTUDO = "testudo"
SOURCE_REGISTRAR = "registrar"
SOURCE_PLANETTERP = "planetterp"


class ReconcileReport:
    """What one reconciliation run did, for logging and for CI thresholds."""

    def __init__(self) -> None:
        self.observed = 0
        self.denylisted = 0
        self.resolved = 0
        self.created = 0
        self.queued = 0
        self.section_links = 0

    def __str__(self) -> str:
        return (
            f"{self.observed} distinct names: {self.resolved} resolved, "
            f"{self.created} created, {self.queued} queued, "
            f"{self.denylisted} skipped as placeholders; "
            f"{self.section_links} section links"
        )


def distinct_instructor_names(sections_data: Iterable[dict]) -> dict[str, str]:
    """
    Every real instructor name in a section scrape, keyed by normalized form.

    Deduplicating here rather than in the database matters more than it looks:
    a large lecture course lists the same professor on thirty sections, and a
    department scrape would otherwise issue thousands of identical resolution
    calls. The value kept for each key is the first raw spelling seen, which is
    what gets stored as `alias_raw` for the audit trail.
    """
    names: dict[str, str] = {}
    for section in sections_data:
        for raw in section.get("instructors") or []:
            if is_denylisted(raw):
                continue
            normalized = normalize_name(raw)
            if normalized is not None and normalized not in names:
                names[normalized] = raw.strip()
    return names


def reconcile_instructors(
    sections_data: list[dict],
    term: int | None,
    print_output: bool,
    client: "Client | None" = None,
) -> ReconcileReport:
    """
    Resolve every instructor named in a section scrape and rebuild
    `section_instructors`.

    New professors are created automatically here - a person teaching a section
    this term is real, and making a human confirm each one every August would
    make the scrape unusable. The grade backfill deliberately does the
    opposite; see `scripts/backfill_instructors.py`.
    """
    report = ReconcileReport()

    total_named = sum(len(s.get("instructors") or []) for s in sections_data)
    names = distinct_instructor_names(sections_data)
    report.observed = len(names)
    report.denylisted = total_named - sum(
        1 for s in sections_data for raw in (s.get("instructors") or []) if not is_denylisted(raw)
    )

    if print_output:
        print(f"Would reconcile {len(names)} distinct instructor names for term {term}")
        for normalized, raw in sorted(names.items()):
            print(f"  {normalized:<40} {raw}")
        return report

    if client is None:
        from db import get_supabase_client

        client = get_supabase_client()

    # Resolve every distinct name. `link_instructor` writes the alias on a
    # confident match, creates the instructor when nothing at all was similar,
    # and queues anything ambiguous. It returns null in that last case.
    resolved: dict[str, int] = {}
    known_before = _instructor_count(client)

    for normalized, raw in names.items():
        instructor_id = client.rpc(
            "link_instructor",
            {
                "observed": raw,
                "source": SOURCE_TESTUDO,
                "context": {"term": term} if term is not None else None,
                "create_if_missing": True,
                "seen_term": term,
            },
        ).execute().data

        if instructor_id is None:
            report.queued += 1
        else:
            resolved[normalized] = instructor_id
            report.resolved += 1

    report.created = max(0, _instructor_count(client) - known_before)
    report.resolved -= report.created

    _rebuild_section_instructors(client, sections_data, resolved, report)
    _mark_active(client, list(resolved.values()), term)

    # `sections.instructor_slugs` is what lets the site link a professor from a
    # section without matching on their name. It is derived from the aliases
    # this function just wrote, so it has to be recomputed here rather than by
    # whatever wrote `sections` -- at upload time the names have not been
    # resolved yet.
    #
    # Not fatal. A null slug array degrades to an unlinked professor name,
    # which is worth far more than failing a scrape that has already uploaded
    # everything else correctly.
    try:
        client.rpc("refresh_section_instructor_slugs", {}).execute()
    except Exception as error:  # noqa: BLE001 - reported, never raised
        print(f"WARNING: could not refresh section instructor slugs: {error}")
        print("Professors will render unlinked in the planner until this is re-run.")

    return report


def _instructor_count(client: "Client") -> int:
    response = client.table("instructors").select("id", count="exact").limit(1).execute()
    return response.count or 0


def _rebuild_section_instructors(
    client: "Client",
    sections_data: list[dict],
    resolved: dict[str, int],
    report: ReconcileReport,
) -> None:
    """
    Replace `section_instructors` with what this scrape saw.

    Testudo data is a snapshot, so this table is a snapshot too - a professor
    who stopped teaching a section must disappear from it, which an upsert
    alone would not do. This is safe to truncate precisely because nothing
    references it; `instructors` itself is never cleared, and `db.py` has a
    guard to keep it that way.
    """
    rows = []
    for section in sections_data:
        for raw in section.get("instructors") or []:
            normalized = normalize_name(raw)
            instructor_id = resolved.get(normalized) if normalized else None
            if instructor_id is None:
                continue
            rows.append(
                {
                    "course_code": section["course_code"],
                    "sec_code": section["sec_code"],
                    "instructor_id": instructor_id,
                }
            )

    # Deduplicate: a section listing the same professor twice (which Testudo
    # does) would otherwise violate the primary key mid-batch.
    unique = list({(r["course_code"], r["sec_code"], r["instructor_id"]): r for r in rows}.values())
    report.section_links = len(unique)

    scraped_courses = {s["course_code"] for s in sections_data}
    for chunk in _chunked(sorted(scraped_courses)):
        client.table("section_instructors").delete().in_("course_code", chunk).execute()

    for chunk in _chunked(unique):
        client.table("section_instructors").insert(chunk).execute()


def _mark_active(client: "Client", instructor_ids: list[int], term: int | None) -> None:
    """
    Flag everyone seen this scrape as active, and everyone else as not.

    `is_active` is a stored column rather than a view because the professor
    directory filters and sorts on it, and a correlated subquery against
    `section_instructors` on every directory query is exactly the kind of thing
    that looks fine at 2,000 instructors and stops working at 20,000.
    """
    if not instructor_ids:
        return

    client.table("instructors").update({"is_active": False}).eq("is_active", True).execute()

    for chunk in _chunked(instructor_ids):
        payload: dict = {"is_active": True}
        if term is not None:
            payload["last_seen_term"] = term
        client.table("instructors").update(payload).in_("id", chunk).execute()


def unresolved_queue_size(client: "Client") -> int:
    """
    Open entries in `instructor_match_queue`.

    `ci.py` asserts on this. A Testudo format change that breaks name parsing
    shows up here as a spike long before it shows up as professor pages with no
    grade data, which is the failure this whole design exists to make loud.
    """
    response = (
        client.table("instructor_match_queue")
        .select("id", count="exact")
        .is_("resolved_at", "null")
        .limit(1)
        .execute()
    )
    return response.count or 0


def _chunked(items: list, size: int = CHUNK_SIZE):
    for start in range(0, len(items), size):
        yield items[start : start + size]
