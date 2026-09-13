"""
Tests for how ci.py pages through PostgREST.

The hosted project caps every response at 500 rows. ci.py used to ask for 1000
and stop at the first page shorter than that, so it read one page in
production: 500 of 8,698 section links. The drift check then reported 2,870
instructors out of step on a run where the true figure was zero, and the
linkability check looked at 500 of 8,335 sections.

    python3 -m pytest tests/test_ci.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ci  # noqa: E402

# Below PAGE_SIZE on purpose: the server can always return fewer rows than
# were asked for, and paging must survive that whatever PAGE_SIZE is set to.
SERVER_MAX_ROWS = 300


class _Response:
    def __init__(self, data=None, count=None):
        self.data = data
        self.count = count


class _Query:
    """A PostgREST query over a fixed list, truncated like a real server."""

    def __init__(self, rows):
        self.rows = rows
        self.start, self.end = 0, len(rows) - 1
        self.counting = False

    def select(self, *columns, count=None):
        self.counting = count == "exact"
        return self

    def order(self, *args, **kwargs):
        return self

    def is_(self, *args, **kwargs):
        return self

    def limit(self, n):
        self.end = self.start + n - 1
        return self

    def range(self, start, end):
        self.start, self.end = start, end
        return self

    def execute(self):
        window = self.rows[self.start : self.end + 1][:SERVER_MAX_ROWS]
        return _Response(data=window, count=len(self.rows) if self.counting else None)


class FakeClient:
    def __init__(self, tables):
        self.tables = tables

    def table(self, name):
        return _Query(self.tables.get(name, []))


def section_links(instructors: int, sections_each: int) -> list[dict]:
    return [
        {"instructor_id": i, "course_code": f"CMSC{i:03d}", "sec_code": f"{s:04d}"}
        for i in range(instructors)
        for s in range(sections_each)
    ]


def test_fetch_all_reads_past_a_short_page():
    rows = [{"id": i} for i in range(2 * ci.PAGE_SIZE + 7)]
    client = FakeClient({"t": rows})
    assert ci.fetch_all(lambda: client.table("t").select("id").order("id")) == rows


def test_fetch_all_of_an_empty_table():
    client = FakeClient({})
    assert ci.fetch_all(lambda: client.table("t").select("id")) == []


def test_distinct_linked_instructors_counts_every_page():
    client = FakeClient({"section_instructors": section_links(instructors=1200, sections_each=3)})
    assert ci._distinct_linked_instructors(client) == 1200


def test_healthy_run_reports_no_drift():
    links = section_links(instructors=1200, sections_each=3)
    active = [{"id": i} for i in range(1200)]
    client = FakeClient({"section_instructors": links, "active_instructors": active})

    failures: list[str] = []
    ci._check_active_flag_matches_section_links(client, failures)
    assert failures == []


def test_unqueued_unlinked_name_past_the_first_page_still_fails():
    sections = [
        {"course_code": "CMSC131", "sec_code": f"{i:04d}", "instructors": ["Ada Lovelace"], "instructor_slugs": ["ada-lovelace"]}
        for i in range(ci.PAGE_SIZE + SERVER_MAX_ROWS)
    ]
    sections.append({"course_code": "MATH140", "sec_code": "0101", "instructors": ["Grace Hopper"], "instructor_slugs": [None]})
    client = FakeClient({"sections_with_instructors": sections})

    failures: list[str] = []
    ci._check_every_professor_is_linkable(client, failures)
    assert len(failures) == 1 and "Grace Hopper" in failures[0]


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-q"]))
