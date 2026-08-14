#!/usr/bin/env python3
"""
One-time capture of PlanetTerp's instructor ratings.

    python3 scripts/snapshot_planetterp.py --archive ./archive
    python3 scripts/snapshot_planetterp.py --archive ./archive --print-output

THIS CANNOT BE REDONE. PlanetTerp is no longer being actively updated, and if
it goes offline before this runs, Jupiterp has no baseline ratings at all and
every professor page starts at zero reviews forever. Run it early, verify the
archive file exists and is not empty, and keep the archive somewhere that is
not this laptop.

What it captures that `instructors.py` did not: `num_reviews`. The rating
blend weights PlanetTerp's average by how many reviews produced it, so a 4.9
from three students does not outrank a 4.6 from sixty. The old scraper threw
that field away because nothing used it.

Everything lands in the `pt_*` columns and is never written again. Jupiterp's
own ratings accumulate separately in `jupiterp_rating`, and `combined_rating`
blends the two with the PlanetTerp side decaying out over about six years.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from time import sleep

import requests
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from names import is_denylisted  # noqa: E402

API = "https://planetterp.com/api/v1/professors"
PAGE_SIZE = 100

# PlanetTerp asked for 500ms between requests. They are doing us a favour by
# still being online at all; keep it.
REQUEST_DELAY_SEC = 0.5

CHUNK_SIZE = 200


def fetch_all(verbose: bool = True) -> list[dict]:
    """Page through every professor PlanetTerp has, keeping the raw records."""
    everything: list[dict] = []
    offset = 0

    while True:
        sleep(REQUEST_DELAY_SEC)
        if verbose:
            print(f"Fetching professors at offset {offset}...")

        response = requests.get(
            API,
            params={"type": "professor", "limit": PAGE_SIZE, "offset": offset},
            headers={"User-Agent": "Jupiterp/1.0 (+https://jupiterp.com)"},
            timeout=30,
        )
        if response.status_code != 200:
            raise SystemExit(
                f"PlanetTerp returned {response.status_code} {response.reason} at offset {offset}. "
                f"Got {len(everything)} records before failing; nothing has been written."
            )

        page = response.json()
        everything += page
        offset += len(page)

        if len(page) < PAGE_SIZE:
            return everything


def archive_raw(records: list[dict], archive_dir: Path) -> Path:
    """
    Write the untouched API response to disk before touching the database.

    The parsed columns are a lossy projection - PlanetTerp returns fields we do
    not store, and the shape of what we want may change. The raw file is the
    only thing that can answer a question we have not thought of yet.
    """
    archive_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = archive_dir / f"planetterp-professors-{stamp}.json"
    path.write_text(json.dumps(records, indent=2, ensure_ascii=False))
    return path


def to_rows(records: list[dict], snapshot_at: str) -> list[dict]:
    """
    Project the API records onto the `pt_*` columns.

    Matched to existing instructors by PlanetTerp slug, which is what
    `instructors.slug` still held before migration 0002 copied it to `pt_slug`.
    Names are not used for matching here: this runs before instructor identity
    is backfilled, and a name-based match at this point is exactly the
    guesswork the rest of the migration exists to remove.
    """
    rows = []
    seen: set[str] = set()

    for record in records:
        slug = record.get("slug")
        if not slug or slug in seen:
            continue
        name = (record.get("name") or "").strip()
        if not name or is_denylisted(name):
            continue
        seen.add(slug)

        rating = record.get("average_rating")
        rows.append(
            {
                "pt_slug": slug,
                "name": name,
                # PlanetTerp returns these as numbers or null; the old scraper
                # stored the rating as text, which is why the site has a
                # parseFloat helper. Store numerics as numerics.
                "pt_average_rating": float(rating) if rating is not None else None,
                "pt_review_count": int(record.get("num_reviews") or 0),
                "pt_snapshot_at": snapshot_at,
            }
        )
    return rows


def apply_rows(client, rows: list[dict], verbose: bool = True) -> tuple[int, int]:
    """
    Write the snapshot onto existing instructor rows, matched on `pt_slug`.

    Deliberately an UPDATE and never an insert. Instructors that PlanetTerp
    knows about and Jupiterp does not are not created here: instructor records
    originate from Testudo and the registrar exports now, and inserting ~13,000
    PlanetTerp rows would reintroduce exactly the identity problem this
    migration is removing. Their ratings are still preserved in the archive
    file if they later turn out to matter.
    """
    updated = 0
    missing = 0

    for row in rows:
        response = (
            client.table("instructors")
            .update(
                {
                    "pt_average_rating": row["pt_average_rating"],
                    "pt_review_count": row["pt_review_count"],
                    "pt_snapshot_at": row["pt_snapshot_at"],
                }
            )
            .eq("pt_slug", row["pt_slug"])
            .execute()
        )
        if response.data:
            updated += 1
        else:
            missing += 1

    if verbose:
        print(f"Updated {updated} instructors; {missing} PlanetTerp records had no match.")
    return updated, missing


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument(
        "--archive",
        default="./archive",
        help="Directory for the raw JSON archive (default ./archive)",
    )
    parser.add_argument(
        "--print-output",
        action="store_true",
        help="Fetch and archive, but do not write to the database",
    )
    args = parser.parse_args()

    load_dotenv()

    records = fetch_all()
    print(f"Fetched {len(records)} professor records.")

    if not records:
        raise SystemExit("PlanetTerp returned nothing. Refusing to write an empty snapshot.")

    archive_path = archive_raw(records, Path(args.archive))
    print(f"Archived raw response to {archive_path}")
    print("Copy this file somewhere durable before continuing. It cannot be regenerated.")

    snapshot_at = datetime.now(timezone.utc).isoformat()
    rows = to_rows(records, snapshot_at)
    print(f"{len(rows)} usable records after dropping duplicates and placeholders.")

    rated = sum(1 for r in rows if r["pt_average_rating"] is not None)
    print(f"{rated} have an average rating; {len(rows) - rated} have none.")

    if args.print_output:
        for row in rows[:20]:
            print(f"  {row['pt_slug']:<40} {row['pt_average_rating']} ({row['pt_review_count']} reviews)")
        print("--print-output set; database not written.")
        return

    from db import get_supabase_client

    apply_rows(get_supabase_client(), rows)


if __name__ == "__main__":
    main()
