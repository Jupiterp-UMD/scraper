"""
Tests for the instructor-attribution guard in the grade parser.

The bug this exists for was total and completely silent. The `.repaired.csv`
set spells its instructor column `INSTRUCTOR`, which was not in
`HEADER_ALIASES`, so the column was never mapped and every row loaded with a
null instructor -- while the row count, the grade buckets, the totals and the
computed GPAs all came out exactly right. The file parsed. The ingest reported
success. A hundred percent of the attribution was gone, and nothing downstream
could notice: the resolver had no names to fail on, so it queued nothing, and
the professor pages were simply empty.

The alias was added. What is tested here is the guard, which is the part that
makes the *next* unrecognised header an error instead of a quiet loss.

    python3 -m pytest tests/test_parse_attribution.py    # or
    python3 tests/test_parse_attribution.py
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "grades"))

from grades.parse import ParseError, parse_file  # noqa: E402

GRADE_COLUMNS = "A+,A,A-,B+,B,B-,C+,C,C-,D+,D,D-,F,W,OTHER"
# One row's worth of grades, summing to the total below it.
GRADE_VALUES = "1,1,1,1,1,1,1,1,1,1,1,1,1,1,1"
ROW_TOTAL = "15"


def write(text: str) -> Path:
    handle = tempfile.NamedTemporaryFile(
        "w", suffix=".csv", delete=False, encoding="utf-8"
    )
    handle.write(text)
    handle.close()
    return Path(handle.name)


def test_a_recognised_instructor_column_parses() -> None:
    """The control. Without this the test below proves nothing."""
    path = write(
        f"TERM,COURSE,SECTION,INSTRUCTOR,TOTAL,{GRADE_COLUMNS}\n"
        f"202508,CMSC132,0101,\"Walsh, Shane\",{ROW_TOTAL},{GRADE_VALUES}\n"
        f"202508,CMSC132,0201,\"O'Brien, Erin\",{ROW_TOTAL},{GRADE_VALUES}\n"
    )
    try:
        records, report = parse_file(path, term=202508)
    finally:
        path.unlink()

    assert report.rows == 2, report.rows
    attributed = (
        report.instructors_reported
        + report.instructors_lead
        + report.instructors_course
    )
    assert attributed == 2, f"expected both rows attributed, got {attributed}"
    assert records[0]["instructor_name"] == "Shane Walsh", records[0]["instructor_name"]


def test_an_unmapped_instructor_column_is_refused() -> None:
    """
    The regression.

    Same file, same rows, same grade columns -- only the instructor header is
    spelled something the parser does not know. Everything else about the parse
    still succeeds, which is exactly why this has to be checked explicitly.
    """
    path = write(
        f"TERM,COURSE,SECTION,TEACHER_OF_RECORD,TOTAL,{GRADE_COLUMNS}\n"
        f"202508,CMSC132,0101,\"Walsh, Shane\",{ROW_TOTAL},{GRADE_VALUES}\n"
        f"202508,CMSC132,0201,\"O'Brien, Erin\",{ROW_TOTAL},{GRADE_VALUES}\n"
    )
    try:
        parse_file(path, term=202508)
    except ParseError as error:
        message = str(error)
        assert "HEADER_ALIASES" in message, (
            "the error should name the thing to fix, not just report a count: " + message
        )
        return
    finally:
        path.unlink()

    raise AssertionError(
        "a file with an unrecognised instructor column parsed without complaint; "
        "this is the failure that produced 100% null instructors silently"
    )


def test_gradefix_fills_keep_a_weaker_tier_than_reported() -> None:
    """
    A `.repaired.csv` name that gradefix filled in is a guess, not something the
    registrar printed. Loaded as `reported`, a wrong guess (MATH401-0501, Spring
    2026) sat on a professor page with full confidence and Testudo could not
    correct it.
    """
    header = f"TERM,COURSE,SECTION,INSTRUCTOR,TOTAL,{GRADE_COLUMNS},FILL_SOURCE,FILL_CONFIDENCE,NOTES"
    row = lambda sec, name, fill: (  # noqa: E731
        f"Spring 2026,MATH401,{sec},\"{name}\",{ROW_TOTAL},{GRADE_VALUES},{fill},high,\n"
    )
    path = write(
        header + "\n"
        + row("0111", "Liu, Yaxiong", "original+schedule-confirmed")
        + row("0112", "Liu, Yaxiong", "original")
        + row("0501", "Nguyen, Thu Thi Xuan", "schedule-section")
        + row("0601", "Yang, Haizhao", "schedule-course-unanimous")
        + row("0701", "Kass, Jason M", "file-course-unanimous")
        + row("0801", "", "unresolved")
    )
    try:
        records, report = parse_file(path, term=202601)
    finally:
        path.unlink()

    by_sec = {r["sec_code"]: r for r in records}
    tiers = {sec: r["instructor_source"] for sec, r in by_sec.items()}
    assert tiers == {
        "0111": "reported",
        "0112": "reported",
        "0501": "testudo",
        "0601": "course",
        "0701": "course",
        # Carried from the last *printed* name, never from a fill.
        "0801": "course",
    }, tiers
    assert by_sec["0801"]["instructor_name"] == "Yaxiong Liu", by_sec["0801"]
    # The raw column is what the registrar printed, and it printed nothing.
    assert by_sec["0501"]["instructor"] is None, by_sec["0501"]
    assert by_sec["0501"]["instructor_name"] == "Thu Thi Xuan Nguyen"
    assert by_sec["0111"]["instructor"] == "Liu, Yaxiong"
    assert report.instructors_testudo == 1, report.instructors_testudo
    assert not report.warnings, report.warnings


def test_an_unknown_fill_source_loads_as_course_and_says_so() -> None:
    path = write(
        f"TERM,COURSE,SECTION,INSTRUCTOR,TOTAL,{GRADE_COLUMNS},FILL_SOURCE\n"
        f"202601,CMSC132,0101,\"Walsh, Shane\",{ROW_TOTAL},{GRADE_VALUES},llm-guess\n"
    )
    try:
        records, report = parse_file(path, term=202601)
    finally:
        path.unlink()

    assert records[0]["instructor_source"] == "course", records[0]
    assert any("llm-guess" in w for w in report.warnings), report.warnings


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ok   {name}")
            except AssertionError as error:
                failures += 1
                print(f"  FAIL {name}: {error}")
    print(f"\n{failures} failure(s)." if failures else "\nAll parse attribution tests pass.")
    sys.exit(1 if failures else 0)
