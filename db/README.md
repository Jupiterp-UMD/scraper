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
