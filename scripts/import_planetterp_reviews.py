#!/usr/bin/env python3
"""
One-time import of PlanetTerp's written reviews into `planetterp_reviews`.

    python3 scripts/import_planetterp_reviews.py --print-output
    python3 scripts/import_planetterp_reviews.py
    python3 scripts/import_planetterp_reviews.py --archive ./archive/planetterp-professors-<stamp>.json

Reads the archive `snapshot_planetterp.py` already wrote, which fetched with
`reviews=true` and so holds every review's text, rating, course, expected grade
and date. PlanetTerp is not contacted.

These are display-only. PlanetTerp's ratings are already counted through
`pt_average_rating`, and `planetterp_reviews` is a separate table precisely so
that nothing here can reach `compute_instructor_ratings()`; see the migration
20260927120000_planetterp_reviews.sql.

Every review is stored, including those whose professor no Jupiterp instructor
holds the `pt_slug` of: `public_reviews` joins on the slug, so they stay hidden
until one does. Re-running is a no-op, keyed on a hash of each review.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from snapshot_planetterp import load_archive  # noqa: E402

CHUNK_SIZE = 500

COURSE_RE = re.compile(r"^[A-Z]{4}\d{3}[A-Z]?$")

GRADES = {
    "A+", "A", "A-", "B+", "B", "B-", "C+", "C", "C-",
    "D+", "D", "D-", "F", "W", "Other",
}


def latest_archive(directory: Path) -> Path:
    archives = sorted(directory.glob("planetterp-professors-*.json"))
    if not archives:
        raise SystemExit(f"no planetterp-professors-*.json in {directory}; run snapshot_planetterp.py first")
    return archives[-1]


def expected_grade(raw: str | None) -> str | None:
    """
    PlanetTerp's field is free text in practice: 13% blank, plus lowercase
    letters, `P`, `XF`, `?`, `B?`. Anything that is not a grade on the
    `reviews` scale is dropped rather than guessed at.
    """
    grade = (raw or "").strip().upper()
    return grade if grade in GRADES else None


def course_code(raw: str | None) -> str | None:
    code = (raw or "").strip().upper()
    return code if COURSE_RE.match(code) else None


def to_rows(records: list[dict]) -> list[dict]:
    rows: dict[str, dict] = {}
    for record in records:
        slug = record.get("slug")
        if not slug:
            continue
        for review in record.get("reviews") or []:
            rating = review.get("rating")
            created = review.get("created")
            if rating is None or not created:
                continue
            body = (review.get("review") or "").strip()
            key = hashlib.sha256(f"{slug}\x1f{created}\x1f{body}".encode()).hexdigest()
            # The archive repeats some professors; the key collapses them.
            rows[key] = {
                "pt_slug": slug,
                "course_code": course_code(review.get("course")),
                "rating": float(rating),
                "expected_grade": expected_grade(review.get("expected_grade")),
                "body": body or None,
                "created_at": created,
                "source_key": key,
            }
    return list(rows.values())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    parser.add_argument(
        "--archive",
        type=Path,
        help="Archive file to import (default: the newest in ./archive)",
    )
    parser.add_argument(
        "--print-output",
        action="store_true",
        help="Summarize what would be imported without writing to the database",
    )
    args = parser.parse_args()

    load_dotenv()

    path = args.archive or latest_archive(Path(__file__).resolve().parent.parent / "archive")
    records, captured = load_archive(path)
    rows = to_rows(records)
    print(f"{path.name}: {len(records)} professors captured {captured}, {len(rows)} distinct reviews.")

    if args.print_output:
        print(f"  {sum(1 for r in rows if r['course_code'])} name a course")
        print(f"  {sum(1 for r in rows if r['expected_grade'])} give an expected grade")
        print(f"  {sum(1 for r in rows if not r['body'])} have no text")
        print("--print-output set; database not written.")
        return

    from db import get_supabase_client

    client = get_supabase_client()
    for start in range(0, len(rows), CHUNK_SIZE):
        client.table("planetterp_reviews").upsert(
            rows[start:start + CHUNK_SIZE],
            on_conflict="source_key",
            ignore_duplicates=True,
        ).execute()
        print(f"  {min(start + CHUNK_SIZE, len(rows))}/{len(rows)}", end="\r")

    stored = client.table("planetterp_reviews").select("id", count="exact").limit(1).execute().count
    print(f"\nplanetterp_reviews now holds {stored} reviews.")


if __name__ == "__main__":
    main()
