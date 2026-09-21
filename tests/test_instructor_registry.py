"""
Tests for how reconcile_instructors() talks to the database.

The resolution itself is SQL and is not exercised here. What is: that names go
to `link_instructors_bulk` in batches rather than one request each, and that a
batch the gateway fails is retried while one the database fails is not. A single
gateway 504 on one of ~3,000 per-name requests is what ended the 2026-09-13
sections run, after `sections` had already been replaced.

    python3 -m pytest tests/test_instructor_registry.py    # or
    python3 tests/test_instructor_registry.py
"""

from __future__ import annotations

import sys
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import httpx  # noqa: E402
from postgrest.exceptions import APIError  # noqa: E402

import instructor_registry as registry  # noqa: E402
from names import normalize_name  # noqa: E402

TERM = 202608
NAMES = ["Shane Walsh", "Jonathan Lazar", "Ada Lovelace", "Grace Hopper", "Alan Turing"]
SECTIONS = [
    {"course_code": "CMSC132", "sec_code": f"010{i}", "instructors": [name]}
    for i, name in enumerate(NAMES, start=1)
]


def gateway_timeout() -> APIError:
    # What the failed run raised: the gateway sent no PostgREST body, so the
    # client put the HTTP status in `code`.
    return APIError(
        {
            "message": "JSON could not be generated",
            "code": 504,
            "hint": "Refer to full message for details",
            "details": "b'{\"message\":\"Gateway Timeout\"}'",
        }
    )


def statement_timeout() -> APIError:
    return APIError(
        {
            "message": "canceling statement due to statement timeout",
            "code": "57014",
            "hint": None,
            "details": None,
        }
    )


class _Response:
    def __init__(self, data=None, count=None):
        self.data = data
        self.count = count


class _Query:
    """A table query. Every builder method chains; nothing is stored."""

    def __getattr__(self, name):
        return lambda *args, **kwargs: self

    def execute(self):
        return _Response(data=[], count=0)


class _Rpc:
    def __init__(self, client, name, params):
        self.client, self.name, self.params = client, name, params

    def execute(self):
        return self.client.answer(self.name, self.params)


class FakeClient:
    """Just enough of `supabase.Client` for reconcile_instructors()."""

    def __init__(self, failures=(), queued=()):
        self.failures = list(failures)  # raised by successive link_instructors_bulk calls
        self.queued = set(queued)  # normalized names the fake resolver queues
        self.link_calls: list[dict] = []
        self.next_id = 1000

    def table(self, name):
        return _Query()

    def rpc(self, name, params):
        return _Rpc(self, name, params)

    def answer(self, name, params):
        if name != "link_instructors_bulk":
            return _Response()
        self.link_calls.append(params)
        if self.failures:
            raise self.failures.pop(0)
        results = []
        for item in params["batch"]:
            if item["name_norm"] in self.queued:
                results.append({"name_norm": item["name_norm"], "instructor_id": None})
            else:
                self.next_id += 1
                results.append({"name_norm": item["name_norm"], "instructor_id": self.next_id})
        return _Response(results)


@contextmanager
def small_batches_no_delay():
    saved = registry.LINK_BATCH, registry.LINK_RETRY_DELAY_SEC
    registry.LINK_BATCH, registry.LINK_RETRY_DELAY_SEC = 2, 0
    try:
        yield
    finally:
        registry.LINK_BATCH, registry.LINK_RETRY_DELAY_SEC = saved


def reconcile(client):
    with small_batches_no_delay():
        return registry.reconcile_instructors(SECTIONS, TERM, print_output=False, client=client)


def raises(error_type, fn) -> BaseException:
    try:
        fn()
    except error_type as error:
        return error
    raise AssertionError(f"expected {error_type.__name__}")


def test_links_every_name_in_batches():
    client = FakeClient()
    report = reconcile(client)

    assert [len(call["batch"]) for call in client.link_calls] == [2, 2, 1]
    for call in client.link_calls:
        assert call["p_source"] == registry.SOURCE_TESTUDO
        assert call["p_create_if_missing"] is True
        for item in call["batch"]:
            assert item["seen_term"] == TERM
            assert item["context"] == {"term": TERM}

    sent = [item["name_norm"] for call in client.link_calls for item in call["batch"]]
    assert sorted(sent) == sorted(normalize_name(n) for n in NAMES)
    assert (report.resolved, report.queued, report.section_links) == (5, 0, 5)


def test_counts_queued_names_and_leaves_them_unlinked():
    client = FakeClient(queued={normalize_name("Ada Lovelace")})
    report = reconcile(client)

    assert (report.resolved, report.queued, report.section_links) == (4, 1, 4)


def test_retries_a_gateway_timeout():
    client = FakeClient(failures=[gateway_timeout()])
    report = reconcile(client)

    # Three batches, the first sent twice.
    assert len(client.link_calls) == 4
    assert client.link_calls[0] == client.link_calls[1]
    assert (report.resolved, report.queued) == (5, 0)


def test_retries_a_dropped_connection():
    client = FakeClient(failures=[httpx.ReadTimeout("timed out")])
    report = reconcile(client)

    assert len(client.link_calls) == 4
    assert report.resolved == 5


def test_raises_a_database_error_without_retrying():
    client = FakeClient(failures=[statement_timeout()])
    error = raises(APIError, lambda: reconcile(client))

    assert error.code == "57014"
    assert len(client.link_calls) == 1


def test_gives_up_after_the_last_attempt():
    client = FakeClient(failures=[gateway_timeout() for _ in range(registry.LINK_ATTEMPTS)])
    raises(APIError, lambda: reconcile(client))

    assert len(client.link_calls) == registry.LINK_ATTEMPTS


if __name__ == "__main__":
    tests = [
        test_links_every_name_in_batches,
        test_counts_queued_names_and_leaves_them_unlinked,
        test_retries_a_gateway_timeout,
        test_retries_a_dropped_connection,
        test_raises_a_database_error_without_retrying,
        test_gives_up_after_the_last_attempt,
    ]
    for test in tests:
        test()
    print(f"All {len(tests)} instructor_registry tests pass.")
