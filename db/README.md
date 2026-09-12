# Jupiterp database migrations

Schema changes to the Jupiterp Supabase project live in `supabase/migrations/`
and are applied with the [Supabase CLI](https://supabase.com/docs/guides/cli).
This directory holds everything around them: the baseline capture, the
name-parity check, and the scripts that clone production into a test project.

There are two migrations:

| File | What |
| :-- | :-- |
| `20260912200000_prod_baseline.sql` | Production's schema before the grade work: the dashboard-made `courses`, `sections`, `departments`, `instructors`, `user_data`, `dept_codes`, and the old `active_instructors` matview. Dumped with `supabase db dump --linked`. |
| `20260912200959_grades_instructors_reviews.sql` | Everything the grade/PlanetTerp work adds. Replaces `grades/schema.sql` and the numbered `db/migrations/0001`–`0036` that `db/migrate.sh` applied during the rehearsal; those are in git history (last present at `b66e3ca`), with the reasoning behind most of it. |

Together they build the whole schema from an empty database. Production already
has everything in the baseline, so there it is **marked as applied, never run**.

## Applying

Run from the repository root. Pushing needs a Postgres connection string, not
Docker:

```sh
npx supabase db push --db-url "$DATABASE_DIRECT_URL" --dry-run   # list what would be applied
npx supabase db push --db-url "$DATABASE_DIRECT_URL"             # apply it
npx supabase migration list --db-url "$DATABASE_DIRECT_URL"      # local vs. applied
```

`npx supabase link --project-ref <ref>` and then `--linked` in place of
`--db-url` works too. Without a stored password the CLI connects through a
temporary login role it creates on the project, and switches to `postgres`, so
objects are still owned by `postgres`.

### First push to production, or to a clone of it

Those databases already have the baseline's tables. Record it as applied first,
or `db push` tries to create them again:

```sh
npx supabase migration repair 20260912200000 --status applied --linked   # writes only the ledger
npx supabase db push --linked --dry-run   # expect only 20260912200959_grades_instructors_reviews.sql
npx supabase db push --linked
```

`db push` runs each migration file, and the row recording it in
`supabase_migrations.schema_migrations`, in a single transaction. A failure
anywhere in the file leaves the database exactly as it was.

PostgREST caches the schema. After a push, reload it, or new functions answer
404 from a route that plainly exists:

```sh
psql "$DATABASE_DIRECT_URL" -c "notify pgrst, 'reload schema';"
```

### The connection string

`DATABASE_DIRECT_URL` is the *session* connection string from the Supabase
dashboard (Settings → Database), not `DATABASE_URL`, which points at the
PostgREST endpoint the scraper uses. The CLI requires it percent-encoded: a
password containing `#`, `$`, `&` or `@` has to be escaped in the URL.

It can live in `db/.env` (see `.env.example`). The CLI does not read that file,
so load it into the shell first:

```sh
source db/load_env.sh && load_env_file
```

Anything already exported wins over the file, so a one-off override against a
different project still works.

Note the variable is `DATABASE_DIRECT_URL`, not `DIRECT_DATABASE_URL`. Nothing
accepts the second spelling, and the failure looks like the variable was never
set at all.

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
transaction mode on 6543. A migration is one transaction spanning many
statements, and transaction mode does not keep a session across them.

## Rules

1. **Migrations are append-only once applied to production.** The CLI records
   which versions have run, not what they contained, so an edit to an applied
   file is never run and nothing says so. Fixing a mistake means a new
   migration.
2. **Create them with the CLI** — `npx supabase migration new <name>` — so the
   timestamp prefix sorts after everything already applied.
3. **Backfills that touch many rows do not go in migrations.** A migration
   holds a transaction open; a backfill over 210k grade rows wants to be
   resumable and interruptible. Those live in `scripts/` and are run
   separately, with the migration adding the (nullable) column and the script
   filling it. See `grades.instructor_id` and
   `scripts/backfill_instructor_ids.py`.

## Baseline

The dashboard-made objects are recorded in `20260912200000_prod_baseline.sql`,
dumped from production on 2026-09-12, before the grades migration touched it.

A schema dump cannot see pg_cron jobs. Production had one, "Refresh
active_instructors view", calling `refresh_active_instructors()` every night;
the grades migration unschedules it, because it drops that function.

`baseline/capture.sql` and `baseline/current_schema.sql` predate the baseline
migration and are kept for reference.

## Moving the rehearsal clone onto the CLI

The clone had `0001`–`0036` applied by `migrate.sh`, which is the schema these
migrations produce, recorded in the old `public.schema_migrations` ledger. Mark
both as applied there instead of running them, then drop the old ledger:

```sh
npx supabase migration repair 20260912200000 20260912200959 --status applied --db-url "$DATABASE_DIRECT_URL"
psql "$DATABASE_DIRECT_URL" -c "drop table public.schema_migrations;"
```

The clone is missing grants the migration now makes explicitly. Without them a
scrape against it fails at the staging swap:

```sql
grant select, insert, update, delete on section_instructors_staging to service_role;
grant execute on function set_active_instructors(bigint[], int),
                          swap_section_instructors(),
                          prune_rate_limits(interval) to service_role;
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

A fresh clone of production is pre-migration, so after the same baseline
`migration repair` the migration pushes onto it exactly as it will onto
production. Worth doing before touching production,
because it answers the question nobody can estimate in advance: clone, push the
migration, then run `scripts/backfill_instructor_ids.py --dry-run` against the
copy. The match rate it prints is what decides how much manual triage the real
migration costs.

The clone also captures `active_instructors`, whose definition currently exists
only inside the production database.

## Order of operations for the PlanetTerp migration

The migration is only half of the change; the scripts that fill the new
columns are the other half. Running them out of order produces a schema that
looks correct and is empty.

| Step | What | Where |
| :-- | :-- | :-- |
| 1 | Capture the production baseline | `baseline/capture.sql` |
| 2 | Mark the baseline applied, push the migration, reload PostgREST's schema cache | `supabase migration repair`, `supabase db push` |
| 3 | Name parity: every query returns zero rows | `tests/name_parity.sql` |
| 4 | Load grade data | `grades/main.py ingest` |
| 5 | **PlanetTerp snapshot** — cannot be redone | `scripts/snapshot_planetterp.py` |
| 6 | Testudo section scrape | `main.py --sections` |
| 7 | Grade instructor backfill, which refreshes the grade matviews | `scripts/backfill_instructor_ids.py` |
| 8 | Triage `instructor_match_queue` | admin UI |

Step 5 is the one that cannot be redone. PlanetTerp is no longer being updated
and if it goes offline before the snapshot runs, the baseline ratings are gone
permanently. Until it runs, no professor displays a rating: the migration
recomputes ratings from PlanetTerp columns that are still empty.
