#!/usr/bin/env python3
"""
gradefix - repair UMD/UMCP grade-distribution files using Schedule of Classes catalogs.

The grade-distribution exports have a systematic defect: the instructor column is
blank for ~25-30% of section rows (the source PDF only prints the name once per
"instructor group", and the rest of the rows come through empty). They also carry
PDF-extraction litter: page headers, dashed rule rows, form feeds, drifting column
counts, and missing course codes in the trailing ZZZZ block.

This tool rebuilds the missing information from the printed Schedule of Classes for
the same term, then falls back to evidence inside the grade file itself.

Subcommands
-----------
  roster     build a canonical instructor-name roster from any number of grade files
  schedule   parse a Schedule of Classes .txt into a course/section/instructor index
  repair     repair one grade file (optionally aligning the schedule as it goes)
  batch      pair grade files with schedules by term and repair all of them
  audit      report on the state of a grade file (damage / repair coverage)

Quick start
-----------
  python gradefix.py roster grades/*.csv grades/*.xlsx -o roster.json
  python gradefix.py repair grades/spring2023.csv -s catalogs/spring-2023.txt \
         -r roster.json -o out/spring2023.csv --log out/spring2023.log.csv
  python gradefix.py batch --grades grades/ --catalogs catalogs/ --out out/

Only the standard library is required; openpyxl is needed for .xlsx input/output.
"""

from __future__ import annotations

import argparse
import collections
import csv
import glob
import json
import os
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

VERSION = "1.0"

# --------------------------------------------------------------------------------------
# canonical schema
# --------------------------------------------------------------------------------------

GRADE_COLS = ["A+", "A", "A-", "B+", "B", "B-", "C+", "C", "C-",
              "D+", "D", "D-", "F", "W", "OTHER"]
CANON_COLS = ["COURSE", "SECTION", "INSTRUCTOR", "TOTAL"] + GRADE_COLS

# Every header spelling seen across 2010-2026 exports, mapped to the canonical name.
HEADER_ALIASES = {
    "course": "COURSE", "main_course": "COURSE",
    "sect": "SECTION", "section": "SECTION", "lead|sect": "SECTION", "lead sect": "SECTION",
    "professor name": "INSTRUCTOR", "name": "INSTRUCTOR", "instructor": "INSTRUCTOR",
    "total": "TOTAL", "tot": "TOTAL",
    "gpa": "GPA",
    "a": "A", "gr_a": "A",
    "a-": "A-", "gr_a-": "A-", "gr_am": "A-", "am": "A-",
    "a+": "A+", "gr_a+": "A+", "gr_ap": "A+", "ap": "A+",
    "b": "B", "gr_b": "B",
    "b-": "B-", "gr_b-": "B-", "gr_bm": "B-", "bm": "B-",
    "b+": "B+", "gr_b+": "B+", "gr_bp": "B+", "bp": "B+",
    "c": "C", "gr_c": "C",
    "c-": "C-", "gr_c-": "C-", "gr_cm": "C-", "cm": "C-",
    "c+": "C+", "gr_c+": "C+", "gr_cp": "C+", "cp": "C+",
    "d": "D", "gr_d": "D",
    "d-": "D-", "gr_d-": "D-", "gr_dm": "D-", "dm": "D-",
    "d+": "D+", "gr_d+": "D+", "gr_dp": "D+", "dp": "D+",
    "f": "F", "fs": "F", "gr_f": "F",
    "w": "W", "withdraw": "W", "gr_w": "W",
    "other": "OTHER", "gr_o": "OTHER", "o": "OTHER",
}

COURSE_RE = re.compile(r"^[A-Z]{4}\d{3}[A-Z]?$")
SECTION_RE = re.compile(r"^[0-9A-Z]{2,4}$")


# --------------------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------------------

def deaccent(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c))


SUFFIXES = {"jr", "sr", "ii", "iii", "iv", "phd", "md"}
PARTICLES = {"van", "von", "de", "del", "della", "di", "da", "la", "le", "el",
             "st", "mac", "ter", "ten", "bin", "al", "der", "den"}


def norm_words(s: str) -> List[str]:
    """Lowercase, strip accents and punctuation. Initials are kept - they carry signal."""
    s = deaccent(s or "").lower()
    s = re.sub(r"[^a-z\s-]", " ", s)
    return [w for w in s.split() if w and w not in SUFFIXES]


def split_name(name: str) -> Optional[Tuple[List[str], str]]:
    """Return (given-name tokens, surname) for either 'Last, First M' or 'First M Last'."""
    if not name:
        return None
    if "," in name:
        last, first = name.split(",", 1)
        lt, ft = norm_words(last), norm_words(first)
        if not lt:
            return None
        return ft, lt[-1]
    t = norm_words(name)
    if len(t) < 2:
        return (t, t[0]) if t else None
    i = len(t) - 1
    while i > 1 and t[i - 1] in PARTICLES:
        i -= 1
    return t[:i], t[-1]


def name_key(name: str) -> Optional[str]:
    """Coarse bucket key: the surname. Comparisons use names_match()."""
    sp = split_name(name)
    return sp[1] if sp else None


def _edit1(a: str, b: str) -> bool:
    """True if a and b are within one edit - catches OCR damage ('Mary!' vs 'Maryl')."""
    if a == b:
        return True
    la, lb = len(a), len(b)
    if abs(la - lb) > 1:
        return False
    if la == lb:
        return sum(1 for x, y in zip(a, b) if x != y) == 1
    if la > lb:
        a, b, la, lb = b, a, lb, la
    for i in range(lb):
        if a == b[:i] + b[i + 1:]:
            return True
    return False


def _first_ok(fa: List[str], fb: List[str]) -> bool:
    if not fa or not fb:
        return True                       # one side gave no given name at all
    for x in fa:
        for y in fb:
            if len(x) == 1 or len(y) == 1:
                if x[0] == y[0]:
                    return True
            elif x == y or x.startswith(y) or y.startswith(x):
                return True
            # Typo tolerance only where a typo is likelier than a different
            # person: short given names one letter apart are routinely distinct
            # ("Quan" / "Xuan" put an epidemiologist on MATH401-0501, S26).
            elif min(len(x), len(y)) >= 5 and x[0] == y[0] and _edit1(x, y):
                return True
    return False


def names_match(a: str, b: str) -> bool:
    """Compare a catalog name to a grade-file name across format, initials and typos."""
    sa, sb = split_name(a), split_name(b)
    if not sa or not sb:
        return False
    la, lb = sa[1], sb[1]
    if not (la == lb or (min(len(la), len(lb)) >= 5 and _edit1(la, lb))):
        return False
    return _first_ok(sa[0], sb[0])


def any_match(name: str, candidates: Iterable[str]) -> bool:
    return any(names_match(name, c) for c in candidates)


def split_instructors(raw: str) -> List[str]:
    """'Sarah Balcom, Andrew Broadbent' -> two names. Comma-last-first stays whole."""
    raw = (raw or "").strip()
    if not raw:
        return []
    parts = [p.strip() for p in re.split(r"\s*(?:;|/| and |&)\s*", raw) if p.strip()]
    out = []
    for p in parts:
        # A schedule line lists names as "First Last", so a comma separates PEOPLE.
        # A grade file lists "Last, First", so a comma is internal. Distinguish by
        # checking whether each comma-piece already looks like a full name.
        pieces = [x.strip() for x in p.split(",") if x.strip()]
        if len(pieces) > 1 and all(len(norm_words(x)) >= 2 for x in pieces):
            out.extend(pieces)
        else:
            out.append(p)
    return out


def to_last_first(name: str) -> str:
    """'Barnet Pavao-Zuckerman' -> 'Pavao-Zuckerman, Barnet'. Already-comma names pass."""
    name = (name or "").strip()
    if not name or "," in name:
        return name
    toks = name.split()
    if len(toks) < 2:
        return name
    particles = {"van", "von", "de", "del", "della", "di", "da", "la", "le", "el",
                 "st", "st.", "mac", "ter", "ten", "bin", "al"}
    i = len(toks) - 1
    while i > 1 and toks[i - 1].lower().strip(".") in particles:
        i -= 1
    return f"{' '.join(toks[i:])}, {' '.join(toks[:i])}"


def norm_section(s) -> str:
    """Sections appear as 101, '0101', 101.0, 'SO01'. Canonicalize to 4 chars."""
    if s is None:
        return ""
    if isinstance(s, float) and s.is_integer():
        s = int(s)
    s = str(s).strip().upper()
    if s.endswith(".0"):
        s = s[:-2]
    if s.isdigit():
        s = s.zfill(4)
    return s


def parse_term(text: str) -> Optional[str]:
    m = re.search(r"(spring|summer|fall|winter)[\s_\-]*((?:19|20)\d{2})", text, re.I)
    if m:
        return f"{m.group(1).capitalize()} {m.group(2)}"
    m = re.search(r"((?:19|20)\d{2})[\s_\-]*(spring|summer|fall|winter)", text, re.I)
    if m:
        return f"{m.group(2).capitalize()} {m.group(1)}"
    return None


def is_int(x) -> bool:
    try:
        int(str(x).strip())
        return True
    except (TypeError, ValueError):
        return False


# --------------------------------------------------------------------------------------
# grade file loading
# --------------------------------------------------------------------------------------

@dataclass
class GradeRow:
    course: str = ""
    section: str = ""
    instructor: str = ""
    values: Dict[str, str] = field(default_factory=dict)
    extra: Dict[str, str] = field(default_factory=dict)
    source_line: int = 0
    # repair provenance
    fill_source: str = ""
    fill_confidence: str = ""
    notes: str = ""


@dataclass
class GradeFile:
    path: str
    term: Optional[str]
    rows: List[GradeRow]
    dropped: List[Tuple[int, list]]
    header_variant: str
    has_gpa: bool


def _raw_rows(path: str) -> List[list]:
    ext = os.path.splitext(path)[1].lower()
    if ext in (".xlsx", ".xlsm"):
        try:
            import openpyxl
        except ImportError:
            sys.exit("openpyxl is required to read .xlsx files:  pip install openpyxl")
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        ws = wb[wb.sheetnames[0]]
        rows = [["" if c is None else c for c in r] for r in ws.iter_rows(values_only=True)]
        wb.close()
        return rows
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as fh:
        sample = fh.read(8192)
        fh.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",\t;")
        except csv.Error:
            dialect = csv.excel
        return [r for r in csv.reader(fh, dialect)]


def _find_header(rows: Sequence[list]) -> Tuple[int, List[str]]:
    """Locate the real header row; PDF exports bury it under 1-3 junk lines."""
    best = (-1, -1, [])
    for i, r in enumerate(rows[:12]):
        cells = [str(c).strip().lower().replace("\x0c", "") for c in r]
        hits = sum(1 for c in cells if c in HEADER_ALIASES)
        if hits > best[1]:
            best = (i, hits, cells)
    idx, hits, cells = best
    if hits < 4:
        return -1, []
    return idx, cells


def load_grade_file(path: str, term: Optional[str] = None) -> GradeFile:
    rows = _raw_rows(path)
    hidx, header = _find_header(rows)
    if hidx < 0:
        raise ValueError(f"{path}: could not find a recognizable header row")

    # Map each physical column to a canonical name; unknown/blank columns are kept
    # positionally so nothing is silently lost.
    colmap: Dict[int, str] = {}
    used = set()
    for j, h in enumerate(header):
        canon = HEADER_ALIASES.get(h)
        if canon and canon not in used:
            colmap[j] = canon
            used.add(canon)

    # Some exports (Fall 2016/2017) shift by a leading blank/form-feed column; if the
    # essentials are missing, fall back to fixed positional order.
    if not {"COURSE", "SECTION", "INSTRUCTOR", "TOTAL"} <= used:
        order = ["COURSE", "SECTION", "INSTRUCTOR", "TOTAL"] + \
                ["A", "A-", "A+", "B", "B-", "B+", "C", "C-", "C+",
                 "D", "D-", "D+", "F", "W", "OTHER"]
        colmap = {j: order[j] for j in range(min(len(order), max(len(r) for r in rows[:50])))}
        used = set(colmap.values())

    has_gpa = "GPA" in used
    variant = ",".join(h for h in header if h)[:60]

    out: List[GradeRow] = []
    dropped: List[Tuple[int, list]] = []
    last_course = ""

    for n, r in enumerate(rows[hidx + 1:], start=hidx + 2):
        cells = [("" if c is None else str(c)).replace("\x0c", "").strip() for c in r]
        if not any(cells):
            continue
        joined = "".join(cells)
        if set(joined) <= set("- "):                      # dashed rule row
            dropped.append((n, cells)); continue
        low = joined.lower()
        if low.startswith("universityofmaryland") or "gradedistribution" in low.replace(" ", ""):
            dropped.append((n, cells)); continue
        if any(c.lower() in HEADER_ALIASES for c in cells[:3]) and not is_int(
                cells[3] if len(cells) > 3 else ""):
            dropped.append((n, cells)); continue        # repeated page header

        g = GradeRow(source_line=n)
        for j, c in enumerate(cells):
            canon = colmap.get(j)
            if canon == "COURSE":
                g.course = c.upper()
            elif canon == "SECTION":
                g.section = norm_section(c)
            elif canon == "INSTRUCTOR":
                g.instructor = re.sub(r"\s+", " ", c).strip()
            elif canon:
                g.values[canon] = c
            elif c:
                g.extra[f"COL{j}"] = c

        if not g.section and not g.course:
            dropped.append((n, cells)); continue

        # trailing ZZZZ block loses its course code on continuation rows
        if not g.course and last_course:
            g.course = last_course
            g.notes = "course_code_forward_filled"
        if g.course:
            last_course = g.course
        out.append(g)

    return GradeFile(path=path,
                     term=term or parse_term(os.path.basename(path)),
                     rows=out, dropped=dropped,
                     header_variant=variant, has_gpa=has_gpa)


# --------------------------------------------------------------------------------------
# roster of canonical instructor names
# --------------------------------------------------------------------------------------

class Roster:
    """Maps a (first,last) key to the canonical 'Last, First Middle' spelling that the
    grade files themselves use, so schedule names come out in the same format."""

    def __init__(self, counts: Optional[Dict[str, Dict[str, int]]] = None):
        self.counts: Dict[str, Dict[str, int]] = counts or {}

    def add(self, name: str) -> None:
        k = name_key(name)
        if not k or "," not in name:
            return
        bucket = self.counts.setdefault(k, {})
        bucket[name] = bucket.get(name, 0) + 1

    def build(self, paths: Iterable[str]) -> "Roster":
        for p in paths:
            try:
                gf = load_grade_file(p)
            except Exception as e:                       # noqa: BLE001
                print(f"  ! skipping {p}: {e}", file=sys.stderr)
                continue
            for r in gf.rows:
                if r.instructor:
                    self.add(r.instructor)
        return self

    def canonical(self, name: str) -> Tuple[str, bool]:
        """Return (canonical 'Last, First' spelling used by the grade files, matched?)."""
        k = name_key(name)
        if k:
            bucket = self.counts.get(k)
            if bucket:
                cands = [(c, n) for c, n in bucket.items() if names_match(name, c)]
                if cands:
                    return max(cands, key=lambda kv: (kv[1], len(kv[0])))[0], True
        return to_last_first(name), False

    def save(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": VERSION, "counts": self.counts}, fh, indent=0)

    @classmethod
    def load(cls, path: str) -> "Roster":
        with open(path, encoding="utf-8") as fh:
            return cls(json.load(fh)["counts"])


# --------------------------------------------------------------------------------------
# Schedule of Classes parsing
# --------------------------------------------------------------------------------------

@dataclass
class Block:
    """One course entry in the catalog: a title/grading-method header plus its sections."""
    line: int
    title: str = ""
    code: Optional[str] = None                 # set directly (old format) or by alignment
    anchor: Optional[str] = None               # code printed on this block's own title line
    anchor_idx: int = -1                       # position of that code in the code stream
    sections: Dict[str, List[str]] = field(default_factory=dict)


CODE_ONLY_RE = re.compile(r"^([A-Z]{4}\d{3}[A-Z]?)\s*$")
# some titles keep the code on the same line: "AGNR301 Sustainability" - a hard anchor
CODE_TITLE_RE = re.compile(r"^([A-Z]{4}\d{3}[A-Z]?)\s+([A-Z][^;]{3,})$")
# new format (2013+): "0101* Shane Walsh Seats (Total: 35)"
SEC_INLINE_RE = re.compile(r"^(\d{4}[A-Z]?)\*?\s+(.+?)\s+Seats\s*\(\s*Total:", re.I)
SEC_NOSEATS_RE = re.compile(r"^(\d{4}[A-Z]?)\*?\s+([A-Z][^,;()]*(?:,\s*[A-Z][^,;()]*)*)\s*$")
SEC_ALONE_RE = re.compile(r"^(\d{4}[A-Z]?)\*?\s*$")
# old format (<=2012): "AASP100 Introduction to ...; (3 credits) Grade Method: REG/P-F/AUD."
# The header frequently wraps, so the code is matched on its own line and the credits /
# grade-method marker is looked for in the next couple of lines.
OLD_HEADER_RE = re.compile(
    r"^([A-Z]{4}\d{3}[A-Z]?)\s+(?:\(PermReq\)\s*)?(.+?);?\s*\(\s*\d+(?:-\d+)?\s*credits?\s*\)\s*Grade Method", re.I)
OLD_HEADER_START_RE = re.compile(r"^([A-Z]{4}\d{3}[A-Z]?)\s+(?:\(PermReq\)\s*)?([A-Z(].*)$")
OLD_HEADER_TAIL_RE = re.compile(r"\(\s*\d+(?:-\d+)?\s*credits?\s*\)|Grade Method", re.I)
NOISE_RE = re.compile(r"^(seats|total|held|meets|discussion|laboratory|lab|lecture|online|tba)\b", re.I)
TIME_RE = re.compile(r"\d{1,2}:\d{2}\s*[ap]m", re.I)


def _clean_instructor(s: str) -> str:
    s = re.sub(r"\s+", " ", s or "").strip(" .*")
    s = re.sub(r"\(.*?\)", "", s).strip()
    if not s or NOISE_RE.match(s) or TIME_RE.search(s):
        return ""
    if s.lower() in ("instructor: tba", "tba", "staff", "instructor tba", "to be announced"):
        return ""
    return s


def parse_schedule_new(lines: List[str]) -> Tuple[List[Block], List[Tuple[int, str]]]:
    """2013+ layout: bare course codes in the margin, 'Grading Method:' starts a block."""
    blocks: List[Block] = []
    codes: List[Tuple[int, str]] = []
    cur: Optional[Block] = None
    pending_title = ""
    pending_anchor: Optional[str] = None
    pending_anchor_idx = -1
    pending_line = -10 ** 6
    last_gm = -10

    for i, raw in enumerate(lines):
        s = raw.strip()
        if not s:
            continue
        m = CODE_ONLY_RE.match(s)
        if m:
            codes.append((i, m.group(1)))
            continue
        m = CODE_TITLE_RE.match(s)
        if m and "Seats" not in s and not TIME_RE.search(s):
            codes.append((i, m.group(1)))
            pending_anchor_idx = len(codes) - 1
            pending_anchor = m.group(1)
            pending_title = m.group(2).strip()
            pending_line = i
            continue
        if "Grading Method" in s:
            # The marker is not always at line start: later catalogs fold the credit count
            # in front of it ("Credits: 4 Grading Method: Regular") or prefix a permission
            # note ("(Perm req) Credits: 1-6 Grading Method: ..."), and ~29% of Spring 2026
            # blocks are missed by a startswith test.
            if i - last_gm > 4:                       # collapse wrapped continuations
                near = pending_anchor is not None and (i - pending_line) <= 40
                cur = Block(line=i, title=pending_title,
                            anchor=pending_anchor if near else None,
                            anchor_idx=pending_anchor_idx if near else -1)
                blocks.append(cur)
                pending_title = ""
                pending_anchor = None
                pending_anchor_idx = -1
            last_gm = i
            continue

        m = SEC_INLINE_RE.match(s)
        if not m and SEC_ALONE_RE.match(s):
            # "Seats (Total:" wrapped onto the following line
            nxt = next((lines[j].strip() for j in range(i + 1, min(i + 4, len(lines)))
                        if lines[j].strip()), "")
            if "Seats" in nxt:
                m = re.match(r"^(\d{4}[A-Z]?)\*?", s)
                name = _clean_instructor(nxt.split("Seats")[0])
                if m and cur is not None:
                    cur.sections.setdefault(m.group(1), [])
                    if name:
                        cur.sections[m.group(1)] = split_instructors(name)
                continue
        if m:
            sec, name = m.group(1), _clean_instructor(m.group(2))
            if cur is not None:
                cur.sections[sec] = split_instructors(name)
            continue

        if (len(s) > 3 and not TIME_RE.search(s) and not s[0].isdigit()
                and not s.startswith(("*", "Credit", "Prerequisite", "Restricted", "Formerly",
                                      "Recommended", "Students", "Additional", "Contact",
                                      "Also offered", "Jointly", "This ", "http"))):
            if len(s) < 120:
                pending_title = s
                pending_anchor, pending_anchor_idx = None, -1
                pending_line = i
    return blocks, codes


def parse_schedule_old(lines: List[str]) -> Tuple[List[Block], List[Tuple[int, str]]]:
    """<=2012 layout: 'CODE Title; (3 credits) Grade Method:' header, one field per line.

    The header wraps freely across two or three physical lines, so a candidate header is
    stitched together from the code line plus its successors before being tested.
    """
    blocks: List[Block] = []
    cur: Optional[Block] = None
    i = 0
    n = len(lines)
    while i < n:
        s = lines[i].strip()
        m = OLD_HEADER_START_RE.match(s)
        if m:
            joined = s
            k = i
            for j in range(i + 1, min(i + 4, n)):
                if OLD_HEADER_TAIL_RE.search(joined):
                    break
                nxt = lines[j].strip()
                if not nxt or OLD_HEADER_START_RE.match(nxt) or SEC_ALONE_RE.match(nxt):
                    break
                joined = joined + " " + nxt
                k = j
            if OLD_HEADER_TAIL_RE.search(joined):
                title = re.split(r";?\s*\(\s*\d+(?:-\d+)?\s*credits?\s*\)|Grade Method",
                                 m.group(2), maxsplit=1)[0]
                if len(title) < 4 and k > i:
                    title = re.split(r";?\s*\(\s*\d+", joined[len(m.group(1)):], maxsplit=1)[0]
                cur = Block(line=i, title=title.strip(" ;"), code=m.group(1))
                blocks.append(cur)
                i = k + 1
                continue
        m = SEC_ALONE_RE.match(s)
        if m and cur is not None:
            sec = m.group(1)
            # instructor is the next non-empty line that isn't a time/room/"Seats"
            name = ""
            for j in range(i + 1, min(i + 8, n)):
                t = lines[j].strip()
                if not t:
                    continue
                if t.startswith("Seats") or SEC_ALONE_RE.match(t):
                    break
                cand = _clean_instructor(t)
                if cand:
                    name = cand
                    break
            if sec not in cur.sections or name:
                cur.sections[sec] = split_instructors(name) if name else []
        i += 1
    return blocks, []


def detect_format(lines: List[str]) -> str:
    old = sum(1 for l in lines[:6000] if OLD_HEADER_RE.match(l.strip()))
    new = sum(1 for l in lines[:6000] if "Grading Method" in l)
    return "old" if old > new else "new"


@dataclass
class Schedule:
    term: Optional[str]
    source: str
    fmt: str
    index: Dict[str, Dict[str, List[str]]]      # course -> section -> [instructors]
    unaligned_blocks: int = 0
    aligned_blocks: int = 0

    def get(self, course: str, section: str) -> List[str]:
        return self.index.get(course, {}).get(norm_section(section), [])

    def course_instructors(self, course: str) -> List[str]:
        names = [n for sec in self.index.get(course, {}).values() for n in sec]
        return names

    def save(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": VERSION, "term": self.term, "source": self.source,
                       "format": self.fmt, "aligned": self.aligned_blocks,
                       "unaligned": self.unaligned_blocks, "index": self.index}, fh)

    @classmethod
    def load(cls, path: str) -> "Schedule":
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        return cls(term=d.get("term"), source=d.get("source", path), fmt=d.get("format", "?"),
                   index=d["index"], aligned_blocks=d.get("aligned", 0),
                   unaligned_blocks=d.get("unaligned", 0))


def align_blocks_to_codes(blocks: List[Block], codes: List[Tuple[int, str]],
                          evidence: Optional[Dict[str, Dict[str, str]]] = None,
                          band: int = 80) -> Tuple[int, int]:
    """Assign a course code to each block.

    The PDF is two-column, so the margin course codes and the body blocks arrive in the
    same order but not interleaved reliably - a naive "next code" rule drifts whenever a
    block spans a page break. This is a banded monotone sequence alignment: codes and
    blocks both stay in order, and a pairing is scored by how well the block's
    (section -> instructor) pairs agree with the instructor names the grade file already
    knows for that course. With no grade file, position alone decides.
    """
    if not codes or not blocks:
        return 0, len(blocks)

    # Blocks whose title line carried the course code are certainties. Pin them, then
    # solve each gap between consecutive pins independently - the segments are short,
    # so drift can never propagate across the whole catalog.
    pins = [(bj, b.anchor_idx) for bj, b in enumerate(blocks)
            if b.anchor and b.anchor_idx >= 0]
    pins = [p for p in pins if codes[p[1]][1] == blocks[p[0]].anchor]
    aligned = 0
    prev_b, prev_c = -1, -1
    for bj, ci in pins + [(len(blocks), len(codes))]:
        if bj < len(blocks):
            blocks[bj].code = codes[ci][1]
            aligned += 1
        seg_b = list(range(prev_b + 1, bj))
        seg_c = list(range(prev_c + 1, ci))
        aligned += _align_segment(blocks, codes, seg_b, seg_c, evidence, band)
        prev_b, prev_c = bj, ci
    return aligned, sum(1 for b in blocks if not b.code)


def _align_segment(blocks: List[Block], codes: List[Tuple[int, str]],
                   seg_b: List[int], seg_c: List[int],
                   evidence: Optional[Dict[str, Dict[str, str]]], band: int) -> int:
    m, n = len(seg_c), len(seg_b)
    if not m or not n:
        return 0

    def score(i: int, j: int) -> float:
        code = codes[seg_c[i]][1]
        blk = blocks[seg_b[j]]
        s = 0.5 - 0.01 * abs(i - j)
        if evidence is not None:
            known = evidence.get(code)
            if known is None:
                return s - 0.5
            for sec, names in blk.sections.items():
                truth = known.get(sec)
                if truth is None:
                    s -= 0.4                       # section not offered under this code
                elif truth == "":
                    s += 0.6                       # section exists, name unknown: structural hit
                else:
                    s += 3.0 if any_match(truth, names) else -1.5
        return s

    NEG = float("-inf")
    prev = {}

    def window(i: int) -> Tuple[int, int]:
        """Band centred on the proportional diagonal, so steady drift between the two
        sequence lengths never pushes the end cell outside the search area."""
        c = round(i * n / m) if m else 0
        return max(0, c - band), min(n, c + band)

    # only the band of each row is materialised
    row_prev = {0: 0.0} if window(0)[0] == 0 else {}
    dp_rows = [row_prev]
    for i in range(1, m + 1):
        lo, hi = window(i)
        row = {}
        for j in range(lo, hi + 1):
            best, arg = NEG, None
            v = row_prev.get(j)
            if v is not None:                              # code with no block
                best, arg = v - 0.05, "c"
            v = row.get(j - 1)
            if v is not None:                              # block with no code (costly)
                v -= 2.0
                if v > best:
                    best, arg = v, "b"
            v = row_prev.get(j - 1)
            if v is not None:
                v += score(i - 1, j - 1)
                if v > best:
                    best, arg = v, "m"
            if arg is not None:
                row[j] = best
                prev[(i, j)] = arg
        dp_rows.append(row)
        row_prev = row

    i, j = m, n
    if j not in dp_rows[i]:
        cand = [(v, a, b) for a, r in enumerate(dp_rows) for b, v in r.items()]
        _, i, j = max(cand)
    aligned = 0
    while (i, j) in prev:
        op = prev[(i, j)]
        if op == "m":
            blocks[seg_b[j - 1]].code = codes[seg_c[i - 1]][1]
            aligned += 1
            i, j = i - 1, j - 1
        elif op == "c":
            i -= 1
        else:
            j -= 1
    return aligned


def build_schedule(path: str, evidence_file: Optional[GradeFile] = None,
                   band: int = 80) -> Schedule:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    fmt = detect_format(lines)
    if fmt == "old":
        blocks, codes = parse_schedule_old(lines)
        aligned, unaligned = len(blocks), 0
    else:
        blocks, codes = parse_schedule_new(lines)
        evidence = None
        if evidence_file is not None:
            evidence = collections.defaultdict(dict)
            for r in evidence_file.rows:
                evidence[r.course][r.section] = r.instructor
            evidence = dict(evidence)
        aligned, unaligned = align_blocks_to_codes(blocks, codes, evidence, band)

    index: Dict[str, Dict[str, List[str]]] = collections.defaultdict(dict)
    for b in blocks:
        if not b.code:
            continue
        for sec, names in b.sections.items():
            if names or sec not in index[b.code]:
                index[b.code][sec] = names
    term = parse_term(os.path.basename(path)) or parse_term("\n".join(lines[:40]))
    return Schedule(term=term, source=path, fmt=fmt, index=dict(index),
                    aligned_blocks=aligned, unaligned_blocks=unaligned)


# --------------------------------------------------------------------------------------
# repair engine
# --------------------------------------------------------------------------------------

@dataclass
class RepairStats:
    total: int = 0
    already: int = 0
    blank: int = 0
    filled: Dict[str, int] = field(default_factory=lambda: collections.Counter())
    unfilled: int = 0
    checked: int = 0
    agree: int = 0
    disagree: int = 0
    conflicts: List[Tuple[str, str, str, str]] = field(default_factory=list)


def repair(gf: GradeFile, sched: Optional[Schedule], roster: Roster,
           allow_course_unanimous: bool = True,
           allow_file_unanimous: bool = True,
           overwrite_conflicts: bool = False) -> RepairStats:
    st = RepairStats()

    # evidence from the grade file itself: course -> set of known instructors
    by_course: Dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    local = Roster()
    for r in gf.rows:
        if r.instructor:
            by_course[r.course][r.instructor] += 1
            local.add(r.instructor)

    def canon(name: str) -> str:
        """Prefer the spelling this file already uses, so a term stays self-consistent."""
        n, hit = local.canonical(name)
        return n if hit else roster.canonical(name)[0]

    for r in gf.rows:
        st.total += 1
        if r.instructor:
            st.already += 1
            if sched:
                names = sched.get(r.course, r.section)
                if names:
                    st.checked += 1
                    if any_match(r.instructor, names):
                        st.agree += 1
                        r.fill_source = "original+schedule-confirmed"
                        r.fill_confidence = "high"
                    else:
                        st.disagree += 1
                        alt = canon(names[0])
                        if len(st.conflicts) < 500:
                            st.conflicts.append((r.course, r.section, r.instructor, alt))
                        if overwrite_conflicts:
                            r.notes = (r.notes + ";" if r.notes else "") + \
                                      f"replaced_original={r.instructor}"
                            r.instructor = alt
                            r.fill_source = "schedule-override"
                            r.fill_confidence = "medium"
                        else:
                            r.fill_source = "original"
                            r.fill_confidence = "high"
                            r.notes = (r.notes + ";" if r.notes else "") + \
                                      f"schedule_disagrees={alt}"
                else:
                    r.fill_source = "original"
                    r.fill_confidence = "high"
            else:
                r.fill_source = "original"
                r.fill_confidence = "high"
            continue

        st.blank += 1

        # 1. exact (course, section) hit in the Schedule of Classes
        if sched:
            names = sched.get(r.course, r.section)
            if names:
                r.instructor = "; ".join(canon(n) for n in names)
                r.fill_source = "schedule-section"
                r.fill_confidence = "high"
                st.filled["schedule-section"] += 1
                continue

        # 2. every listed section of this course in the catalog has the same instructor
        if sched and allow_course_unanimous:
            names = sched.course_instructors(r.course)
            keys = {name_key(n) for n in names if name_key(n)}
            if len(keys) == 1 and names:
                r.instructor = canon(names[0])
                r.fill_source = "schedule-course-unanimous"
                r.fill_confidence = "medium"
                st.filled["schedule-course-unanimous"] += 1
                continue

        # 3. every named row of this course in this same file has the same instructor
        if allow_file_unanimous:
            c = by_course.get(r.course)
            if c:
                keys = {name_key(n) for n in c}
                if len(keys) == 1:
                    r.instructor = c.most_common(1)[0][0]
                    r.fill_source = "file-course-unanimous"
                    r.fill_confidence = "medium"
                    st.filled["file-course-unanimous"] += 1
                    continue

        r.fill_source = "unresolved"
        r.fill_confidence = "none"
        st.unfilled += 1
    return st


# --------------------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------------------

def write_repaired(gf: GradeFile, path: str, term: Optional[str]) -> None:
    cols = ["TERM"] + CANON_COLS + ["FILL_SOURCE", "FILL_CONFIDENCE", "NOTES"]
    ext = os.path.splitext(path)[1].lower()
    rows = []
    for r in gf.rows:
        rows.append([term or "", r.course, r.section, r.instructor,
                     r.values.get("TOTAL", "")] +
                    [r.values.get(c, "") for c in GRADE_COLS] +
                    [r.fill_source, r.fill_confidence, r.notes])
    if ext in (".xlsx", ".xlsm"):
        import openpyxl
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "repaired"
        ws.append(cols)
        for row in rows:
            ws.append(row)
        wb.save(path)
        return
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        w.writerows(rows)


def write_log(gf: GradeFile, path: str, term: Optional[str], st: RepairStats) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["term", "course", "section", "action", "value", "confidence", "notes",
                    "source_line"])
        for r in gf.rows:
            if r.fill_source in ("original", "original+schedule-confirmed") and not r.notes:
                continue
            action = "filled" if r.fill_source.startswith(("schedule-", "file-")) else r.fill_source
            w.writerow([term or "", r.course, r.section, action, r.instructor,
                        r.fill_confidence, r.notes, r.source_line])


def print_stats(name: str, gf: GradeFile, sched: Optional[Schedule], st: RepairStats) -> None:
    print(f"\n=== {name} ===")
    print(f"  term                 {gf.term or '(unknown)'}")
    print(f"  rows kept            {st.total}   (dropped {len(gf.dropped)} junk lines)")
    if sched:
        print(f"  catalog              {os.path.basename(sched.source)} "
              f"[{sched.fmt}] {len(sched.index)} courses, "
              f"{sum(len(v) for v in sched.index.values())} sections, "
              f"{sched.aligned_blocks} blocks aligned / {sched.unaligned_blocks} orphan")
    print(f"  instructor present   {st.already}")
    print(f"  instructor missing   {st.blank}")
    for k, v in sorted(st.filled.items(), key=lambda kv: -kv[1]):
        print(f"      filled by {k:<28} {v:>6}  ({v / max(st.blank,1):.1%} of gaps)")
    print(f"      still unresolved {'':<28}{st.unfilled:>6}  "
          f"({st.unfilled / max(st.blank,1):.1%} of gaps)")
    if st.checked:
        print(f"  cross-check vs catalog: {st.checked} rows had both a name and a catalog "
              f"entry -> {st.agree} agree ({st.agree / st.checked:.1%}), "
              f"{st.disagree} differ (instructor-of-record changed after publication)")


# --------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------

def expand(patterns: Sequence[str]) -> List[str]:
    out = []
    for p in patterns:
        hits = glob.glob(p)
        if os.path.isdir(p):
            hits = sorted(glob.glob(os.path.join(p, "*.csv")) +
                          glob.glob(os.path.join(p, "*.xlsx")))
        out.extend(hits or ([p] if os.path.exists(p) else []))
    return sorted(set(out))


def cmd_roster(a) -> None:
    files = expand(a.files)
    print(f"building roster from {len(files)} grade files ...")
    r = Roster().build(files)
    r.save(a.output)
    print(f"  {len(r.counts)} distinct instructors -> {a.output}")


def cmd_schedule(a) -> None:
    ev = load_grade_file(a.evidence) if a.evidence else None
    s = build_schedule(a.catalog, ev, band=a.band)
    s.save(a.output)
    print(f"{a.catalog}: format={s.fmt} term={s.term} courses={len(s.index)} "
          f"sections={sum(len(v) for v in s.index.values())} "
          f"aligned={s.aligned_blocks} orphan={s.unaligned_blocks} -> {a.output}")


def _resolve_schedule(a, gf: GradeFile) -> Optional[Schedule]:
    if not a.schedule:
        return None
    if a.schedule.lower().endswith(".json"):
        return Schedule.load(a.schedule)
    return build_schedule(a.schedule, gf if not a.no_evidence else None, band=a.band)


def cmd_repair(a) -> None:
    gf = load_grade_file(a.grades, term=a.term)
    sched = _resolve_schedule(a, gf)
    roster = Roster.load(a.roster) if a.roster else Roster().build([a.grades])
    st = repair(gf, sched, roster,
                allow_course_unanimous=not a.no_course_unanimous,
                allow_file_unanimous=not a.no_file_unanimous,
                overwrite_conflicts=a.overwrite_conflicts)
    out = a.output or (os.path.splitext(a.grades)[0] + ".repaired.csv")
    write_repaired(gf, out, gf.term)
    print_stats(os.path.basename(a.grades), gf, sched, st)
    print(f"  written              {out}")
    if a.log:
        write_log(gf, a.log, gf.term, st)
        print(f"  repair log           {a.log}")
    if a.conflicts and st.conflicts:
        with open(a.conflicts, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["course", "section", "grade_file_name", "catalog_name"])
            w.writerows(st.conflicts)
        print(f"  conflicts            {a.conflicts}")


def cmd_batch(a) -> None:
    grades = expand([a.grades])
    cats = expand([os.path.join(a.catalogs, "*.txt")]) if os.path.isdir(a.catalogs) \
        else expand([a.catalogs])
    cat_by_term = {}
    for c in cats:
        t = parse_term(os.path.basename(c))
        if t:
            cat_by_term[t] = c
    roster = Roster.load(a.roster) if a.roster else Roster().build(grades)
    os.makedirs(a.out, exist_ok=True)
    summary = []
    for g in grades:
        gf = load_grade_file(g)
        cat = cat_by_term.get(gf.term or "")
        sched = build_schedule(cat, gf, band=a.band) if cat else None
        st = repair(gf, sched, roster)
        base = os.path.splitext(os.path.basename(g))[0]
        write_repaired(gf, os.path.join(a.out, base + ".repaired.csv"), gf.term)
        write_log(gf, os.path.join(a.out, base + ".log.csv"), gf.term, st)
        print_stats(base, gf, sched, st)
        summary.append([gf.term or "", os.path.basename(g),
                        os.path.basename(cat) if cat else "", st.total, st.already, st.blank,
                        sum(st.filled.values()), st.unfilled,
                        f"{st.agree/st.checked:.3f}" if st.checked else ""])
    with open(os.path.join(a.out, "_summary.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["term", "grade_file", "catalog", "rows", "had_name", "missing",
                    "filled", "unresolved", "catalog_agreement"])
        w.writerows(summary)
    print(f"\nsummary -> {os.path.join(a.out, '_summary.csv')}")


def cmd_audit(a) -> None:
    for p in expand(a.files):
        gf = load_grade_file(p)
        blank = sum(1 for r in gf.rows if not r.instructor)
        ff = sum(1 for r in gf.rows if r.notes == "course_code_forward_filled")
        badsum = 0
        for r in gf.rows:
            if is_int(r.values.get("TOTAL", "")):
                s = sum(int(r.values.get(c) or 0) for c in GRADE_COLS
                        if is_int(r.values.get(c, "")))
                if s != int(r.values["TOTAL"]):
                    badsum += 1
        print(f"{os.path.basename(p):<50} term={str(gf.term):<12} rows={len(gf.rows):>5} "
              f"junk={len(gf.dropped):>2} missing_instructor={blank:>5} "
              f"({blank/max(len(gf.rows),1):>5.1%}) course_ffill={ff:>3} total!=sum={badsum:>5}")


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="gradefix", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", action="version", version=VERSION)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("roster", help="build canonical instructor roster")
    s.add_argument("files", nargs="+")
    s.add_argument("-o", "--output", default="roster.json")
    s.set_defaults(func=cmd_roster)

    s = sub.add_parser("schedule", help="parse a Schedule of Classes into a JSON index")
    s.add_argument("catalog")
    s.add_argument("-o", "--output", default="schedule.json")
    s.add_argument("-e", "--evidence", help="grade file for the same term (improves alignment)")
    s.add_argument("--band", type=int, default=80)
    s.set_defaults(func=cmd_schedule)

    s = sub.add_parser("repair", help="repair one grade file")
    s.add_argument("grades")
    s.add_argument("-s", "--schedule", help="catalog .txt or prebuilt .json index")
    s.add_argument("-r", "--roster")
    s.add_argument("-o", "--output")
    s.add_argument("--log")
    s.add_argument("--conflicts")
    s.add_argument("--term")
    s.add_argument("--band", type=int, default=80)
    s.add_argument("--no-evidence", action="store_true",
                   help="align the catalog by position only, ignoring the grade file")
    s.add_argument("--no-course-unanimous", action="store_true")
    s.add_argument("--no-file-unanimous", action="store_true")
    s.add_argument("--overwrite-conflicts", action="store_true",
                   help="prefer the catalog when it disagrees with an existing name")
    s.set_defaults(func=cmd_repair)

    s = sub.add_parser("batch", help="repair a directory of grade files")
    s.add_argument("--grades", required=True)
    s.add_argument("--catalogs", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("-r", "--roster")
    s.add_argument("--band", type=int, default=80)
    s.set_defaults(func=cmd_batch)

    s = sub.add_parser("audit", help="report damage in grade files")
    s.add_argument("files", nargs="+")
    s.set_defaults(func=cmd_audit)

    a = p.parse_args(argv)
    a.func(a)


if __name__ == "__main__":
    main()
