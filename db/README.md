# Jupiterp database migrations

Every schema change to the Jupiterp Supabase project lives here as a numbered
SQL file. Before this directory existed the schema was applied by hand-running
`grades/schema.sql` in the SQL editor, which works for one idempotent file and
stops working the moment a change has to add a column, backfill it, and then
rewrite the views that read it — in that order, once, in production.

## Applying

Migrations need DDL, which PostgREST does not do, so `supabase-py` cannot apply
them. Use a direct Postgres connection:

```sh
export DATABASE_DIRECT_URL='postgresql://postgres:...@db.<ref>.supabase.co:5432/postgres'
./db/migrate.sh            # apply everything not yet applied
./db/migrate.sh --dry-run  # list what would be applied, touch nothing
./db/migrate.sh --to 0003  # stop after 0003
```

`DATABASE_DIRECT_URL` is the *session* connection string from the Supabase
dashboard (Settings → Database), not `DATABASE_URL`, which points at the
PostgREST endpoint the scraper uses.

Rather than exporting it every time, put it in `db/.env`, which
`clone_via_api.py`, `clone_project.sh`, and `migrate.sh` all read. See
`.env.example`. Anything already exported wins over the file, so a one-off
override against a different project still works:

```sh
DATABASE_DIRECT_URL=postgresql://... ./db/migrate.sh --dry-run
```

Note the variable is `DATABASE_DIRECT_URL`, not `DIRECT_DATABASE_URL`. The
scripts do not accept the second spelling, and the failure looks like the
variable was never set at all.

### If the connection times out or reports "network is unreachable"

`db.<ref>.supabase.co` publishes **only an AAAA record**. Supabase moved
direct connections to IPv6 and made IPv4 a paid add-on, so on an IPv4-only
network — which most home and campus networks still are — the direct string
cannot be reached at all, no matter how correct the password is.

Use the **Session pooler** string from the same dashboard page instead. It is
IPv4 and looks different: a `postgres.<ref>` username and a pooler hostname.

```sh
DATABASE_DIRECT_URL='postgresql://postgres.<ref>:...@aws-0-<region>.pooler.supabase.com:5432/postgres'
```

**Port 5432, not 6543.** The pooler serves session mode on 5432 and
transaction mode on 6543; transaction mode does not keep a session across
statements, which is what `migrate.sh` needs to run a file inside one
transaction. Pointing it at 6543 fails partway through a migration rather
than refusing up front.

The runner records each applied file in `schema_migrations` and refuses to
re-apply one whose checksum has changed since. Editing a migration that has
already run in production is therefore an error, not a silent no-op: write a
new migration instead.

Each file runs inside a single transaction, so a failure rolls back cleanly and
leaves `schema_migrations` untouched.

## Rules

1. **Migrations are append-only once applied to production.** The checksum
   guard exists to enforce this. Fixing a mistake means a new file.
2. **Migrations are idempotent where it is free** (`if not exists`,
   `create or replace`) but the runner is what actually guarantees
   apply-once, so do not rely on idempotency for correctness.
3. **Backfills that touch many rows do not go in migrations.** A migration
   holds a transaction open; a backfill over 210k grade rows wants to be
   resumable and interruptible. Those live in `scripts/` and are run
   separately, with the migration adding the (nullable) column and the script
   filling it. See `0004` and `scripts/backfill_instructor_ids.py`.
4. **Numbering is sequential, not timestamped.** There is one person applying
   these; sequential numbers sort correctly everywhere and read better in a
   review than `20260814093122`.

## Baseline

The tables this project started with — `courses`, `sections`, `departments`,
`instructors` — and the `active_instructors` view were created through the
Supabase dashboard and **their definitions exist only in the database.** That
is a real gap: nothing in version control records what `active_instructors`
currently selects.

`baseline/capture.sql` dumps the live definitions. Run it once and commit the
output to `baseline/current_schema.sql` *before applying `0003`*, which
redefines `active_instructors` — otherwise there is no record of what it
replaced.

```sh
psql "$DATABASE_DIRECT_URL" -Atf db/baseline/capture.sql > db/baseline/current_schema.sql
```

## Rehearsing against a test project

Copy the `public` schema and its data from one Supabase project into another,
so the whole migration can be run somewhere a mistake costs nothing. Two ways,
depending on whether you have the database passwords.

### Without a database password (`clone_via_api.py`)

Authenticates with personal access tokens over the Supabase Management API, so
there is no password to find and no connection to port 5432. Tokens are
per-account, which makes cloning between two different accounts just two
tokens.

Generate one on each account at
<https://supabase.com/dashboard/account/tokens>.

```sh
export SOURCE_PAT=sbp_...   SOURCE_REF=<prod-ref>
export TARGET_PAT=sbp_...   TARGET_REF=<test-ref>

python3 db/clone_via_api.py --dry-run              # inspect both, write nothing
python3 db/clone_via_api.py --confirm <test-ref>   # the only form that writes
```

The project ref is the subdomain of your project URL —
`https://<ref>.supabase.co`.

Copies enum types, tables (including identity and generated columns), primary
keys, unique and check constraints, foreign keys, indexes, views, materialized
views, functions, RLS policies, grants, and all rows. It does *not* copy
triggers, non-standard extensions, composite or domain types, or partitioned
tables — but it detects them and says so rather than skipping silently.

Slower than the `pg_dump` route, since every batch of rows is a round trip.

### With a database password (`clone_project.sh`)

Faster and more complete, using `pg_dump` and `pg_restore` directly. Needs the
database password for both projects and a route to port 5432.

```sh
brew install libpq
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

export SOURCE_DB_URL='postgresql://postgres:...@db.<prod>.supabase.co:5432/postgres'
export TARGET_DB_URL='postgresql://postgres:...@db.<test>.supabase.co:5432/postgres'

./db/clone_project.sh --dry-run              # inspect both, write nothing
./db/clone_project.sh --confirm <test-ref>   # the only form that writes
```

### Both

The target's `public` schema is dropped and recreated, so the confirmation
argument has to be typed by hand: a copy-pasted connection string or project
ref pointing at the wrong project is the one mistake here that cannot be
undone. Both refuse to run when source and target are the same project, and
both end by comparing row counts, which is what actually decides whether the
copy worked.

Worth doing before touching production, because it answers the question nobody
can estimate in advance. Clone, apply the migrations, then run
`scripts/backfill_instructor_ids.py --dry-run` against the copy: the match rate
it prints is what decides how much manual triage the real migration costs.

The clone also captures `active_instructors`, whose definition currently exists
only inside the production database.

## Order of operations for the PlanetTerp migration

The migrations here are only half of each phase; the scripts that fill the new
columns are the other half. Running them out of order produces a schema that
looks correct and is empty.

| Step | What | Where |
| :-- | :-- | :-- |
| 1 | Capture the baseline | `baseline/capture.sql` |
| 2 | `0001`–`0002` | extensions, `normalize_name`, instructor identity |
| 3 | **PlanetTerp snapshot** — unrepeatable, do it early | `scripts/snapshot_planetterp.py` |
| 4 | `0003` | `section_instructors`, `active_instructors` rework |
| 5 | **Instructor backfill** from registrar + Testudo names | `scripts/backfill_instructors.py` |
| 6 | Triage `instructor_match_queue` | admin UI |
| 7 | `0004`–`0005` | `grades.instructor_id`, matviews |
| 8 | **Grade instructor backfill**, then refresh matviews | `scripts/backfill_instructor_ids.py` |
| 9 | `0006` | row-level security |

Step 3 is the one that cannot be redone. PlanetTerp is no longer being updated
and if it goes offline before the snapshot runs, the baseline ratings are gone
permanently.
