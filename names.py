"""
Name normalization, shared by everything that has to decide whether two
spellings mean the same person.

This module is the Python half of a three-way contract. The other two are:

    SQL  normalize_name() / slugify()   db/migrations/0001_extensions_and_name_functions.sql
    TS   normalizeName() / slugify()    site/src/lib/professor/Names.ts

All three are exercised against `tests/fixtures/names.json`. A drift between
any two of them produces duplicate instructor records, and - once professor
pages are indexed - permanently broken URLs, because the slug is derived from
the same normalization. Change the fixture first, then all three.

Nothing here touches the database or the network, so it can be imported and
tested anywhere.
"""

from __future__ import annotations

import re
import unicodedata

# Characters PostgreSQL's unaccent.rules maps but Unicode NFKD decomposition
# does not, because they are not composed characters at all. Without these the
# Python and SQL normalizers disagree on exactly the names most likely to be
# entered inconsistently in the first place.
_UNACCENT_EXTRA = {
    "Ø": "O", "ø": "o",    # Ø ø  slashed O
    "Đ": "D", "đ": "d",    # Đ đ  stroked D
    "Ł": "L", "ł": "l",    # Ł ł  stroked L
    "Æ": "AE", "æ": "ae",  # Æ æ
    "Œ": "OE", "œ": "oe",  # Œ œ
    "Þ": "TH", "þ": "th",  # Þ þ  thorn
    "Ð": "D", "ð": "d",    # Ð ð  eth
    "ß": "ss",                  # ß
    "ı": "i",                   # ı  dotless i
}

# Anything that is not an ASCII letter or digit becomes a space. Applied after
# unaccenting, so this is deliberately narrow: a name in a script unaccent
# cannot map normalizes to None and goes to the match queue rather than being
# silently mangled into a partial match.
_NON_ALNUM = re.compile(r"[^a-z0-9]+")

# Values Testudo prints where no real instructor has been assigned. Compared
# after normalization, so "Instructor: TBA", "INSTRUCTOR: TBA" and
# "instructor tba" are all one entry.
#
# Matched whole, never as a substring: "Stafford Jones" is a person, and
# "Tabatha Bacon" must not be caught by a test for "tba".
DENYLIST = frozenset(
    {
        "tba",
        "tbd",
        "staff",
        "instructor",
        "instructor tba",
        "instructor tbd",
        "instructor staff",
        "no instructor",
        "unknown",
        "not assigned",
        "to be announced",
        "to be determined",
    }
)


def _unaccent(value: str) -> str:
    """Strip diacritics the way PostgreSQL's unaccent() does."""
    value = "".join(_UNACCENT_EXTRA.get(char, char) for char in value)
    decomposed = unicodedata.normalize("NFKD", value)
    return "".join(char for char in decomposed if not unicodedata.combining(char))


def normalize_name(raw: str | None) -> str | None:
    """
    Canonical form of a name for matching.

    Unaccent, lowercase, replace every run of non-alphanumeric characters with
    a single space, trim. Returns None for anything that normalizes to nothing.

        'Walsh, Shane Bolles' -> 'walsh shane bolles'
        "Erin O'Brien"        -> 'erin o brien'
        'Jose Garcia'         -> 'jose garcia'

    Punctuation collapses to a space rather than to nothing so that "O'Brien"
    and "O Brien" agree; deleting it would give "obrien", which then fails to
    match the spaced spelling Testudo prints.

    This does NOT reorder "Last, First" into "First Last" - the caller knows
    which source it is holding, and `natural_name()` in grades/parse.py does
    that first. It does not drop middle names either: that is a matching step
    with its own confidence level, not a normalization step.
    """
    if raw is None:
        return None
    collapsed = _NON_ALNUM.sub(" ", _unaccent(raw).lower()).strip()
    return collapsed or None


def slugify(raw: str | None) -> str | None:
    """
    Permanent public URL slug for a professor page.

    Frozen from the moment the first professor page is indexed: changing it
    breaks every shared link and every indexed page. Defined as normalize_name
    with spaces as hyphens, so the two cannot drift apart.

        'Shane Bolles Walsh' -> 'shane-bolles-walsh'
        "Erin O'Brien"       -> 'erin-o-brien'

    Collision handling ('david-levin', 'david-levin-2') needs to see the
    instructors table and lives in the SQL function next_instructor_slug().
    """
    normalized = normalize_name(raw)
    if normalized is None:
        return None
    return normalized.replace(" ", "-")


def is_denylisted(raw: str | None) -> bool:
    """True for placeholder values that must never become instructor records."""
    normalized = normalize_name(raw)
    return normalized is None or normalized in DENYLIST


def surname(normalized: str) -> str:
    """
    Last whitespace-separated token of an already-normalized name.

    Wrong for compound surnames ('de la cruz maria' -> 'maria'). That is
    accepted rather than fixed with a particle list, because being wrong here
    makes the resolver *more* conservative: a surname that does not match sends
    the name to the human queue instead of linking it to the wrong person.
    """
    return normalized.rsplit(" ", 1)[-1]


def first(normalized: str) -> str:
    """First whitespace-separated token of an already-normalized name."""
    return normalized.split(" ", 1)[0]


def first_last(normalized: str) -> str:
    """
    Drop middle names: 'shane bolles walsh' -> 'shane walsh'.

    Middle names and initials appear throughout the registrar exports and
    almost never in Testudo, which makes this the highest-yield matching step
    after an exact hit.
    """
    parts = normalized.split(" ")
    if len(parts) < 2:
        return normalized
    return f"{parts[0]} {parts[-1]}"


def natural_name(raw: str | None) -> str | None:
    """
    Convert the registrar's 'Last, First Middle' to 'First Middle Last'.

    Mirrors `natural_name()` in grades/parse.py, which predates this module and
    is kept there so the parser has no imports outside its own directory.
    Returns None for blank input; a name with no comma is returned unchanged.
    """
    value = (raw or "").strip()
    if not value:
        return None
    if "," not in value:
        return value
    last, rest = value.split(",", 1)
    return f"{rest.strip()} {last.strip()}".strip()
