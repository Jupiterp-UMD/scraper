"""
Tests for gradefix's name matching, which decides whose name a blank grade row
is filled with.

The bug: given names one edit apart were accepted as OCR damage, so the catalog's
"Dong Quan Nguyen" matched "Nguyen, Thu Thi Xuan" (Quan / Xuan), and the roster's
tie-break on frequency filled MATH401-0501 (Spring 2026) with an epidemiologist.

    python3 -m pytest tests/test_gradefix_names.py    # or
    python3 tests/test_gradefix_names.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "grades"))

from gradefix import Roster, names_match, parse_schedule_new  # noqa: E402


def test_short_given_names_one_letter_apart_are_different_people() -> None:
    assert not names_match("Dong Quan Nguyen", "Nguyen, Thu Thi Xuan")


def test_the_real_spelling_still_matches() -> None:
    assert names_match("Dong Quan Nguyen", "Nguyen, Dong Quan Ngoc")


def test_long_given_name_typos_are_still_tolerated() -> None:
    """The control: what the edit-distance rule exists for."""
    assert names_match("Michele Smith", "Smith, Michelle")
    assert names_match("Maryl Smith", "Smith, Mary")


def test_roster_picks_the_right_nguyen_even_when_the_wrong_one_is_commoner() -> None:
    roster = Roster()
    for _ in range(6):
        roster.add("Nguyen, Dong Quan Ngoc")
    for _ in range(7):
        roster.add("Nguyen, Thu Thi Xuan")
    name, matched = roster.canonical("Dong Quan Nguyen")
    assert matched and name == "Nguyen, Dong Quan Ngoc", name


FALL_2024_EXCERPT = """
DATA400 Applied Probability and Statistics |
Prerequisite: 1 course with a minimum grade of C- from (MATH131, MATH141). Cross-listed with: STAT400.
Random variables, standard distributions, moments, law of large numbers.
0111 Jonathan Fernandes Seats (Total: 27)
MWF 1:00pm - 1:50pm PHY 1412
0311 Sana Jahedi Seats (Total: 28)
TuTh 2:00pm - 3:15pm ARM 0126
Golden ID students are not eligible for this section.
0312 Sana Jahedi Seats (Total: 28)
STAT401
Applied Probability and Statistics
Prerequisite: 1 course with a minimum grade of C- from (MATH131, MATH141). Cross-listed with: DATA400.
0111 Jonathan Fernandes Seats (Total: 27)
0311 Sana Jahedi Seats (Total: 28)
0312 Sana Jahedi Seats (Total: 28)
"""


def test_a_catalog_without_grading_method_still_splits_courses() -> None:
    """
    The Fall 2024 catalog prints no 'Grading Method' line, which was the only
    thing that started a course; every section in it would have run together.
    The cross-listed pair repeats 0111-0312, a section note must not split a
    course, and the DATA400 anchor must survive the description after it.
    """
    blocks, _ = parse_schedule_new(FALL_2024_EXCERPT.split("\n"), prose_blocks=True)

    assert len(blocks) == 2, [sorted(b.sections) for b in blocks]
    assert blocks[0].anchor == "DATA400", blocks[0].anchor
    for block in blocks:
        assert sorted(block.sections) == ["0111", "0311", "0312"], block.sections
        assert block.sections["0311"] == ["Sana Jahedi"]


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
    print(f"\n{failures} failure(s)." if failures else "\nAll gradefix name tests pass.")
    sys.exit(1 if failures else 0)
