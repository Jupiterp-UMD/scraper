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

from gradefix import Roster, names_match  # noqa: E402


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
