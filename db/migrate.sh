#!/usr/bin/env bash
#
# Apply pending migrations from db/migrations in order.
#
# Migrations need DDL, so this talks to Postgres directly rather than through
# PostgREST. Each file runs in its own transaction; a failure rolls that file
# back and stops, leaving every earlier file applied and `schema_migrations`
# consistent with reality.
#
# Usage:
#   DATABASE_DIRECT_URL=postgresql://... ./db/migrate.sh [--dry-run] [--to NNNN]
#
# DATABASE_DIRECT_URL may also be set in `db/.env`; anything already in the
# environment overrides the file.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="$HERE/migrations"

source "$HERE/load_env.sh"
load_env_file

DRY_RUN=0
STOP_AFTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --to) STOP_AFTER="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${DATABASE_DIRECT_URL:-}" ]]; then
  echo "DATABASE_DIRECT_URL is not set." >&2
  echo "This is the session connection string from the Supabase dashboard" >&2
  echo "(Settings -> Database), not DATABASE_URL." >&2
  echo >&2
  echo "Export it, or put it in $HERE/.env (gitignored):" >&2
  echo "  DATABASE_DIRECT_URL=postgresql://postgres:...@db.<ref>.supabase.co:5432/postgres" >&2
  exit 1
fi

command -v psql >/dev/null 2>&1 || { echo "psql not found on PATH." >&2; exit 1; }

psql_do() { psql "$DATABASE_DIRECT_URL" -v ON_ERROR_STOP=1 "$@"; }

# The ledger. Created outside any migration so that migration 0001 is a normal
# migration rather than a special case.
psql_do -q <<'SQL'
create table if not exists schema_migrations (
    version     text primary key,
    filename    text        not null,
    checksum    text        not null,
    applied_at  timestamptz not null default now()
);
SQL

applied_checksum() {
  psql_do -Atc "select checksum from schema_migrations where version = '$1'"
}

shopt -s nullglob
files=("$MIGRATIONS_DIR"/[0-9][0-9][0-9][0-9]_*.sql)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No migrations found in $MIGRATIONS_DIR" >&2
  exit 1
fi

pending=0
for file in "${files[@]}"; do
  base="$(basename "$file")"
  version="${base%%_*}"

  # sha256sum on Linux/CI, shasum on macOS.
  if command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "$file" | cut -d' ' -f1)"
  else
    checksum="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  fi

  existing="$(applied_checksum "$version")"

  if [[ -n "$existing" ]]; then
    if [[ "$existing" != "$checksum" ]]; then
      echo "ERROR: $base has changed since it was applied." >&2
      echo "  applied: $existing" >&2
      echo "  on disk: $checksum" >&2
      echo "Applied migrations are append-only. Write a new migration instead." >&2
      exit 1
    fi
    continue
  fi

  pending=$((pending + 1))

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "would apply $base"
  else
    echo "applying $base"
    # -1 wraps the file in a single transaction, so a mid-file failure leaves
    # nothing half-created. The ledger insert is inside it too, which is what
    # makes "applied" and "actually ran" the same statement.
    psql_do -q -1 -f "$file" -c \
      "insert into schema_migrations (version, filename, checksum)
       values ('$version', '$base', '$checksum')"
  fi

  if [[ -n "$STOP_AFTER" && "$version" == "$STOP_AFTER" ]]; then
    break
  fi
done

if [[ $pending -eq 0 ]]; then
  echo "Already up to date."
elif [[ $DRY_RUN -eq 1 ]]; then
  echo "$pending migration(s) pending."
else
  echo "Applied $pending migration(s)."
fi
