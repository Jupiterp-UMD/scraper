"""
Parser for UMD grade distribution files obtained by MPIA request.

The Office of the Registrar has exported these files in at least five different
shapes between Fall 2010 and Spring 2026, and there is no reason to expect the
next one to match the last. Rather than switching on the term, this module
locates the header row and maps *whatever* it finds there onto a canonical set
of fields. A term that arrives with a new spelling of "A-minus" needs one entry
added to `HEADER_ALIASES` and nothing else.

Known variants, all handled:

  1. Legacy report dump (Fall 2010 - Spring 2020, Fall 2021 onward in places):
     an optional title line, a "Lead" banner line, the real header
     (`Course,Sect,Professor Name,Total,A,A-,A+,...,Fs,Withdraw,Other`), and a
     row of dashes, before any data. Some files begin with a form feed (\\x0c).
  2. `Lead|Sect` header (Fall 2021 - Spring 2023):
     `COURSE,Lead|Sect,Professor Name,TOTAL,A,...,F,WITHDRAW,OTHER`.
  3. As above plus a `GPA` column (Spring 2021 only).
  4. As above but with instructor names left *unquoted* (Fall 2022), so
     "Walsh, Shane Bolles" arrives split across two CSV fields.
  5. `GR_` prefixed header (Fall 2023 onward), in two spellings:
     `GR_A-`/`GR_A+` and `GR_AM`/`GR_AP`.
  6. The `.repaired.csv` set: one uniform header across every term,
     `TERM,COURSE,SECTION,INSTRUCTOR,TOTAL,A+,...,OTHER,UNGRADED,FILL_SOURCE,
     FILL_CONFIDENCE,NOTES`. Instructor blanks have already been resolved
     upstream, so ~95% of rows arrive named and the carry-forward below rarely
     fires; `instructor_source` is therefore `reported` for essentially every
     attributed row. `FILL_SOURCE` records how each name was actually arrived
     at (`original`, `schedule-section`, `file-course-unanimous`, ...) and is
     deliberately not read -- see README.

Rows are yielded as plain dicts; nothing here touches the database or the
filesystem beyond reading the file it was given.
"""

import csv
import hashlib
import re
from dataclasses import dataclass, field
from pathlib import Path

from terms import detect_term

# Course codes are four letters, three digits, and an optional trailing letter.
COURSE_RE = re.compile(r"^[A-Z]{4}\d{3}[A-Z]?$")

# Placeholder course codes the registrar uses for administrative records
# (ZZZZ99VM, ZZZZ09FR, ZZZZ029, ...). They carry real enrollment counts but no
# real course, so they are dropped rather than stored.
PLACEHOLDER_PREFIX = "ZZZZ"

# The legacy exports put a row of dashes under the header as a rule line.
_RULE_RE = re.compile(r"^-+$")

# Trailer lines emitted by the mainframe job that produced the older exports.
_TRAILERS = {"ELAPSED:", "END OF REPORT", "TOTAL:", "REPORT TOTAL"}

# From Fall 2017 onward, `total` is exactly the sum of the fifteen buckets. In
# every earlier term roughly a quarter of rows report a total that exceeds that
# sum by a small positive amount: those are enrolled students whose outcome the
# older report did not break out into any column, including "Other". The gap is
# preserved rather than papered over, but it is only *surprising* — and so only
# warned about — from this term forward.
EXACT_TOTALS_FROM_TERM = 201708

# About a quarter of rows carry no instructor. They are not anonymous sections:
# the export lists the instructor once, against the lead section, and leaves the
# rows beneath it blank, which is what the "Lead" banner over the section column
# has always meant. The instructor is therefore carried forward within a course.
#
# How far that carry can be trusted varies, so the derivation is recorded rather
# than assumed:
#
#   reported  the export named this instructor directly.
#   lead      carried from the lead section of the same lecture group — the
#             blank row's section code shares its first two characters with the
#             named one (0101 -> 0102, 0103). These are the discussion and lab
#             sections of a lecture, and their students really are that
#             instructor's. Roughly 91% of carried rows.
#   course    carried from a named section elsewhere in the same course, either
#             a different lecture group (0101 -> 0201) or a differently-coded
#             section (0101 -> FC01, SA76, ESG1). Freshman Connection and study
#             abroad sections in particular often have their own instructor, so
#             this tier is separated out and excluded from the default
#             instructor aggregates.
#
# A course in which no section is named at all leaves every row unattributed.
SOURCE_REPORTED = "reported"
SOURCE_LEAD = "lead"
SOURCE_COURSE = "course"

# The fifteen grade buckets, in the order they are stored and reported.
GRADE_FIELDS = (
    "a_plus", "a", "a_minus",
    "b_plus", "b", "b_minus",
    "c_plus", "c", "c_minus",
    "d_plus", "d", "d_minus",
    "f", "w", "other",
)

# The thirteen buckets that carry quality points, with their UMD scale values.
GPA_POINTS = {
    "a_plus": 4.0, "a": 4.0, "a_minus": 3.7,
    "b_plus": 3.3, "b": 3.0, "b_minus": 2.7,
    "c_plus": 2.3, "c": 2.0, "c_minus": 1.7,
    "d_plus": 1.3, "d": 1.0, "d_minus": 0.7,
    "f": 0.0,
}

# Every header spelling seen so far, normalized to lower case with surrounding
# whitespace and form feeds stripped. Add new spellings here.
HEADER_ALIASES = {
    "course": "course_code", "main_course": "course_code",

    "sect": "sec_code", "section": "sec_code", "lead|sect": "sec_code",

    "professor name": "instructor", "name": "instructor",
    # Variant 6 (the `.repaired.csv` set). Without this the column is simply
    # not mapped, and every row loads with a null instructor while the row
    # counts and grade buckets all come out correct -- so the file parses,
    # reports success, and yields 0% instructor coverage.
    "instructor": "instructor",

    "total": "total", "tot": "total",

    "a": "a", "gr_a": "a",
    "a-": "a_minus", "gr_a-": "a_minus", "gr_am": "a_minus",
    "a+": "a_plus", "gr_a+": "a_plus", "gr_ap": "a_plus",

    "b": "b", "gr_b": "b",
    "b-": "b_minus", "gr_b-": "b_minus", "gr_bm": "b_minus",
    "b+": "b_plus", "gr_b+": "b_plus", "gr_bp": "b_plus",

    "c": "c", "gr_c": "c",
    "c-": "c_minus", "gr_c-": "c_minus", "gr_cm": "c_minus",
    "c+": "c_plus", "gr_c+": "c_plus", "gr_cp": "c_plus",

    "d": "d", "gr_d": "d",
    "d-": "d_minus", "gr_d-": "d_minus", "gr_dm": "d_minus",
    "d+": "d_plus", "gr_d+": "d_plus", "gr_dp": "d_plus",

    "f": "f", "fs": "f", "gr_f": "f",
    "w": "w", "withdraw": "w", "gr_w": "w",
    "o": "other", "other": "other", "gr_o": "other",

    # Present in Spring 2021 only, and not reproducible from the counts in that
    # file, so it is read and discarded. See README.
    "gpa": "_reported_gpa",
}

# A row must map at least this many canonical fields to count as the header.
_MIN_HEADER_FIELDS = 15

# The header is always near the top; no file seen has needed more than four.
_HEADER_SEARCH_ROWS = 12


class ParseError(ValueError):
    """Raised when a file cannot be parsed into grade records."""


@dataclass
class ParseReport:
    """Counts and warnings gathered while parsing one file."""

    source: str
    term: int
    header_row: int
    rows: int = 0
    skipped_placeholder: int = 0
    skipped_blank: int = 0
    # Rows where `total` exceeds the sum of the fifteen buckets, and the number
    # of students that accounts for. Expected before Fall 2017; see
    # EXACT_TOTALS_FROM_TERM.
    unaccounted_rows: int = 0
    unaccounted_students: int = 0
    # How each row's instructor was attributed; see SOURCE_* above.
    instructors_reported: int = 0
    instructors_lead: int = 0
    instructors_course: int = 0
    instructors_missing: int = 0
    warnings: list[str] = field(default_factory=list)

    def summary(self) -> str:
        return (
            f"{Path(self.source).name}: term={self.term} rows={self.rows} "
            f"placeholders={self.skipped_placeholder} blank={self.skipped_blank} "
            f"unaccounted={self.unaccounted_students} "
            f"warnings={len(self.warnings)}"
        )


def _clean(cell) -> str:
    """Normalize one raw cell to a string, dropping form feeds and BOMs."""
    if cell is None:
        return ""
    if isinstance(cell, float) and cell.is_integer():
        cell = int(cell)
    return str(cell).replace("\x0c", "").replace("\ufeff", "").strip()


def _read_rows(path: Path):
    """Yield every row of a .csv or .xlsx source as a list of cleaned strings."""
    suffix = path.suffix.lower()
    if suffix in (".xlsx", ".xlsm"):
        import openpyxl  # imported lazily so CSV-only runs need no dependency

        book = openpyxl.load_workbook(path, read_only=True, data_only=True)
        try:
            sheet = book[book.sheetnames[0]]
            for row in sheet.iter_rows(values_only=True):
                yield [_clean(c) for c in row]
        finally:
            book.close()
    elif suffix == ".csv":
        with path.open(newline="", encoding="utf-8-sig", errors="replace") as handle:
            for row in csv.reader(handle):
                yield [_clean(c) for c in row]
    else:
        raise ParseError(f"unsupported file type: {path.suffix} ({path})")


def _map_header(row: list[str]) -> dict[str, int] | None:
    """
    Map a candidate header row to `{canonical_field: column_index}`, or return
    None if the row does not look like a header.
    """
    mapping: dict[str, int] = {}
    for index, cell in enumerate(row):
        canonical = HEADER_ALIASES.get(cell.lower())
        # First spelling wins, so a stray duplicate column cannot shadow the
        # real one.
        if canonical and canonical not in mapping:
            mapping[canonical] = index
    required = {"course_code", "sec_code", "total"}
    if not required.issubset(mapping):
        return None
    if len(mapping) < _MIN_HEADER_FIELDS:
        return None
    return mapping


def _find_header(rows: list[list[str]]) -> tuple[int, dict[str, int]]:
    """Locate the header row and its column mapping."""
    for index, row in enumerate(rows[:_HEADER_SEARCH_ROWS]):
        mapping = _map_header(row)
        if mapping:
            return index, mapping
    raise ParseError(
        "no header row found in the first "
        f"{_HEADER_SEARCH_ROWS} rows; if the registrar has changed the column "
        "names again, add the new spellings to HEADER_ALIASES in parse.py"
    )


def _detect_split_name(header: list[str], mapping: dict[str, int]) -> bool:
    """
    Detect the Fall 2022 defect, where instructor names were written to CSV
    without quoting, so "Walsh, Shane Bolles" occupies two fields.

    The tell is a blank, unmapped header cell immediately after the instructor
    column. A blank cell anywhere else (Fall 2017 has a trailing one) is just an
    extra column and is ignored.
    """
    instructor_index = mapping.get("instructor")
    if instructor_index is None:
        return False
    next_index = instructor_index + 1
    if next_index >= len(header):
        return False
    if header[next_index] != "":
        return False
    return next_index not in mapping.values()


def _resolve_instructor(row: list[str], mapping: dict[str, int], split_name: bool):
    """
    Read the instructor from one row and report how far the columns after it are
    displaced relative to the header.

    In a split-name file the alignment is not a property of the file but of the
    individual row: a name containing a comma consumes two fields and leaves the
    remaining columns where the header says they are, while a blank or
    single-token name consumes one and shifts everything after it left by one.
    Both shapes have the same field count, because the export also carries a
    trailing empty column, so the row length cannot be used to tell them apart.

    The discriminator is the cell after the instructor column: if it parses as
    an integer it is the start of the numeric block, not the tail of a name.

    Returns `(instructor, delta)`, where `delta` is added to every mapped index
    after the instructor column.
    """
    index = mapping.get("instructor")
    if index is None:
        return "", 0
    head = row[index] if index < len(row) else ""
    if not split_name:
        return head, 0
    tail = row[index + 1] if index + 1 < len(row) else ""
    if tail == "" or _is_int(tail):
        # The name occupied a single field; the numeric block starts one column
        # earlier than the header claims.
        return head, -1
    return (f"{head}, {tail}" if head else tail), 0


def _is_int(value: str) -> bool:
    try:
        int(value)
    except ValueError:
        return False
    return True


def normalize_section(raw: str) -> str | None:
    """
    Normalize a section code to the four-character form Jupiterp uses.

    The legacy exports drop leading zeros ("101" for section 0101), while newer
    ones sometimes keep them. Codes containing letters ("FC01", "ESG1", "SA29")
    are already four characters and are passed through upper-cased.
    """
    value = raw.strip().upper()
    if not value:
        return None
    if value.isdigit():
        return value.zfill(4) if len(value) <= 4 else value
    return value


def natural_name(raw: str) -> str | None:
    """
    Convert the registrar's "Last, First Middle" to the "First Middle Last"
    order that Testudo and PlanetTerp use, so the value can be matched against
    `sections.instructors` and `instructors.name`.

    Returns None for blank input. Names without a comma (a bare surname such as
    "Koppel") are returned unchanged.
    """
    value = (raw or "").strip()
    if not value:
        return None
    if "," not in value:
        return value
    last, rest = value.split(",", 1)
    return f"{rest.strip()} {last.strip()}".strip()


def carry_tier(from_sec: str, to_sec: str) -> str:
    """
    Classify a carried instructor attribution by the two section codes involved.

    Sections in the same lecture group share the first two characters of their
    code, so 0101 -> 0102 is a discussion of that lecture and 0101 -> 0201 is a
    different lecture entirely. Anything with a letter in it (FC01, SA76, ESG1)
    is a separately-run offering and never counts as the same group.
    """
    if from_sec.isdigit() and to_sec.isdigit() and from_sec[:2] == to_sec[:2]:
        return SOURCE_LEAD
    return SOURCE_COURSE


def compute_gpa(record: dict) -> float | None:
    """
    GPA on the UMD 4.0 scale over graded enrollments.

    Withdrawals and non-letter outcomes are excluded from both the numerator and
    the denominator; a section in which nobody received a letter grade has no
    GPA. Returns None in that case.
    """
    graded = sum(record[key] for key in GPA_POINTS)
    if graded == 0:
        return None
    points = sum(record[key] * weight for key, weight in GPA_POINTS.items())
    return round(points / graded, 3)


def file_digest(path: Path) -> str:
    """SHA-256 of the file's bytes, used to detect re-ingests of the same file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_file(path: str | Path, term: int | None = None) -> tuple[list[dict], ParseReport]:
    """
    Parse one grade distribution file into canonical records.

    Returns the records and a `ParseReport`. `term` overrides term detection;
    when omitted, the term is derived from the filename and, for workbooks, the
    sheet name.
    """
    path = Path(path)
    rows = list(_read_rows(path))
    if not rows:
        raise ParseError(f"{path} is empty")

    hints = [path.stem]
    if path.suffix.lower() in (".xlsx", ".xlsm"):
        import openpyxl

        book = openpyxl.load_workbook(path, read_only=True)
        try:
            # Sheet names such as "pickaprof-202601" carry the registrar's own
            # term code and are preferred over the filename.
            hints.insert(0, book.sheetnames[0])
        finally:
            book.close()

    resolved_term = term if term is not None else detect_term(*hints)

    header_index, mapping = _find_header(rows)
    split_name = _detect_split_name(rows[header_index], mapping)

    report = ParseReport(
        source=path.name, term=resolved_term, header_row=header_index
    )
    if split_name:
        report.warnings.append(
            "instructor names are unquoted in this file; rejoining the two "
            "columns they were split across"
        )

    records: list[dict] = []
    seen: set[tuple[str, str]] = set()
    carry_course: str | None = None
    carry_name: str | None = None
    carry_sec: str | None = None

    for row in rows[header_index + 1:]:
        if not row or all(cell == "" for cell in row):
            report.skipped_blank += 1
            continue

        course = row[mapping["course_code"]].upper() if mapping["course_code"] < len(row) else ""
        if not course:
            # Trailing rows in every file carry enrollment totals with no course
            # code attached; they are summary lines, not sections.
            report.skipped_blank += 1
            continue
        if course.startswith(PLACEHOLDER_PREFIX):
            report.skipped_placeholder += 1
            continue
        if _RULE_RE.match(course) or course in _TRAILERS:
            # The rule line under a legacy header, or a job trailer at the foot.
            report.skipped_blank += 1
            continue
        if not COURSE_RE.match(course):
            report.skipped_placeholder += 1
            report.warnings.append(f"dropped row with unrecognized course code {course!r}")
            continue

        sec_code = normalize_section(row[mapping["sec_code"]])
        if sec_code is None:
            report.warnings.append(f"dropped {course} row with no section code")
            continue

        instructor_raw, delta = _resolve_instructor(row, mapping, split_name)

        # The export lists an instructor once per lecture and leaves the rows
        # beneath it blank, so a blank inherits from the last named section of
        # the same course. State resets at every course boundary; the files are
        # strictly grouped by course, so a course is never revisited.
        if course != carry_course:
            carry_course, carry_name, carry_sec = course, None, None

        reported_name = natural_name(instructor_raw)
        if reported_name:
            instructor_name = reported_name
            instructor_source = SOURCE_REPORTED
            carry_name, carry_sec = reported_name, sec_code
        elif carry_name:
            instructor_name = carry_name
            instructor_source = carry_tier(carry_sec, sec_code)
        else:
            instructor_name = None
            instructor_source = None

        record: dict = {
            "term": resolved_term,
            "course_code": course,
            "sec_code": sec_code,
            # Exactly as printed, and null when the row was blank. Comparing
            # this against `instructor_name` identifies every carried row.
            "instructor": instructor_raw or None,
            "instructor_name": instructor_name,
            "instructor_source": instructor_source,
        }

        if instructor_source == SOURCE_REPORTED:
            report.instructors_reported += 1
        elif instructor_source == SOURCE_LEAD:
            report.instructors_lead += 1
        elif instructor_source == SOURCE_COURSE:
            report.instructors_course += 1
        else:
            report.instructors_missing += 1

        try:
            record["total"] = _as_int(row, mapping["total"] + delta)
            for name in GRADE_FIELDS:
                index = mapping.get(name)
                record[name] = _as_int(row, None if index is None else index + delta)
        except ValueError as err:
            report.warnings.append(f"dropped {course}-{sec_code}: {err}")
            continue

        # From Fall 2017 the reported total is exactly the sum of the buckets.
        # Before then a positive gap is normal and is recorded, not warned
        # about; a gap after that term, or a negative one in any term, means the
        # columns have shifted and is worth surfacing loudly.
        counted = sum(record[name] for name in GRADE_FIELDS)
        gap = record["total"] - counted
        if gap:
            report.unaccounted_rows += 1
            report.unaccounted_students += gap
            if gap < 0 or resolved_term >= EXACT_TOTALS_FROM_TERM:
                report.warnings.append(
                    f"{course}-{sec_code}: total {record['total']} does not match "
                    f"the sum of its grade columns ({counted})"
                )

        key = (course, sec_code)
        if key in seen:
            report.warnings.append(f"duplicate row for {course}-{sec_code}; keeping the first")
            continue
        seen.add(key)

        record["gpa"] = compute_gpa(record)
        records.append(record)
        report.rows += 1

    if not records:
        raise ParseError(f"{path} parsed to zero rows; check the header mapping")

    return records, report


def _as_int(row: list[str], index: int | None) -> int:
    """Read one integer cell, treating a missing column or blank cell as zero."""
    if index is None or index >= len(row):
        return 0
    value = row[index]
    if value == "":
        return 0
    try:
        return int(float(value))
    except ValueError:
        raise ValueError(f"expected an integer, found {value!r}") from None
