"""
Parity tests for name normalization.

Every case comes from `fixtures/names.json`, which is the same file the SQL
implementation is tested against (`db/tests/name_parity.sql`) and the site's
TypeScript implementation is tested against (`Names.test.ts`). Adding a case
here without adding it to the fixture is the one thing that defeats the point.

    python3 -m pytest tests/                 # or
    python3 tests/test_names.py              # no pytest needed
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from names import (  # noqa: E402
    first_last,
    is_denylisted,
    natural_name,
    normalize_name,
    slugify,
    surname,
)

FIXTURES = json.loads((Path(__file__).parent / "fixtures" / "names.json").read_text())


def _check(group: str, fn) -> list[str]:
    failures = []
    for case in FIXTURES[group]:
        actual = fn(case["input"])
        if actual != case["expected"]:
            failures.append(
                f"{group}({case['input']!r}) -> {actual!r}, expected {case['expected']!r}"
                + (f"  [{case['why']}]" if "why" in case else "")
            )
    return failures


def test_normalize():
    assert not _check("normalize", normalize_name)


def test_slugify():
    assert not _check("slugify", slugify)


def test_denylisted():
    assert not _check("denylisted", is_denylisted)


def test_first_last():
    assert not _check("first_last", first_last)


def test_surname():
    assert not _check("surname", surname)


def test_slug_is_normalize_with_hyphens():
    """
    The relationship the SQL implementation relies on. If this ever stops
    holding, `slugify` and `normalize_name` have to be kept in sync by review
    rather than by construction, which is how they drift.
    """
    for case in FIXTURES["normalize"]:
        normalized = normalize_name(case["input"])
        expected = None if normalized is None else normalized.replace(" ", "-")
        assert slugify(case["input"]) == expected, case["input"]


def test_natural_name_then_normalize_matches_testudo_order():
    """
    The end-to-end shape of the problem this exists to solve: the registrar's
    'Walsh, Shane Bolles' and Testudo's 'Shane Walsh' must reduce to the same
    first+last key.
    """
    registrar = normalize_name(natural_name("Walsh, Shane Bolles"))
    testudo = normalize_name("Shane Walsh")
    assert registrar == "shane bolles walsh"
    assert testudo == "shane walsh"
    assert first_last(registrar) == first_last(testudo) == "shane walsh"


def test_denylist_is_not_a_substring_test():
    """Real people whose names contain a denylisted token as a substring."""
    for name in ("Stafford Jones", "Tabatha Bacon", "Instructors Aide", "Staffordshire Bull"):
        assert not is_denylisted(name), name


if __name__ == "__main__":
    all_failures = []
    for group, fn in (
        ("normalize", normalize_name),
        ("slugify", slugify),
        ("denylisted", is_denylisted),
        ("first_last", first_last),
        ("surname", surname),
    ):
        all_failures += _check(group, fn)

    if all_failures:
        print(f"{len(all_failures)} failure(s):")
        for failure in all_failures:
            print("  " + failure)
        sys.exit(1)

    total = sum(len(FIXTURES[g]) for g in ("normalize", "slugify", "denylisted", "first_last", "surname"))
    print(f"All {total} name fixtures pass.")
