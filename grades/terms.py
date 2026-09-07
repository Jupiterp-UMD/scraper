"""
Term code detection.

Jupiterp identifies terms with a six-digit code: the four-digit calendar year
followed by a two-digit month marking the start of the term (the same codes
Testudo uses, and the same ones passed to `scraper/main.py --term`).

    Spring 2026 -> 202601
    Summer 2025 -> 202505
    Fall 2025   -> 202508
    Winter 2026 -> 202612

The MPIA grade files arrive with human-written names that are not consistent
between terms ("UMCP grade distribution Spring -2012.csv", "UMCP grade
distribuiton Fall 2011.xlsx", "umcp Grade Distributions Spring 2026.xlsx"), so
the term is recovered by regex rather than by exact filename match.
"""

import re

SEASON_MONTHS = {
    "spring": "01",
    "winter": "12",
    "summer": "05",
    "fall": "08",
}

# Tolerates any junk between the season and the year, which covers the stray
# hyphen in "Spring -2012" and any double spaces.
_TERM_RE = re.compile(
    r"(spring|summer|fall|winter)\W*(\d{4})",
    re.IGNORECASE,
)

# Some workbooks name their sheet after the term directly (ex. "pickaprof-202601").
_CODE_RE = re.compile(r"(20\d{2})(01|05|08|12)")


class TermError(ValueError):
    """Raised when a term code cannot be determined for a source file."""


def term_from_code(text: str) -> int | None:
    """Pull an explicit six-digit term code out of `text`, if one is present."""
    match = _CODE_RE.search(text or "")
    if not match:
        return None
    return int(match.group(1) + match.group(2))


def term_from_name(text: str) -> int | None:
    """
    Derive a term code from a season/year phrase in `text`, if one is present.

    Winter terms are labelled with the *previous* calendar year at UMD (Winter
    2026 runs in January 2026 but is term 202512), so the year is decremented
    for winter.
    """
    match = _TERM_RE.search(text or "")
    if not match:
        return None
    season = match.group(1).lower()
    year = int(match.group(2))
    if season == "winter":
        year -= 1
    return int(f"{year}{SEASON_MONTHS[season]}")


def detect_term(*candidates: str) -> int:
    """
    Determine the term code for a file, given any number of hints (filename,
    sheet name, etc.) in order of preference.

    An explicit six-digit code always wins over a season/year phrase, because a
    sheet named "pickaprof-202508" is the university's own label for the term
    while the filename is whatever the records office typed that day.

    Raises `TermError` if no hint yields a term; callers should fall back to an
    operator-supplied `--term`.
    """
    for candidate in candidates:
        code = term_from_code(candidate)
        if code is not None:
            return code
    for candidate in candidates:
        code = term_from_name(candidate)
        if code is not None:
            return code
    raise TermError(
        "could not determine a term from: "
        + ", ".join(repr(c) for c in candidates)
        + "; pass --term explicitly (ex. --term 202508)"
    )


def term_label(term: int) -> str:
    """Render a term code back as a human-readable label (202508 -> 'Fall 2025')."""
    year, month = divmod(term, 100)
    seasons = {1: "Spring", 5: "Summer", 8: "Fall", 12: "Winter"}
    season = seasons.get(month, f"Month{month:02d}")
    if season == "Winter":
        year += 1
    return f"{season} {year}"
