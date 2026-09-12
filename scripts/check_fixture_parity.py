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
    python3 scripts/check_fixture_parity.py --url --ref main   # fetch a named ref

Exits non-zero and prints the differing cases when the two have drifted.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
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

RAW_URL_TEMPLATE = (
    "https://raw.githubusercontent.com/atcupps/Jupiterp/{ref}/"
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


def candidate_refs(explicit: str | None) -> list[str]:
    """
    Refs to look for the site's copy on, in the order to try them.

    This used to be `main` alone, which 404s for as long as a cross-repo change
    is in flight: the site's copy of the fixture lands on the site's branch,
    not on its `main`, so the file this asks for does not exist yet. Comparing
    against `main` would be wrong even once it did resolve -- that is the
    version from before the change, so it would either 404 or report a drift
    that is really just the feature not having landed.

    A change like this carries the same branch name in all four repositories,
    so the matching branch is the right thing to compare against while the work
    is open, and `main` is right once it has merged and the branch is gone.
    Trying the branch first and falling back to `main` is correct in both
    states without anyone having to remember to flip it back.
    """
    if explicit:
        return [explicit]

    refs: list[str] = []

    # In CI. `GITHUB_HEAD_REF` is set only for `pull_request` events, where
    # `GITHUB_REF_NAME` is the synthetic "123/merge" rather than a real branch;
    # for `push` events `GITHUB_REF_NAME` is the branch itself.
    head_ref = os.environ.get("GITHUB_HEAD_REF", "").strip()
    ref_name = os.environ.get("GITHUB_REF_NAME", "").strip()
    if head_ref:
        refs.append(head_ref)
    elif ref_name and not re.fullmatch(r"\d+/merge", ref_name):
        refs.append(ref_name)

    # Only when nothing said which branch is under test: whatever is checked
    # out here. Under `actions/checkout` this is a detached HEAD and yields
    # nothing, which is why it is a fallback rather than the first source.
    if not refs:
        try:
            result = subprocess.run(
                ["git", "rev-parse", "--abbrev-ref", "HEAD"],
                capture_output=True,
                text=True,
                timeout=5,
                cwd=Path(__file__).resolve().parent.parent,
            )
            branch = result.stdout.strip()
            if result.returncode == 0 and branch and branch != "HEAD":
                refs.append(branch)
        except (OSError, subprocess.SubprocessError):
            pass

    # Always last, and always the end of the line: once the branch under test
    # is `main` there is nothing further to fall back to.
    refs.append("main")

    seen: set[str] = set()
    return [ref for ref in refs if not (ref in seen or seen.add(ref))]


def fetch_site_copy(refs: list[str]) -> tuple[dict, str]:
    """Fetch the site's fixture from the first ref that has one."""
    missing: list[str] = []
    for ref in refs:
        url = RAW_URL_TEMPLATE.format(ref=ref)
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return load(response.read().decode("utf-8"), is_text=True), url
        except urllib.error.HTTPError as error:
            # A 404 means this ref does not carry the file; anything else
            # (rate limiting, an outage) is not something to paper over by
            # quietly trying the next ref.
            if error.code != 404:
                raise
            missing.append(ref)

    raise LookupError(", ".join(missing))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", help="path to the site's names.json")
    parser.add_argument(
        "--url",
        action="store_true",
        help="fetch the site's copy from GitHub instead of the filesystem",
    )
    parser.add_argument(
        "--ref",
        help="branch or tag to fetch the site's copy from; defaults to the "
        "branch under test, then main",
    )
    args = parser.parse_args()

    canonical = load(str(CANONICAL))

    if args.url:
        refs = candidate_refs(args.ref)
        try:
            other, source = fetch_site_copy(refs)
        except LookupError as error:
            print(
                f"None of these refs of the site repository have a copy of "
                f"the fixture: {error}.\n"
                "The site keeps it at "
                f"{SITE_RELATIVE}; pass --ref to name the branch it is on.",
                file=sys.stderr,
            )
            return 2
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
