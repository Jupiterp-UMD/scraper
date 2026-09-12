# Jupiterp database migrations

Schema changes to the Jupiterp Supabase project live in `supabase/migrations/`
and are applied with the [Supabase CLI](https://supabase.com/docs/guides/cli).
This directory holds everything around them: the baseline capture, the
name-parity check, and the scripts that clone production into a test project.

There is one migration, `20260912200959_grades_instructors_reviews.sql`. It is
everything the grade/PlanetTerp work adds on top of the schema production
already had, and it replaces `grades/schema.sql` and the numbered
`db/migrations/0001`–`0036` that `db/migrate.sh` applied during the rehearsal.
Those files are in git history (last present at `b66e3ca`), along with the
reasoning behind most of what the migration does.

It is a **delta, not a full schema**. `courses`, `sections`, `departments`,
`instructors` and `user_data` were created in the Supabase dashboard and appear
in no migration, so the migration alters them rather than creating them. That
means `supabase start` and `supabase db reset` cannot build a local database
from this repository yet. Getting there needs the production baseline (below)
committed as an earlier migration and marked as applied on production with
`supabase migration repair`.

## Applying

Run from the repository root. Pushing needs a Postgres connection string, not
Docker:

```sh
npx supabase db push --db-url "$DATABASE_DIRECT_URL" --dry-run   # list what would be applied
npx supabase db push --db-url "$DATABASE_DIRECT_URL"             # apply it
npx supabase migration list --db-url "$DATABASE_DIRECT_URL"      # local vs. applied
```

`npx supabase link --project-ref <ref>` and then `--linked` in place of
`--db-url` works too, and prompts for the database password.

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

The dashboard-made tables and the original `active_instructors` materialized
view are defined **only in the production database**. The migration drops
`active_instructors`, so capture production's schema before pushing to it —
otherwise there is no record of what was replaced.

```sh
psql "$PROD_DIRECT_URL" -Atf db/baseline/capture.sql > db/baseline/prod_schema.sql
```

`baseline/current_schema.sql` is an earlier, partial capture recovered from the
rehearsal clone.

## Moving the rehearsal clone onto the CLI

The clone had `0001`–`0036` applied by `migrate.sh`, which is the schema this
migration produces, recorded in the old `public.schema_migrations` ledger. Mark
the migration as applied there instead of running it again, then drop the old
ledger:

```sh
npx supabase migration repair 20260912200959 --status applied --db-url "$DATABASE_DIRECT_URL"
psql "$DATABASE_DIRECT_URL" -c "drop table public.schema_migrations;"
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

A fresh clone of production is pre-migration, so the migration pushes onto it
exactly as it will onto production. Worth doing before touching production,
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
| 2 | Push the migration, then reload PostgREST's schema cache | `supabase db push` |
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
