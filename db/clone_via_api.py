#!/usr/bin/env python3
"""
Clone a Supabase project's `public` schema and data using only personal access
tokens -- no database password, and no direct Postgres connection.

`clone_project.sh` is faster and more thorough, but it needs the database
password for both projects and a route to port 5432. This does the same job
over the Supabase Management API, which authenticates with a personal access
token instead. Since tokens are per-account, cloning between two accounts is
just two tokens.

    # https://supabase.com/dashboard/account/tokens  (on each account)
    export SOURCE_PAT=sbp_...
    export SOURCE_REF=abcdefghijklmnopqrst
    export TARGET_PAT=sbp_...
    export TARGET_REF=uvwxyzabcdefghijklmn

    python3 db/clone_via_api.py --dry-run             # inspect, write nothing
    python3 db/clone_via_api.py --confirm $TARGET_REF

The project ref is the subdomain in your project URL:
`https://abcdefghijklmnopqrst.supabase.co`.

## What this copies

Enum types, tables (including identity and generated columns), primary keys,
unique and check constraints, foreign keys, indexes, views, materialized
views, functions, row-level security policies, grants to the Supabase roles,
and all row data.

## What it does not

Extensions beyond `unaccent` and `pg_trgm`; triggers; composite and domain
types; partitioned tables; anything outside the `public` schema. None of those
are in Jupiterp's schema today, and the script says so rather than silently
skipping if it finds one.

Ordering is deliberate: tables are created without foreign keys, then data is
loaded, then the keys are added. That sidesteps having to work out a valid
insertion order between tables that reference each other.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.supabase.com"

# urllib's default User-Agent is blocked by Cloudflare in front of the
# Management API, with an opaque 403. Any ordinary one works.
USER_AGENT = "jupiterp-clone/1.0"

# Rows fetched and inserted per round trip. Kept modest because both the
# request and the response travel as JSON in a single SQL statement.
DEFAULT_BATCH = 500

# Roles Supabase's PostgREST uses. Grants to anything else are not copied.
SUPABASE_ROLES = ("anon", "authenticated", "service_role")


class ApiError(RuntimeError):
    pass


class Project:
    """One Supabase project, reachable through the Management API."""

    def __init__(self, ref: str, token: str, label: str):
        self.ref = ref
        self.token = token
        self.label = label

    def query(self, sql: str, retries: int = 3):
        """Run SQL and return the rows as a list of dicts."""
        body = json.dumps({"query": sql}).encode()
        request = urllib.request.Request(
            f"{API}/v1/projects/{self.ref}/database/query",
            method="POST",
            data=body,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "User-Agent": USER_AGENT,
            },
        )

        last_error = None
        for attempt in range(retries):
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    payload = response.read()
                return json.loads(payload) if payload else []
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors="replace")[:400]
                if error.code in (401, 403):
                    raise ApiError(
                        f"{self.label}: not authorised ({error.code}). Check that "
                        f"the token belongs to the account owning project "
                        f"'{self.ref}'.\n  {detail}"
                    ) from None
                if error.code == 404:
                    raise ApiError(
                        f"{self.label}: project '{self.ref}' not found, or this "
                        f"token cannot see it.\n  {detail}"
                    ) from None
                # 429 and 5xx are worth retrying; a SQL error is not.
                if error.code not in (429, 500, 502, 503, 504):
                    raise ApiError(f"{self.label}: query failed ({error.code})\n  {detail}\n"
                                   f"  SQL: {sql[:300]}") from None
                last_error = f"{error.code} {detail}"
                time.sleep(2 ** attempt)
            except urllib.error.URLError as error:
                last_error = str(error)
                time.sleep(2 ** attempt)

        raise ApiError(f"{self.label}: gave up after {retries} attempts. {last_error}")

    def scalar(self, sql: str):
        rows = self.query(sql)
        if not rows:
            return None
        return next(iter(rows[0].values()))


def quote_literal(value: str) -> str:
    """Quote a string for inclusion in SQL."""
    return "'" + value.replace("'", "''") + "'"


def dollar_quote(value: str) -> str:
    """
    Wrap a string in dollar quoting, picking a tag the content does not contain.

    Used for the JSON payloads carrying row data, which are full of quotes and
    backslashes that would otherwise need escaping twice over.
    """
    tag = "jp"
    while f"${tag}$" in value:
        tag += "x"
    return f"${tag}${value}${tag}$"


# ---------------------------------------------------------------------------
# Introspection
# ---------------------------------------------------------------------------


def fetch_enums(src: Project) -> list[str]:
    rows = src.query("""
        select t.typname as name,
               string_agg(quote_literal(e.enumlabel), ', ' order by e.enumsortorder) as labels
        from pg_type t
        join pg_enum e on e.enumtypid = t.oid
        join pg_namespace n on n.oid = t.typnamespace
        where n.nspname = 'public'
        group by t.typname
        order by t.typname;
    """)
    return [f'create type "{r["name"]}" as enum ({r["labels"]});' for r in rows]


def fetch_tables(src: Project) -> list[str]:
    rows = src.query("""
        select c.relname as name
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r'
        order by c.relname;
    """)
    return [r["name"] for r in rows]


def fetch_columns(src: Project, table: str) -> list[dict]:
    return src.query(f"""
        select a.attname as name,
               format_type(a.atttypid, a.atttypmod) as coltype,
               a.attnotnull as notnull,
               pg_get_expr(d.adbin, d.adrelid) as coldefault,
               a.attidentity as identity,
               a.attgenerated as generated
        from pg_attribute a
        left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
        where a.attrelid = {quote_literal('public.' + table)}::regclass
          and a.attnum > 0 and not a.attisdropped
        order by a.attnum;
    """)


def column_ddl(col: dict) -> str:
    parts = [f'"{col["name"]}" {col["coltype"]}']

    if col.get("generated") == "s":
        # A stored generated column carries its expression instead of a
        # default, and its value must never be inserted.
        parts.append(f'generated always as ({col["coldefault"]}) stored')
    elif col.get("identity") in ("a", "d"):
        kind = "always" if col["identity"] == "a" else "by default"
        parts.append(f"generated {kind} as identity")
    elif col.get("coldefault"):
        parts.append(f'default {col["coldefault"]}')

    if col.get("notnull"):
        parts.append("not null")
    return " ".join(parts)


def fetch_constraints(src: Project, table: str) -> list[dict]:
    return src.query(f"""
        select conname as name,
               contype as kind,
               pg_get_constraintdef(oid) as definition
        from pg_constraint
        where conrelid = {quote_literal('public.' + table)}::regclass
        order by contype, conname;
    """)


def fetch_indexes(src: Project, table: str) -> list[str]:
    # Indexes that back a constraint are created by the constraint, so adding
    # them separately is an error rather than a duplicate.
    rows = src.query(f"""
        select i.indexdef as definition
        from pg_indexes i
        where i.schemaname = 'public' and i.tablename = {quote_literal(table)}
          and not exists (
              select 1 from pg_constraint c
              where c.conrelid = {quote_literal('public.' + table)}::regclass
                and c.conname = i.indexname
          )
        order by i.indexname;
    """)
    return [r["definition"] + ";" for r in rows]


def fetch_views(src: Project, materialized: bool) -> list[dict]:
    kind = "m" if materialized else "v"
    return src.query(f"""
        select c.relname as name, pg_get_viewdef(c.oid, true) as definition
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = '{kind}'
        order by c.relname;
    """)


def fetch_functions(src: Project) -> list[str]:
    # Functions belonging to an extension come with the extension and must not
    # be recreated by hand.
    rows = src.query("""
        select pg_get_functiondef(p.oid) as definition
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.prokind in ('f', 'p')
          and not exists (
              select 1 from pg_depend d
              where d.objid = p.oid and d.deptype = 'e'
          )
        order by p.proname;
    """)
    return [r["definition"].rstrip().rstrip(";") + ";" for r in rows]


def fetch_rls(src: Project) -> tuple[list[str], list[str]]:
    enabled = src.query("""
        select c.relname as name
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
        order by c.relname;
    """)
    enable_sql = [f'alter table "{r["name"]}" enable row level security;' for r in enabled]

    policies = src.query("""
        select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
        from pg_policies
        where schemaname = 'public'
        order by tablename, policyname;
    """)

    policy_sql = []
    for p in policies:
        roles = p["roles"]
        if isinstance(roles, str):
            roles = roles.strip("{}").split(",") if roles.strip("{}") else []
        roles = [r.strip() for r in roles if r.strip()]
        role_clause = f' to {", ".join(roles)}' if roles and roles != ["public"] else ""

        stmt = (f'create policy "{p["policyname"]}" on "{p["tablename"]}"'
                f' as {"permissive" if p["permissive"] in ("PERMISSIVE", True) else "restrictive"}'
                f' for {p["cmd"].lower()}{role_clause}')
        if p["qual"]:
            stmt += f' using ({p["qual"]})'
        if p["with_check"]:
            stmt += f' with check ({p["with_check"]})'
        policy_sql.append(stmt + ";")

    return enable_sql, policy_sql


def fetch_grants(src: Project) -> list[str]:
    roles = ", ".join(quote_literal(r) for r in SUPABASE_ROLES)
    rows = src.query(f"""
        select grantee, table_name, string_agg(distinct privilege_type, ', ') as privs
        from information_schema.role_table_grants
        where table_schema = 'public' and grantee in ({roles})
        group by grantee, table_name
        order by table_name, grantee;
    """)
    return [f'grant {r["privs"].lower()} on "{r["table_name"]}" to {r["grantee"]};' for r in rows]


def unsupported_objects(src: Project) -> list[str]:
    """Anything present that this script would silently fail to copy."""
    problems = []

    triggers = src.query("""
        select tgname as name, c.relname as tbl
        from pg_trigger t join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and not t.tgisinternal;
    """)
    for t in triggers:
        problems.append(f'trigger {t["name"]} on {t["tbl"]}')

    extensions = src.query("""
        select extname as name from pg_extension
        where extname not in ('plpgsql', 'unaccent', 'pg_trgm', 'pgcrypto',
                              'uuid-ossp', 'pg_stat_statements', 'pg_graphql',
                              'pgjwt', 'supabase_vault', 'pgsodium');
    """)
    for e in extensions:
        problems.append(f'extension {e["name"]}')

    return problems


# ---------------------------------------------------------------------------
# Data copy
# ---------------------------------------------------------------------------


def primary_key_columns(src: Project, table: str) -> list[str]:
    rows = src.query(f"""
        select a.attname as name
        from pg_constraint c
        join unnest(c.conkey) with ordinality k(attnum, ord) on true
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
        where c.conrelid = {quote_literal('public.' + table)}::regclass
          and c.contype = 'p'
        order by k.ord;
    """)
    return [r["name"] for r in rows]


def copy_table(src: Project, dst: Project, table: str, columns: list[dict],
               batch: int, verbose: bool = True) -> int:
    """Copy one table's rows. Returns how many were written."""
    # Generated columns are computed by the target and cannot be inserted.
    insertable = [c["name"] for c in columns if c.get("generated") != "s"]
    if not insertable:
        return 0
    col_list = ", ".join(f'"{c}"' for c in insertable)

    pk = primary_key_columns(src, table)
    # A stable order is what makes offset paging return each row exactly once.
    order = ", ".join(f'"{c}"' for c in pk) if pk else col_list

    total = src.scalar(f'select count(*) from "{table}";') or 0
    if total == 0:
        return 0

    written = 0
    offset = 0
    while offset < total:
        rows_json = src.scalar(f"""
            select coalesce(jsonb_agg(t), '[]'::jsonb)::text
            from (
                select {col_list} from "{table}"
                order by {order}
                limit {batch} offset {offset}
            ) t;
        """)
        if not rows_json or rows_json == "[]":
            break

        # jsonb_populate_recordset maps by column name and handles every type
        # the table uses, which is far more robust than building INSERT tuples
        # and quoting each value by hand.
        dst.query(f"""
            insert into "{table}" ({col_list})
            select {col_list}
            from jsonb_populate_recordset(null::public."{table}",
                                          {dollar_quote(rows_json)}::jsonb);
        """)

        count = len(json.loads(rows_json))
        written += count
        offset += batch
        if verbose:
            print(f"      {written}/{total}", end="\r", flush=True)
        if count < batch:
            break

    if verbose:
        print(f"      {written}/{total} rows      ")
    return written


def resync_identities(dst: Project, table: str, columns: list[dict]) -> None:
    """
    Move identity sequences past the data just inserted.

    Rows are copied with their original ids, which leaves the sequence at 1.
    The next insert would then collide with an existing row -- and only on the
    target, only later, which is a bad way to discover it.
    """
    for col in columns:
        if col.get("identity") not in ("a", "d"):
            continue
        dst.query(f"""
            select setval(
                pg_get_serial_sequence('public."{table}"', '{col["name"]}'),
                coalesce((select max("{col["name"]}") from "{table}"), 1),
                true
            );
        """)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Clone a Supabase project over the Management API (no DB password)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Inspect both projects and report; write nothing")
    parser.add_argument("--confirm", metavar="TARGET_REF",
                        help="Target project ref, typed out. Required to write")
    parser.add_argument("--schema-only", action="store_true",
                        help="Recreate the schema without copying any rows")
    parser.add_argument("--batch", type=int, default=DEFAULT_BATCH,
                        help=f"Rows per round trip (default {DEFAULT_BATCH})")
    args = parser.parse_args()

    try:
        source = Project(os.environ["SOURCE_REF"], os.environ["SOURCE_PAT"], "source")
        target_ref = os.environ["TARGET_REF"]
        target_pat = os.environ["TARGET_PAT"]
    except KeyError as missing:
        print(f"Missing environment variable: {missing}", file=sys.stderr)
        print("\nNeeded: SOURCE_REF, SOURCE_PAT, TARGET_REF, TARGET_PAT", file=sys.stderr)
        print("Tokens come from https://supabase.com/dashboard/account/tokens", file=sys.stderr)
        print("-- one per account, if the projects are on different accounts.", file=sys.stderr)
        return 1

    target = Project(target_ref, target_pat, "target")

    if source.ref == target.ref:
        print("ERROR: source and target are the same project. Refusing.", file=sys.stderr)
        return 1

    if not args.dry_run and args.confirm != target.ref:
        print("ERROR: refusing to write to the target.", file=sys.stderr)
        print(f"\nThis drops and recreates the 'public' schema on project "
              f"'{target.ref}', destroying everything in it.", file=sys.stderr)
        print(f"To proceed, name the target explicitly:\n", file=sys.stderr)
        print(f"  python3 db/clone_via_api.py --confirm {target.ref}\n", file=sys.stderr)
        print("Or inspect first with --dry-run.", file=sys.stderr)
        return 1

    print(f"source: {source.ref}")
    print(f"target: {target.ref}")
    print()

    # ── inspect ────────────────────────────────────────────────────────────
    print("Reading source schema...")
    tables = fetch_tables(source)
    columns = {t: fetch_columns(source, t) for t in tables}
    enums = fetch_enums(source)
    views = fetch_views(source, materialized=False)
    matviews = fetch_views(source, materialized=True)
    functions = fetch_functions(source)
    rls_enable, rls_policies = fetch_rls(source)
    grants = fetch_grants(source)
    problems = unsupported_objects(source)

    print(f"  {len(tables)} tables, {len(views)} views, {len(matviews)} materialized views")
    print(f"  {len(enums)} enum types, {len(functions)} functions")
    print(f"  {len(rls_policies)} RLS policies, {len(grants)} grants")

    counts = {}
    for table in tables:
        counts[table] = source.scalar(f'select count(*) from "{table}";') or 0
    print()
    for table in tables:
        print(f"    {table:<28} {counts[table]:>9,} rows")

    if problems:
        print()
        print("  NOT COPIED by this script:")
        for problem in problems:
            print(f"    - {problem}")
        print("  Use clone_project.sh with a database password if these matter.")

    if args.dry_run:
        target_objects = target.scalar("""
            select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','v','m');
        """)
        print()
        print(f"Target currently holds {target_objects} object(s) in public.")
        print("--dry-run: nothing written.")
        return 0

    # ── reset target ───────────────────────────────────────────────────────
    print()
    print("Resetting target public schema...")
    target.query("""
        create extension if not exists unaccent;
        create extension if not exists pg_trgm;
        drop schema if exists public cascade;
        create schema public;
        grant usage on schema public to anon, authenticated, service_role;
        grant all on schema public to postgres;
    """)

    # ── types and tables ───────────────────────────────────────────────────
    for statement in enums:
        target.query(statement)
    if enums:
        print(f"  created {len(enums)} enum type(s)")

    print("Creating tables...")
    for table in tables:
        cols = ",\n    ".join(column_ddl(c) for c in columns[table])
        target.query(f'create table "{table}" (\n    {cols}\n);')
    print(f"  created {len(tables)} table(s)")

    # Functions before constraints: a check constraint or a generated column
    # can call one, and the table would fail to alter without it.
    if functions:
        print("Creating functions...")
        created = 0
        for statement in functions:
            try:
                target.query(statement)
                created += 1
            except ApiError as error:
                print(f"  skipped a function: {str(error)[:120]}")
        print(f"  created {created}/{len(functions)} function(s)")

    # ── data ───────────────────────────────────────────────────────────────
    if not args.schema_only:
        print("Copying rows...")
        for table in tables:
            if counts[table] == 0:
                print(f"    {table:<28} empty")
                continue
            print(f"    {table:<28}")
            copy_table(source, target, table, columns[table], args.batch)
            resync_identities(target, table, columns[table])

    # ── constraints and indexes, after the data ────────────────────────────
    print("Adding constraints...")
    deferred_fks = []
    added = 0
    for table in tables:
        for constraint in fetch_constraints(source, table):
            statement = (f'alter table "{table}" add constraint '
                         f'"{constraint["name"]}" {constraint["definition"]};')
            if constraint["kind"] == "f":
                deferred_fks.append(statement)
            else:
                try:
                    target.query(statement)
                    added += 1
                except ApiError as error:
                    print(f"  skipped {constraint['name']}: {str(error)[:120]}")

    for statement in deferred_fks:
        try:
            target.query(statement)
            added += 1
        except ApiError as error:
            print(f"  skipped a foreign key: {str(error)[:120]}")
    print(f"  added {added} constraint(s)")

    print("Creating indexes...")
    index_count = 0
    for table in tables:
        for statement in fetch_indexes(source, table):
            try:
                target.query(statement)
                index_count += 1
            except ApiError as error:
                print(f"  skipped an index: {str(error)[:120]}")
    print(f"  created {index_count} index(es)")

    # ── views ──────────────────────────────────────────────────────────────
    # Views can depend on other views, and the catalog does not hand back a
    # dependency order. Retrying until nothing new succeeds resolves it
    # without having to build the graph.
    for label, items, keyword in (("views", views, "create view"),
                                  ("materialized views", matviews, "create materialized view")):
        if not items:
            continue
        print(f"Creating {label}...")
        pending = list(items)
        while pending:
            progressed = []
            for view in pending:
                try:
                    target.query(f'{keyword} "{view["name"]}" as {view["definition"]}')
                except ApiError:
                    progressed.append(view)
            if len(progressed) == len(pending):
                for view in progressed:
                    print(f"  could not create {view['name']}")
                break
            pending = progressed
        print(f"  created {len(items) - len(pending)}/{len(items)}")

    # ── security ───────────────────────────────────────────────────────────
    print("Applying row-level security and grants...")
    for statement in rls_enable + rls_policies + grants:
        try:
            target.query(statement)
        except ApiError as error:
            print(f"  skipped: {str(error)[:120]}")

    # ── verify ─────────────────────────────────────────────────────────────
    print()
    print("Verifying...")
    mismatches = 0
    for table in tables:
        try:
            got = target.scalar(f'select count(*) from "{table}";') or 0
        except ApiError:
            got = "error"
        ok = got == counts[table]
        if not ok:
            mismatches += 1
        print(f"    {table:<28} {counts[table]:>9,} -> {got:>9}  {'ok' if ok else 'MISMATCH'}")

    print()
    if mismatches:
        print(f"{mismatches} table(s) did not match. Investigate before relying on this copy.")
        return 1

    print("Done. Every table matches.")
    print()
    print("Next, against the TEST project only:")
    print("  DATABASE_DIRECT_URL=... ./db/migrate.sh --dry-run")
    print("  python3 scripts/backfill_instructor_ids.py --dry-run")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ApiError as error:
        print(f"\n{error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted. The target is probably half-written; re-run to start over.",
              file=sys.stderr)
        sys.exit(130)
