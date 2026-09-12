-- Extensions and the two text functions everything downstream depends on.
--
-- `normalize_name` and `slugify` are the foundation of instructor identity.
-- Both are immutable so they can back generated columns and indexes, and both
-- have a Python twin in `instructor_registry.py` that must agree with them
-- exactly. `tests/fixtures/names.json` is the shared contract; a change here
-- that is not mirrored there is a bug that surfaces months later as duplicate
-- instructor records that are painful to merge.

create extension if not exists unaccent;
create extension if not exists pg_trgm;


-- Canonical form of a human name for matching purposes.
--
-- Unaccent, lowercase, replace every run of non-alphanumeric characters with a
-- single space, trim. "Walsh, Shane Bolles" -> "walsh shane bolles";
-- "O'Brien" -> "o brien"; "José García" -> "jose garcia".
--
-- Punctuation becomes a space rather than nothing so that "O'Brien" and
-- "O Brien" agree. Deleting it instead would produce "obrien", which then
-- fails to match the spaced spelling Testudo actually prints.
--
-- Stripping *everything* non-alphanumeric after unaccenting, rather than
-- listing the punctuation to remove, means there is no character class to keep
-- in sync with the Python implementation and no dependence on the database
-- locale's idea of which characters are letters. A name that unaccent cannot
-- map at all (a script outside its dictionary) normalizes to null, which the
-- resolver treats as unresolvable and sends to the match queue rather than
-- guessing.
--
-- Deliberately NOT done here:
--   * reordering "Last, First" into "First Last" — the caller knows which
--     source it holds, and natural_name() in parse.py does that first
--   * dropping middle names — that is a *matching* step with its own
--     confidence level, not a normalization step
--   * stripping suffixes (jr, iii) — two people in a family genuinely differ
--     by that token, so it is kept and matched on
--
-- The two-argument form of unaccent() is immutable; the one-argument form is
-- only stable, because it resolves its dictionary through search_path. The
-- explicit `set search_path` is what makes that resolution reliable: Supabase
-- installs extensions into the `extensions` schema, so a bare `unaccent` is
-- not visible to a function called during a write with a different path.
create or replace function normalize_name(raw text)
returns text
language sql
immutable
strict
parallel safe
set search_path = public, extensions, pg_catalog
as $$
    select nullif(
        btrim(
            regexp_replace(
                lower(unaccent('unaccent'::regdictionary, raw)),
                '[^a-z0-9]+', ' ', 'g'
            )
        ),
        ''
    )
$$;

comment on function normalize_name(text) is
    'Canonical unaccented lowercase form of a name, punctuation collapsed to '
    'single spaces. Must stay identical to normalize_name() in '
    'scraper/instructor_registry.py; both are tested against '
    'scraper/tests/fixtures/names.json.';


-- URL slug for a professor page.
--
-- These become permanent public URLs the moment a professor page is indexed,
-- so this function is frozen from the point the first page ships. It is just
-- normalize_name with spaces as hyphens, which is what keeps the two
-- consistent by construction rather than by review:
--
--   'Shane Bolles Walsh' -> 'shane-bolles-walsh'
--   "Erin O'Brien"       -> 'erin-o-brien'
--   'José García'        -> 'jose-garcia'
--   'John Smith Jr.'     -> 'john-smith-jr'
--
-- Collision handling (david-levin, david-levin-2) is not here: it has to see
-- the table, so it lives in next_instructor_slug() in 0002.
create or replace function slugify(raw text)
returns text
language sql
immutable
strict
parallel safe
set search_path = public, extensions, pg_catalog
as $$
    select nullif(replace(normalize_name(raw), ' ', '-'), '')
$$;

comment on function slugify(text) is
    'Permanent public URL slug for a professor. Frozen once professor pages '
    'ship: changing it breaks every shared and indexed link.';
