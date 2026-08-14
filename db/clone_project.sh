#!/usr/bin/env bash
#
# Copy the `public` schema and its data from one Supabase project into another.
#
# Built for standing up a test project that mirrors production, so the
# PlanetTerp migration can be rehearsed somewhere a mistake costs nothing.
# That rehearsal is worth more than it sounds: the instructor match rate from
# `scripts/backfill_instructor_ids.py --dry-run` is the single biggest unknown
# in the whole plan, and this is how you measure it against real data without
# touching the real database.
#
# Usage:
#   export SOURCE_DB_URL='postgresql://postgres:...@db.<src>.supabase.co:5432/postgres'
#   export TARGET_DB_URL='postgresql://postgres:...@db.<dst>.supabase.co:5432/postgres'
#
#   ./db/clone_project.sh --dry-run          # inspect both ends, write nothing
#   ./db/clone_project.sh --dump-only        # produce the dump file, stop
#   ./db/clone_project.sh --confirm <dst-ref>
#
# The last form is the only one that writes. `<dst-ref>` is the project ref in
# TARGET_DB_URL, which has to be typed out by hand: this script drops and
# recreates the target's `public` schema, and a copy-pasted connection string
# pointing at the wrong project is exactly the mistake that is unrecoverable.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMP_DIR="${DUMP_DIR:-$HERE/../.dumps}"

DRY_RUN=0
DUMP_ONLY=0
CONFIRM_REF=""
INCLUDE_GRADES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --dump-only) DUMP_ONLY=1; shift ;;
    --confirm)   CONFIRM_REF="${2:-}"; shift 2 ;;
    --schema-only) INCLUDE_GRADES=0; shift ;;
    -h|--help)   sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for tool in pg_dump psql; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool not found. brew install libpq, then:" >&2
    echo '  export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >&2
    exit 1
  }
done

: "${SOURCE_DB_URL:?SOURCE_DB_URL is not set}"
if [[ $DUMP_ONLY -eq 0 ]]; then
  : "${TARGET_DB_URL:?TARGET_DB_URL is not set}"
fi

# Pull the project ref out of a Supabase connection string, for the confirmation
# check and for naming the dump file.
project_ref() {
  local url="$1"
  if [[ "$url" =~ db\.([a-z0-9]+)\.supabase\.co ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$url" =~ postgres\.([a-z0-9]+)@ ]]; then
    # Pooler-style connection strings put the ref in the username.
    echo "${BASH_REMATCH[1]}"
  else
    echo "unknown"
  fi
}

SRC_REF="$(project_ref "$SOURCE_DB_URL")"
DST_REF="$(project_ref "${TARGET_DB_URL:-}")"

# Checked before the dump rather than after it, so a mistyped ref costs a
# second instead of however long dumping 210k grade rows takes.
if [[ $DRY_RUN -eq 0 && $DUMP_ONLY -eq 0 && "$CONFIRM_REF" != "$DST_REF" ]]; then
  echo "ERROR: refusing to write to the target." >&2
  echo >&2
  echo "This drops and recreates the 'public' schema on project '$DST_REF'," >&2
  echo "destroying everything in it. To proceed, name the target explicitly:" >&2
  echo >&2
  echo "  ./db/clone_project.sh --confirm $DST_REF" >&2
  echo >&2
  echo "Or inspect first with --dry-run, or take a dump only with --dump-only." >&2
  exit 1
fi

echo "source project: $SRC_REF"
echo "target project: ${DST_REF:-<none>}"
echo

if [[ "$SRC_REF" != "unknown" && "$SRC_REF" == "$DST_REF" ]]; then
  echo "ERROR: source and target are the same project. Refusing." >&2
  exit 1
fi

# ─── inspect ────────────────────────────────────────────────────────────────

echo "── source contents ──"
psql "$SOURCE_DB_URL" -X -q -A -F $'\t' -c "
select relkind, relname,
       case when relkind = 'r'
            then (select reltuples::bigint from pg_class c2 where c2.oid = c.oid)::text
            else '' end as approx_rows
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and relkind in ('r','v','m')
order by relkind, relname;
" | while IFS=$'\t' read -r kind name rows; do
  case "$kind" in
    r) label="table" ;;
    v) label="view" ;;
    m) label="matview" ;;
    *) label="$kind" ;;
  esac
  printf "  %-10s %-32s %s\n" "$label" "$name" "$rows"
done

if [[ -n "${TARGET_DB_URL:-}" ]]; then
  echo
  echo "── target contents (will be REPLACED) ──"
  TARGET_OBJECTS="$(psql "$TARGET_DB_URL" -X -q -A -t -c "
    select count(*) from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','v','m');")"
  echo "  $TARGET_OBJECTS object(s) in public"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "--dry-run: nothing written."
  exit 0
fi

# ─── dump ───────────────────────────────────────────────────────────────────

mkdir -p "$DUMP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_FILE="$DUMP_DIR/${SRC_REF}-public-${STAMP}.dump"

echo
echo "── dumping public schema from $SRC_REF ──"

# --no-owner / --no-privileges: the two projects have different role OIDs and
#   Supabase manages the roles itself, so carrying ownership across produces
#   errors for no benefit. Grants are re-applied by migration 0006.
# --schema=public: Supabase's auth, storage, realtime and vault schemas are
#   managed by the platform. Copying them breaks the target.
# --no-publications / --no-subscriptions: realtime replication artefacts that
#   do not belong to another project.
DUMP_ARGS=(
  --format=custom
  --schema=public
  --no-owner
  --no-privileges
  --no-publications
  --no-subscriptions
  --quote-all-identifiers
)

if [[ $INCLUDE_GRADES -eq 0 ]]; then
  DUMP_ARGS+=(--schema-only)
  echo "  (schema only)"
fi

pg_dump "$SOURCE_DB_URL" "${DUMP_ARGS[@]}" --file="$DUMP_FILE"

echo "  wrote $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"

if [[ $DUMP_ONLY -eq 1 ]]; then
  echo
  echo "--dump-only: target untouched."
  echo "This file is a full copy of production data. Do not commit it; .dumps/ is gitignored."
  exit 0
fi

# ─── restore ────────────────────────────────────────────────────────────────

echo
echo "── restoring into $DST_REF ──"

psql "$TARGET_DB_URL" -X -q -v ON_ERROR_STOP=1 <<'SQL'
-- Extensions the schema depends on. Present on every Supabase project, but
-- created here so a bare project works too.
create extension if not exists unaccent;
create extension if not exists pg_trgm;

drop schema if exists public cascade;
create schema public;

-- Supabase's PostgREST reaches the schema through these roles. Without the
-- grants the API answers 404 for every table and it looks like a routing bug.
grant usage on schema public to anon, authenticated, service_role;
grant all on schema public to postgres;
SQL

# --no-owner again on the restore side: the dump may still carry owner
# statements for objects created before --no-owner took effect.
#
# Errors are NOT fatal here on purpose. A Supabase target has platform-managed
# objects that a restore will collide with, and stopping on the first one leaves
# a half-restored database that is worse than a complete one with warnings.
# The verification below is what actually decides whether it worked.
pg_restore \
  --dbname="$TARGET_DB_URL" \
  --no-owner \
  --no-privileges \
  --schema=public \
  "$DUMP_FILE" 2>&1 | grep -vE "already exists|must be owner|extension \"" || true

# ─── verify ─────────────────────────────────────────────────────────────────

echo
echo "── verifying ──"

compare() {
  local table="$1"
  local src dst
  src="$(psql "$SOURCE_DB_URL" -X -q -A -t -c "select count(*) from \"$table\";" 2>/dev/null || echo "n/a")"
  dst="$(psql "$TARGET_DB_URL" -X -q -A -t -c "select count(*) from \"$table\";" 2>/dev/null || echo "n/a")"
  if [[ "$src" == "$dst" ]]; then
    printf "  %-24s %10s = %-10s ok\n" "$table" "$src" "$dst"
  else
    printf "  %-24s %10s ≠ %-10s MISMATCH\n" "$table" "$src" "$dst"
  fi
}

for table in courses sections departments instructors grades grade_ingests; do
  compare "$table"
done

echo
echo "Done."
echo
echo "Next, against the TEST project only:"
echo "  DATABASE_DIRECT_URL=\"\$TARGET_DB_URL\" ./db/migrate.sh --dry-run"
echo "  DATABASE_DIRECT_URL=\"\$TARGET_DB_URL\" ./db/migrate.sh"
echo "  python3 scripts/backfill_instructor_ids.py --dry-run"
echo
echo "That last command prints the instructor match rate, which is the number"
echo "that decides how much manual triage the real migration will cost."
