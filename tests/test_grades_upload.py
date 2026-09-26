"""
Tests for what the grade loader sends to `grades`.

The upsert writes every column in the row, so a column present with a None
overwrites whatever the database held. The plain `ingest` path never resolves
instructor names, and it used to send `instructor_id: None` for every row --
re-ingesting any term unlinked every one of its sections from its professor.

    python3 -m pytest tests/test_grades_upload.py    # or
    python3 tests/test_grades_upload.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from grades.db import _rows_for_upload  # noqa: E402


def record(**overrides) -> dict:
    base = {
        "term": 202508,
        "course_code": "CMSC132",
        "sec_code": "0101",
        "instructor": "Walsh, Shane",
        "instructor_name": "Shane Walsh",
        "instructor_source": "reported",
        "total": 30,
        "a": 30,
    }
    base.update(overrides)
    return base


def test_unresolved_ingest_leaves_instructor_id_out_entirely():
    rows = _rows_for_upload([record()], write_instructor_ids=False)
    # Absent, not None: an absent column keeps the stored link on conflict.
    assert "instructor_id" not in rows[0]
    assert rows[0]["instructor_name"] == "Shane Walsh"


def test_resolved_ingest_writes_instructor_id_including_nulls():
    rows = _rows_for_upload(
        [record(instructor_id=42), record(sec_code="0102", instructor_name=None)],
        write_instructor_ids=True,
    )
    assert rows[0]["instructor_id"] == 42
    # A row with no name has no instructor, and saying so is correct here.
    assert "instructor_id" in rows[1] and rows[1]["instructor_id"] is None


def test_every_row_in_a_batch_has_the_same_keys():
    # PostgREST bulk upserts take their column list from the rows; mixed key
    # sets would null the missing ones.
    for write in (True, False):
        rows = _rows_for_upload(
            [record(instructor_id=1), record(sec_code="0102")], write_instructor_ids=write
        )
        assert rows[0].keys() == rows[1].keys()


def test_generated_columns_are_never_sent():
    rows = _rows_for_upload([record(gpa=3.9, graded=30)], write_instructor_ids=True)
    assert "gpa" not in rows[0] and "graded" not in rows[0]


if __name__ == "__main__":
    test_unresolved_ingest_leaves_instructor_id_out_entirely()
    test_resolved_ingest_writes_instructor_id_including_nulls()
    test_every_row_in_a_batch_has_the_same_keys()
    test_generated_columns_are_never_sent()
    print("ok")
