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


class _Not:
    """The `.not_` accessor, which only `is_` is ever chained off here."""

    def __init__(self, query):
        self.query = query

    def is_(self, column, value):
        self.query.exclude_null = column
        return self.query


class _Query:
    """A PostgREST query over a fixed list, truncated like a real server."""

    def __init__(self, rows):
        self.rows = rows
        self.start, self.end = 0, len(rows) - 1
        self.counting = False
        self.exclude_null = None

    def select(self, *columns, count=None):
        self.counting = count == "exact"
        return self

    def order(self, *args, **kwargs):
        return self

    def is_(self, *args, **kwargs):
        return self

    def eq(self, column, value):
        self.rows = [row for row in self.rows if row.get(column) == value]
        self.end = len(self.rows) - 1
        return self

    @property
    def not_(self):
        return _Not(self)

    def limit(self, n):
        self.end = self.start + n - 1
        return self

    def range(self, start, end):
        self.start, self.end = start, end
        return self

    def execute(self):
        rows = self.rows
        if self.exclude_null is not None:
            rows = [r for r in rows if r.get(self.exclude_null) is not None]
        window = rows[self.start : self.end + 1][:SERVER_MAX_ROWS]
        return _Response(data=window, count=len(rows) if self.counting else None)


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


def queue_client(testudo: int, registrar: int) -> FakeClient:
    return FakeClient(
        {
            "instructor_match_queue": [{"id": i, "source": "testudo"} for i in range(testudo)]
            + [{"id": i, "source": "registrar"} for i in range(registrar)]
        }
    )


def test_a_large_registrar_backlog_is_not_a_failure():
    """
    The state the first full backfill left: 1,167 registrar names awaiting
    triage, and a healthy scrape. One combined ceiling failed this run.
    """
    failures: list[str] = []
    ci._check_match_queue(queue_client(testudo=47, registrar=1167), {}, failures)
    assert failures == []


def test_a_testudo_spike_still_fails_under_a_large_backlog():
    """The signal a single ceiling set above the backlog would have lost."""
    failures: list[str] = []
    ci._check_match_queue(queue_client(testudo=600, registrar=1167), {}, failures)
    assert len(failures) == 1 and "testudo" in failures[0]


def test_a_runaway_registrar_backlog_fails():
    failures: list[str] = []
    ci._check_match_queue(queue_client(testudo=10, registrar=5000), {}, failures)
    assert len(failures) == 1 and "registrar" in failures[0]


def test_queue_counts_are_recorded_per_source():
    current: dict = {}
    ci._check_match_queue(queue_client(testudo=47, registrar=1167), current, [])
    assert current["instructor_match_queue_open"] == 1214
    assert current["instructor_match_queue_open_by_source"] == {
        "testudo": 47,
        "registrar": 1167,
    }


def grade_rows(total: int, linked: int) -> list[dict]:
    return [{"instructor_id": i if i < linked else None} for i in range(total)]


def grades_client(total: int, linked: int, covered: int = 0) -> FakeClient:
    return FakeClient(
        {
            "grades": grade_rows(total, linked),
            "instructor_grades": [{"instructor_id": i} for i in range(covered)],
        }
    )


def test_mostly_unlinked_grades_fail_the_floor():
    """The state this check was written for: ingested, refreshed, unlinked."""
    client = grades_client(total=2000, linked=60, covered=4)

    failures: list[str] = []
    ci._check_grades_are_linked(client, {}, {}, failures)
    assert len(failures) == 1
    assert "3.0%" in failures[0] and "backfill_instructor_ids" in failures[0]


def test_linked_grades_pass():
    client = grades_client(total=2000, linked=1900, covered=900)

    failures: list[str] = []
    ci._check_grades_are_linked(client, {}, {}, failures)
    assert failures == []


def test_linked_share_is_recorded_for_the_next_run():
    current: dict = {}
    ci._check_grades_are_linked(grades_client(2000, 1900), {}, current, [])
    assert current["grades_linked"] == 1900
    assert current["grades_linked_share"] == 0.95


def test_a_slide_below_the_previous_run_fails_even_above_the_floor():
    """A new term ingested with no backfill after it."""
    client = grades_client(total=2000, linked=1720, covered=900)

    failures: list[str] = []
    ci._check_grades_are_linked(client, {"grades_linked_share": 0.99}, {}, failures)
    assert len(failures) == 1 and "86.0%" in failures[0]


def test_a_small_dip_is_not_a_failure():
    client = grades_client(total=2000, linked=1900, covered=900)

    failures: list[str] = []
    ci._check_grades_are_linked(client, {"grades_linked_share": 0.97}, {}, failures)
    assert failures == []


def test_an_empty_grades_table_is_left_to_its_own_floor():
    failures: list[str] = []
    ci._check_grades_are_linked(FakeClient({}), {}, {}, failures)
    assert failures == []


def test_the_count_is_not_truncated_by_the_server_cap():
    """
    The counts come from `count="exact"`, not from the returned page, so a
    table far larger than SERVER_MAX_ROWS still reports its true share.
    """
    client = grades_client(total=10 * SERVER_MAX_ROWS, linked=9 * SERVER_MAX_ROWS)

    current: dict = {}
    ci._check_grades_are_linked(client, {}, current, [])
    assert current["grades_linked"] == 9 * SERVER_MAX_ROWS


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-q"]))
