"""
Tests for how the scraper refreshes `departments`.

The table used to be emptied and then refilled. The API caches the department
list for two hours, so a single request landing between the delete and the
insert pinned an empty list in front of every visitor and course search stopped
resolving department codes. These tests hold the refresh to "never empty".

    python3 -m pytest tests/test_upload_depts.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import db  # noqa: E402


class FakeTable:
    """An in-memory `departments` table that records every state it passes through."""

    def __init__(self, rows: dict[str, str], history: list[dict[str, str]]):
        self.rows = rows
        self.history = history
        self._op = None
        self._negate = False

    def upsert(self, data, on_conflict=None):
        assert on_conflict == "dept_code"
        self._op = ("upsert", data)
        return self

    def insert(self, data):
        self._op = ("insert", data)
        return self

    def delete(self):
        self._op = ("delete", None)
        return self

    @property
    def not_(self):
        self._negate = True
        return self

    def in_(self, column, values):
        assert column == "dept_code"
        self._filter = ("in", set(values), self._negate)
        return self

    def neq(self, column, value):
        self._filter = ("neq", value, False)
        return self

    def execute(self):
        kind, data = self._op
        if kind in ("upsert", "insert"):
            for row in data:
                self.rows[row["dept_code"]] = row["name"]
        else:
            op, value, negate = self._filter
            if op == "in":
                doomed = [c for c in self.rows if (c in value) != negate]
            else:
                doomed = [c for c in self.rows if c != value]
            for code in doomed:
                del self.rows[code]
        self.history.append(dict(self.rows))


class FakeClient:
    def __init__(self, rows: dict[str, str]):
        self.rows = dict(rows)
        self.history: list[dict[str, str]] = []

    def table(self, name):
        assert name == "departments"
        return FakeTable(self.rows, self.history)


EXISTING = {"CMSC": "Computer Science", "MATH": "Mathematics", "OLDD": "Retired Department"}


def test_table_is_never_empty_during_a_refresh():
    client = FakeClient(EXISTING)
    db.replace_depts(client, [("CMSC", "Computer Science"), ("MATH", "Mathematics")])
    assert client.history, "expected at least one write"
    assert all(state for state in client.history)


def test_refresh_adds_renames_and_prunes():
    client = FakeClient(EXISTING)
    db.replace_depts(
        client,
        [("CMSC", "Computer Science"), ("MATH", "Math"), ("NEWW", "New Department")],
    )
    assert client.rows == {
        "CMSC": "Computer Science",
        "MATH": "Math",
        "NEWW": "New Department",
    }


def test_empty_scrape_leaves_the_table_alone(monkeypatch):
    client = FakeClient(EXISTING)
    monkeypatch.setattr(db, "get_supabase_client", lambda: client)
    db.upload_depts([], print_output=False)
    assert client.rows == EXISTING
    assert client.history == []


def test_upload_depts_writes_through_replace(monkeypatch):
    client = FakeClient(EXISTING)
    monkeypatch.setattr(db, "get_supabase_client", lambda: client)
    db.upload_depts([("CMSC", "Computer Science")], print_output=False)
    assert client.rows == {"CMSC": "Computer Science"}
