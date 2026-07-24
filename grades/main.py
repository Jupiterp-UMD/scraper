"""
Grade distribution loader.

    # everything the registrar has sent so far
    python3 main.py ingest --dir ./data

    # one new term, next time a file arrives
    python3 main.py ingest "./data/UMCP grade distribution Fall 2026.csv"

    # check a file parses without touching the database
    python3 main.py verify ./data/whatever.csv

    # what is loaded right now
    python3 main.py terms

Ingesting is idempotent. A file whose SHA-256 has already been logged for its
term is skipped; pass --force to load it anyway. Because rows are keyed on
(term, course_code, sec_code), loading the same term twice converges on the same
table either way — the hash check just saves the round trips.
"""

import argparse
import csv
import sys
from pathlib import Path

from dotenv import load_dotenv

import db
from parse import GRADE_FIELDS, ParseError, file_digest, parse_file
from terms import TermError, term_label

SOURCE_SUFFIXES = (".csv", ".xlsx", ".xlsm")

CSV_COLUMNS = (
    "term", "course_code", "sec_code", "instructor", "instructor_name", "instructor_source",
    "total", *GRADE_FIELDS, "gpa",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Parse UMD grade distribution files and load them into Supabase"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    ingest = subparsers.add_parser("ingest", help="Parse files and upload them")
    ingest.add_argument("files", nargs="*", help="One or more .csv/.xlsx source files")
    ingest.add_argument(
        "--dir",
        help="Ingest every .csv/.xlsx file in this directory",
    )
    ingest.add_argument(
        "--term",
        type=int,
        help="Override term detection (ex. 202508); only valid with a single file",
    )
    ingest.add_argument(
        "--print-output",
        action="store_true",
        help="Parse and summarize without uploading",
    )
    ingest.add_argument(
        "--out",
        help="Write the normalized rows to this CSV instead of uploading",
    )
    ingest.add_argument(
        "--force",
        action="store_true",
        help="Re-upload a file even if its hash is already logged for that term",
    )
    ingest.add_argument(
        "--replace-term",
        action="store_true",
        help=(
            "Delete every existing row for the term before uploading. Needed "
            "only when a corrected file has fewer rows than the one it replaces"
        ),
    )

    verify = subparsers.add_parser(
        "verify", help="Parse files and report on them; never touches the database"
    )
    verify.add_argument("files", nargs="*")
    verify.add_argument("--dir")
    verify.add_argument("--term", type=int)

    subparsers.add_parser("terms", help="List the terms currently in the database")

    return parser.parse_args()


def collect_sources(files: list[str], directory: str | None) -> list[Path]:
    """Resolve the file arguments into a sorted list of source paths."""
    paths = [Path(f) for f in files]
    if directory:
        root = Path(directory)
        if not root.is_dir():
            raise SystemExit(f"not a directory: {directory}")
        paths.extend(
            p for p in root.iterdir()
            if p.suffix.lower() in SOURCE_SUFFIXES and not p.name.startswith("~$")
        )
    if not paths:
        raise SystemExit("no input files; pass paths or --dir")
    missing = [p for p in paths if not p.is_file()]
    if missing:
        raise SystemExit("no such file: " + ", ".join(str(p) for p in missing))
    return sorted(set(paths))


def write_csv(path: str, records: list[dict]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for record in records:
            writer.writerow({column: record.get(column) for column in CSV_COLUMNS})


def report_line(report) -> str:
    label = term_label(report.term)
    line = f"  {label:<12} {report.rows:>6} rows"
    if report.unaccounted_students:
        line += (
            f"  ({report.unaccounted_students} students in "
            f"{report.unaccounted_rows} rows not broken out by grade)"
        )
    return line


def run_ingest(args: argparse.Namespace) -> int:
    sources = collect_sources(args.files, args.dir)
    if args.term is not None and len(sources) > 1:
        raise SystemExit("--term can only be used with a single file")

    dry_run = args.print_output or args.out
    client = None if dry_run else db.get_supabase_client()

    all_records: list[dict] = []
    failures = 0
    skipped = 0

    for path in sources:
        digest = file_digest(path)
        try:
            records, report = parse_file(path, term=args.term)
        except (ParseError, TermError) as err:
            print(f"  FAILED {path.name}: {err}", file=sys.stderr)
            failures += 1
            continue

        if client and not args.force and db.already_ingested(client, report.term, digest):
            print(f"  {term_label(report.term):<12} already loaded from this exact file; skipping")
            skipped += 1
            continue

        print(report_line(report))
        for warning in report.warnings:
            print(f"      note: {warning}")

        if client:
            if args.replace_term:
                db.delete_term(client, report.term)
            db.upsert_grades(client, records)
            db.record_ingest(client, report, digest)
        else:
            all_records.extend(records)

    if args.out and all_records:
        write_csv(args.out, all_records)
        print(f"\nwrote {len(all_records)} rows to {args.out}")

    total = len(all_records) if dry_run else None
    print(
        f"\n{len(sources) - failures - skipped} file(s) processed"
        + (f", {skipped} skipped" if skipped else "")
        + (f", {failures} failed" if failures else "")
        + (f"; {total} rows" if total is not None else "")
    )
    return 1 if failures else 0


def run_verify(args: argparse.Namespace) -> int:
    sources = collect_sources(args.files, args.dir)
    failures = 0
    for path in sources:
        try:
            _, report = parse_file(path, term=args.term)
        except (ParseError, TermError) as err:
            print(f"  FAILED {path.name}: {err}", file=sys.stderr)
            failures += 1
            continue
        print(report_line(report))
        for warning in report.warnings:
            print(f"      note: {warning}")
    return 1 if failures else 0


def run_terms() -> int:
    client = db.get_supabase_client()
    rows = db.loaded_terms(client)
    if not rows:
        print("no grade data loaded")
        return 0
    print(f"{'term':<8} {'label':<14} {'sections':>9} {'courses':>8} {'students':>9} {'gpa':>6}")
    for row in rows:
        print(
            f"{row['term']:<8} {term_label(row['term']):<14} "
            f"{row['section_count']:>9} {row['course_count']:>8} "
            f"{row['total']:>9} {row['gpa'] or '-':>6}"
        )
    return 0


def main() -> int:
    load_dotenv()
    args = parse_args()
    if args.command == "ingest":
        return run_ingest(args)
    if args.command == "verify":
        return run_verify(args)
    return run_terms()


if __name__ == "__main__":
    sys.exit(main())
