"""
Check that the site's copy of the name fixtures still matches this one.

The three implementations of `normalize_name` -- SQL, Python, TypeScript --
are each tested against `tests/fixtures/names.json`. Two of those tests live in
this repository and read the file directly. The third lives in the site
repository, which cannot reach across a repository boundary, so it keeps a copy
at `site/src/lib/professor/__fixtures__/names.json`.

Nothing checked that the copy still matched. The copy's own header instructs
the reader to keep the two "byte-identical apart from this comment block", and
they already were not: Prettier reformatted one of them, so a byte comparison
had been failing silently for as long as anyone might have run it.

Byte equality is the wrong invariant anyway -- two formatters will never agree
-- so this compares the parsed JSON with the comment block dropped. That is the
property that actually matters: the same inputs mapped to the same expected
outputs.

    python3 scripts/check_fixture_parity.py                    # find the site checkout
    python3 scripts/check_fixture_parity.py path/to/names.json # explicit path
    python3 scripts/check_fixture_parity.py --url              # fetch from GitHub (CI)

Exits non-zero and prints the differing cases when the two have drifted.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

CANONICAL = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "names.json"

# Where the site keeps its copy, relative to a sibling checkout of the site
# repository. Several layouts are tried because there is no one right answer
# for how the four repositories sit next to each other on a given machine.
SITE_RELATIVE = Path("site/src/lib/professor/__fixtures__/names.json")
SITE_CANDIDATES = [
    Path("../Jupiterp") / SITE_RELATIVE,
    Path("../jupiterp") / SITE_RELATIVE,
    Path("..") / SITE_RELATIVE,
]

RAW_URL = (
    "https://raw.githubusercontent.com/atcupps/Jupiterp/main/"
    "site/src/lib/professor/__fixtures__/names.json"
)


def load(path_or_text: str, *, is_text: bool = False) -> dict:
    """Parse a fixture file and drop the comment block."""
    raw = path_or_text if is_text else Path(path_or_text).read_text(encoding="utf-8")
    data = json.loads(raw)
    data.pop("_comment", None)
    return data


def find_site_copy() -> Path | None:
    base = Path(__file__).resolve().parent.parent
    for candidate in SITE_CANDIDATES:
        resolved = (base / candidate).resolve()
        if resolved.is_file():
            return resolved
    return None


def describe_drift(canonical: dict, other: dict) -> list[str]:
    """Human-readable account of how the two differ."""
    problems: list[str] = []

    missing = sorted(set(canonical) - set(other))
    extra = sorted(set(other) - set(canonical))
    if missing:
        problems.append(f"groups missing from the site copy: {', '.join(missing)}")
    if extra:
        problems.append(f"groups only in the site copy: {', '.join(extra)}")

    for group in sorted(set(canonical) & set(other)):
        left, right = canonical[group], other[group]
        if left == right:
            continue

        # Compare case by case so the message names the input that drifted
        # rather than dumping two lists and leaving the reader to diff them.
        by_input_left = {case.get("input"): case.get("expected") for case in left}
        by_input_right = {case.get("input"): case.get("expected") for case in right}

        for missing_input in sorted(set(by_input_left) - set(by_input_right), key=repr):
            problems.append(f"[{group}] {missing_input!r} is not in the site copy")
        for extra_input in sorted(set(by_input_right) - set(by_input_left), key=repr):
            problems.append(f"[{group}] {extra_input!r} is only in the site copy")
        for shared in sorted(set(by_input_left) & set(by_input_right), key=repr):
            if by_input_left[shared] != by_input_right[shared]:
                problems.append(
                    f"[{group}] {shared!r}: this repo expects "
                    f"{by_input_left[shared]!r}, the site expects {by_input_right[shared]!r}"
                )

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", help="path to the site's names.json")
    parser.add_argument(
        "--url",
        action="store_true",
        help="fetch the site's copy from GitHub instead of the filesystem",
    )
    args = parser.parse_args()

    canonical = load(str(CANONICAL))

    if args.url:
        with urllib.request.urlopen(RAW_URL, timeout=30) as response:
            other = load(response.read().decode("utf-8"), is_text=True)
        source = RAW_URL
    else:
        path = Path(args.path) if args.path else find_site_copy()
        if path is None:
            print(
                "Could not find the site's copy of names.json.\n"
                "Pass its path, or use --url to fetch it from GitHub.",
                file=sys.stderr,
            )
            return 2
        other = load(str(path))
        source = str(path)

    problems = describe_drift(canonical, other)
    if problems:
        print(f"Name fixtures have drifted between this repo and {source}:\n", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print(
            "\nThe two must agree. A drift here produces duplicate instructor "
            "records and, once professor pages are indexed, permanently broken "
            "URLs. Fix the fixture in BOTH repositories, then the three "
            "implementations.",
            file=sys.stderr,
        )
        return 1

    total = sum(len(cases) for cases in canonical.values())
    print(f"Name fixtures agree with {source} ({total} cases across {len(canonical)} groups).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
