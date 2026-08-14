"""
Tests for the Testudo attribution step of `ingest-term`.

This is the part of the per-term ingest that cannot be exercised by running the
command: it needs a Testudo scrape, and Testudo only keeps a few years of past
terms online. So the scrape result is faked and the merge logic tested directly.

    python3 -m pytest tests/test_ingest_term.py    # or
    python3 tests/test_ingest_term.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "grades"))

from grades.ingest_term import SOURCE_TESTUDO, apply_testudo_attribution  # noqa: E402


def row(**overrides) -> dict:
    base = {
        "course_code": "CMSC132",
        "sec_code": "0101",
        "instructor": None,
        "instructor_name": None,
        "instructor_source": None,
    }
    base.update(overrides)
    return base


def test_fills_in_a_blank_section():
    records = [row(sec_code="0102")]
    counts = apply_testudo_attribution(records, {("CMSC132", "0102"): ["Shane Walsh"]})

    assert records[0]["instructor_name"] == "Shane Walsh"
    assert records[0]["instructor_source"] == SOURCE_TESTUDO
    assert counts["upgraded"] == 1


def test_never_overwrites_a_registrar_attribution():
    """
    `instructor` non-null means the registrar named somebody on this row. That
    is a better source than Testudo's schedule and must win, even though the
    row is being visited.
    """
    records = [
        row(
            instructor="Walsh, Shane Bolles",
            instructor_name="Shane Bolles Walsh",
            instructor_source="reported",
        )
    ]
    apply_testudo_attribution(records, {("CMSC132", "0101"): ["Someone Else"]})

    assert records[0]["instructor_name"] == "Shane Bolles Walsh"
    assert records[0]["instructor_source"] == "reported"


def test_upgrades_a_carried_attribution():
    """
    A `lead` attribution is an inference from a neighbouring section. Testudo
    naming this exact section is better, so it wins.
    """
    records = [row(sec_code="0102", instructor_name="Carried Guess", instructor_source="lead")]
    apply_testudo_attribution(records, {("CMSC132", "0102"): ["Shane Walsh"]})

    assert records[0]["instructor_name"] == "Shane Walsh"
    assert records[0]["instructor_source"] == SOURCE_TESTUDO


def test_does_not_downgrade_an_existing_testudo_attribution():
    records = [row(instructor_name="Already Testudo", instructor_source=SOURCE_TESTUDO)]
    counts = apply_testudo_attribution(records, {("CMSC132", "0101"): ["Someone Else"]})

    assert records[0]["instructor_name"] == "Already Testudo"
    assert counts["upgraded"] == 0


def test_placeholder_instructors_are_not_used():
    """
    Testudo prints these where nobody has been assigned. Letting one through
    would create an instructor record called "Instructor: TBA" that then
    accumulates grade data from every unassigned section on campus.
    """
    records = [row(sec_code="0102")]
    counts = apply_testudo_attribution(records, {("CMSC132", "0102"): ["Instructor: TBA"]})

    assert records[0]["instructor_name"] is None
    assert counts["denylisted"] == 1


def test_first_real_instructor_wins_when_a_section_lists_several():
    records = [row(sec_code="0102")]
    apply_testudo_attribution(records, {("CMSC132", "0102"): ["TBA", "Erin O'Brien", "Jose Garcia"]})

    assert records[0]["instructor_name"] == "Erin O'Brien"


def test_sections_missing_from_the_scrape_are_left_alone():
    """
    Testudo drops terms after a few years, so a miss here is the normal case
    for older files rather than an error.
    """
    records = [row(sec_code="0102")]
    counts = apply_testudo_attribution(records, {})

    assert records[0]["instructor_name"] is None
    assert records[0]["instructor_source"] is None
    assert counts["unmatched"] == 1


def test_matching_is_per_section_not_per_course():
    """
    Two sections of one course can have different instructors. Attributing by
    course would silently merge them.
    """
    records = [row(sec_code="0101"), row(sec_code="0201")]
    apply_testudo_attribution(
        records,
        {("CMSC132", "0101"): ["Shane Walsh"], ("CMSC132", "0201"): ["Erin O'Brien"]},
    )

    assert records[0]["instructor_name"] == "Shane Walsh"
    assert records[1]["instructor_name"] == "Erin O'Brien"


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
    print(f"\n{failures} failure(s)." if failures else "\nAll ingest-term tests pass.")
    sys.exit(1 if failures else 0)
