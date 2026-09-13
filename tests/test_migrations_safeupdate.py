"""
Every DELETE and UPDATE inside a SQL function must have a WHERE clause.

Supabase loads `pg_safeupdate` into every session PostgREST opens. It rejects a
DELETE or UPDATE with no WHERE clause - 21000, "DELETE requires a WHERE clause"
- and it checks statements inside functions too. psql and `supabase db push`
connect as postgres without the extension, so a function that clears a table
with `delete from t;` applies cleanly, works from psql, and fails only when the
scraper calls it over the API. That is how `swap_section_instructors()` broke
the scheduled sections run. `where true` satisfies the extension and deletes
the same rows.

Only function bodies are checked; a migration's own top-level statements run
through `db push`, never through PostgREST. A function redefined by a later
migration is judged by its latest definition, since that is what production
runs.

This reads the SQL text rather than parsing it. It understands comments, string
literals and parenthesized subqueries, which covers what the migrations
contain; a DELETE or UPDATE inside a CTE is beyond it.

    python3 -m pytest tests/                        # or
    python3 tests/test_migrations_safeupdate.py     # no pytest needed
"""

from __future__ import annotations

import re
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parent.parent / "supabase" / "migrations"

FUNCTION_HEAD = r"create\s+(?:or\s+replace\s+)?function\s+([\w.]+)"

# `create function name(...) ... as $tag$ body $tag$`. The body runs to the next
# occurrence of its own dollar-quote tag, and the gap before it may not cross
# into another `create`, so one function can never borrow the next one's body.
FUNCTION = re.compile(
    FUNCTION_HEAD + r"\s*\((?:(?!\bcreate\s).)*?\bas\s+(\$\w*\$)(.*?)\2",
    re.IGNORECASE | re.DOTALL,
)

# The head of a DELETE or UPDATE statement. `on conflict ... do update set` is
# part of an INSERT, which the extension does not check, and `for update` is a
# row lock; neither matches.
DML = re.compile(
    r"\bdelete\s+from\b"
    r"|(?<!\bdo\s)\bupdate\s+(?:only\s+)?[\w.]+(?:\s+(?:as\s+)?\w+)?\s+set\b",
    re.IGNORECASE,
)

# Comments and string literals, lexed in one pass so that whichever starts first
# wins: a `--` inside a string belongs to the string, and an apostrophe inside a
# comment belongs to the comment. Stripping comments and then strings gets the
# first case wrong, and the migrations have it - `comment on function ... is
# 'NOT refreshed -- call refresh_grade_matviews()'` - which silently hid two
# function bodies from this check.
TOKEN = re.compile(r"--[^\n]*|/\*.*?\*/|'(?:[^']|'')*'", re.DOTALL)


def _strip_comments_and_strings(sql: str) -> str:
    return TOKEN.sub(lambda m: "''" if m.group(0).startswith("'") else " ", sql)


def _name(raw: str) -> str:
    return raw.lower().removeprefix("public.")


def _migrations() -> list[str]:
    return [_strip_comments_and_strings(p.read_text()) for p in sorted(MIGRATIONS.glob("*.sql"))]


def latest_function_bodies() -> dict[str, str]:
    """Each function's body as of the newest migration that defines it."""
    bodies: dict[str, str] = {}
    for sql in _migrations():
        for match in FUNCTION.finditer(sql):
            bodies[_name(match.group(1))] = match.group(3)
    return bodies


def declared_function_names() -> set[str]:
    return {_name(raw) for sql in _migrations() for raw in re.findall(FUNCTION_HEAD, sql, re.IGNORECASE)}


def unfiltered_statements(body: str) -> list[str]:
    """The DELETE and UPDATE statements in `body` that have no WHERE clause."""
    found = []
    for statement in _strip_comments_and_strings(body).split(";"):
        head = DML.search(statement)
        if head is None:
            continue
        # A WHERE inside a subquery filters the subquery, not the statement, so
        # drop every parenthesized group before looking for one.
        tail = statement[head.start():]
        while True:
            flattened = re.sub(r"\([^()]*\)", "", tail)
            if flattened == tail:
                break
            tail = flattened
        if not re.search(r"\bwhere\b", tail, re.IGNORECASE):
            found.append(" ".join(statement[head.start():].split()))
    return found


def test_lint_rejects_what_safeupdate_rejects():
    # Without these, a pattern that stopped matching anything would let the
    # migration check below pass on every body.
    rejected = [
        "delete from section_instructors",
        "update instructors set is_active = false",
        "if staged > 0 then delete from section_instructors",
        "update instructors i set n = (select max(n) from instructors d where d.id = 1)",
    ]
    accepted = [
        "delete from section_instructors where true",
        "update instructors i set n = c.n from computed c where c.id = i.id",
        "insert into t (k) values (1) on conflict (k) do update set k = excluded.k",
        "select id from instructors for update",
        "raise exception 'delete from section_instructors'",
        "delete from t where note = 'a -- b'",
    ]
    for sql in rejected:
        assert unfiltered_statements(sql), f"not flagged: {sql}"
    for sql in accepted:
        assert not unfiltered_statements(sql), f"wrongly flagged: {sql}"


def test_function_bodies_filter_every_delete_and_update():
    bodies = latest_function_bodies()
    assert "swap_section_instructors" in bodies, "no function bodies were found"

    # A function whose body was not found is a function this test skips.
    unread = declared_function_names() - bodies.keys()
    assert not unread, f"could not find the body of, so did not check: {sorted(unread)}"

    offenders = [
        f"{name}(): {statement}"
        for name, body in sorted(bodies.items())
        for statement in unfiltered_statements(body)
    ]
    assert not offenders, (
        "DELETE/UPDATE with no WHERE clause in a function body. PostgREST "
        "sessions load pg_safeupdate, which rejects these with 21000; write "
        "`where true` if every row is meant.\n  " + "\n  ".join(offenders)
    )


if __name__ == "__main__":
    test_lint_rejects_what_safeupdate_rejects()
    test_function_bodies_filter_every_delete_and_update()
    print("Every DELETE and UPDATE in a function body has a WHERE clause.")
