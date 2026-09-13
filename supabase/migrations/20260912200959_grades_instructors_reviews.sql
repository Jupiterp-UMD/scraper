-- Grades, instructor identity, reviews, and the rating model.
--
-- Everything the grade/PlanetTerp migration adds on top of the schema
-- production had before it: the dashboard-made `courses`, `sections`,
-- `departments`, `instructors` and `user_data` tables, and the materialized
-- `active_instructors`. This file replaces `grades/schema.sql` and
-- `db/migrations/0001`-`0036`, squashed into their final state. Those files are
-- in git history (last present at b66e3ca), with the incident-by-incident
-- reasoning behind much of what is here; comments below and inside function
-- bodies that cite a four-digit number refer to them.
--
-- It applies on top of `20260912200000_prod_baseline.sql`, production's schema
-- as dumped before this migration. Production already has that schema, so there
-- the baseline is marked applied with `supabase migration repair`, not run.
--
-- `supabase db push` runs the whole file and its ledger row in one
-- transaction: a failure anywhere leaves the database exactly as it was.
--
-- The data half of the migration -- grade ingest, the PlanetTerp snapshot, the
-- Testudo scrape, the instructor backfill, triage -- runs afterwards, from
-- scripts. See db/README.md for the order.


/* =========================== session settings =========================== */

-- A DDL migration must not run under the role's `statement_timeout`. Without
-- this the whole file inherits whatever limit the connecting role carries, and
-- any single statement that runs long is cancelled with 57014 -- rolling back
-- the entire migration, because push runs it as one transaction. That is how
-- `select refresh_section_instructor_slugs()` (removed at the foot of this
-- file) took the whole migration down.
--
-- `20260912200000_prod_baseline.sql` sets the same three; a schema dump emits
-- them for exactly this reason. Plain `set`, not `set local`, to match it and
-- because `set local` outside a transaction block is a warning and a no-op --
-- these must hold whether the file is applied by push or by psql. They last
-- only for the connection applying the migration; no role default changes, so
-- the timeouts the application runs under are untouched.
set statement_timeout = 0;
set lock_timeout = 0;
set idle_in_transaction_session_timeout = 0;


/* ============================== extensions ============================== */

create extension if not exists unaccent;
create extension if not exists pg_trgm;


/* ============================ name functions ============================ */

-- Canonical form of a human name for matching purposes.
--
-- Unaccent, lowercase, replace every run of non-alphanumeric characters with a
-- single space, trim. "Walsh, Shane Bolles" -> "walsh shane bolles";
-- "O'Brien" -> "o brien"; "José García" -> "jose garcia".
--
-- This, the Python in `names.py`, and the site's `Names.ts` must agree exactly.
-- `tests/fixtures/names.json` is the shared contract and
-- `db/tests/name_parity.sql` checks this side of it. A drift produces duplicate
-- instructor records whose grade history is split across two pages.
--
-- Punctuation becomes a space rather than nothing so that "O'Brien" and
-- "O Brien" agree. Stripping everything non-alphanumeric after unaccenting,
-- rather than listing punctuation, leaves no character class to keep in sync
-- and no dependence on the locale. A name unaccent cannot map normalizes to
-- null, which the resolver queues rather than guesses at.
--
-- Deliberately NOT done here: reordering "Last, First" (the caller knows which
-- source it holds), dropping middle names (a matching step with its own
-- confidence), stripping suffixes (two people in a family differ by that
-- token).
--
-- The two-argument unaccent() is immutable where the one-argument form is only
-- stable, and the pinned search_path finds it in Supabase's `extensions` schema
-- whatever the caller's path.
create function normalize_name(raw text)
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


-- URL slug for a professor page: normalize_name with spaces as hyphens, which
-- keeps the two consistent by construction.
--
--   'Shane Bolles Walsh' -> 'shane-bolles-walsh'
--   "Erin O'Brien"       -> 'erin-o-brien'
--   'John Smith Jr.'     -> 'john-smith-jr'
--
-- These are permanent public URLs once a professor page is indexed, so this
-- function is frozen. Collision suffixes (david-levin-2) need to see the table
-- and live in next_instructor_slug().
create function slugify(raw text)
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


-- Testudo emits these where no instructor has been assigned. They must never
-- become instructor records. Checked after normalization, so "Instructor: TBA"
-- and "instructor tba" are the same entry.
create function is_instructor_denylisted(raw text)
returns boolean
language sql
immutable
parallel safe
set search_path = public, extensions, pg_catalog
as $$
    select normalize_name(raw) is null
        or normalize_name(raw) in (
            'tba', 'tbd', 'staff', 'instructor', 'instructor tba',
            'instructor tbd', 'instructor staff', 'no instructor',
            'unknown', 'not assigned', 'to be announced', 'to be determined'
        )
$$;


-- Surname is the last token of a normalized name. Wrong for compound surnames
-- ("garcia lopez"), which makes the resolver more conservative rather than
-- less: a mismatched surname queues the name instead of linking it to the wrong
-- person.
create function name_surname(norm text)
returns text
language sql
immutable
strict
parallel safe
as $$
    select (regexp_split_to_array(norm, ' '))[array_length(regexp_split_to_array(norm, ' '), 1)]
$$;

create function name_first(norm text)
returns text
language sql
immutable
strict
parallel safe
as $$
    select (regexp_split_to_array(norm, ' '))[1]
$$;

-- "shane bolles walsh" -> "shane walsh". Middle names appear throughout the
-- registrar exports and almost never in Testudo, so this is the single
-- highest-yield matching step.
create function name_first_last(norm text)
returns text
language sql
immutable
strict
parallel safe
as $$
    select case
        when array_length(regexp_split_to_array(norm, ' '), 1) < 2 then norm
        else name_first(norm) || ' ' || name_surname(norm)
    end
$$;


/* ================================= GPA ================================== */

-- GPA on the UMD 4.0 scale. Withdrawals and non-letter outcomes are excluded
-- from numerator and denominator, matching how UMD and PlanetTerp compute it.
-- Null when nobody earned a letter grade. Immutable so it can back a generated
-- column.
create function umd_gpa(
    a_plus int, a int, a_minus int,
    b_plus int, b int, b_minus int,
    c_plus int, c int, c_minus int,
    d_plus int, d int, d_minus int,
    f int
) returns numeric
language sql
immutable
strict
as $$
    select case
        when (a_plus + a + a_minus + b_plus + b + b_minus
              + c_plus + c + c_minus + d_plus + d + d_minus + f) = 0
        then null
        else round(
            (4.0 * a_plus + 4.0 * a + 3.7 * a_minus
           + 3.3 * b_plus + 3.0 * b + 2.7 * b_minus
           + 2.3 * c_plus + 2.0 * c + 1.7 * c_minus
           + 1.3 * d_plus + 1.0 * d + 0.7 * d_minus
           + 0.0 * f)::numeric
            / (a_plus + a + a_minus + b_plus + b + b_minus
             + c_plus + c + c_minus + d_plus + d + d_minus + f),
            3)
    end
$$;


/* ============================= instructors ============================== */

-- `instructors` was keyed on PlanetTerp's slug and matched by exact name
-- string, and the same person is "Walsh, Shane Bolles" to the registrar and
-- "Shane Walsh" to Testudo. From here on `id` is the identity everything joins
-- on, `name` is display-only, and every observed spelling is an alias.
alter table instructors
    -- Jupiterp-owned identity. `name` becomes display-only.
    add column if not exists id bigint generated by default as identity,
    add column if not exists name_norm text
        generated always as (normalize_name(name)) stored,

    -- PlanetTerp baseline, frozen at the one-time snapshot. PlanetTerp is no
    -- longer updated, so these are a historical record, not a feed.
    add column if not exists pt_slug           text,
    add column if not exists pt_average_rating numeric(3,2),
    add column if not exists pt_review_count   int,
    add column if not exists pt_snapshot_at    timestamptz,

    -- Jupiterp's own ratings, recomputed on a schedule: the recency decay
    -- makes them change on days when no review does.
    add column if not exists jupiterp_rating       numeric(3,2),
    add column if not exists jupiterp_review_count int not null default 0,
    add column if not exists combined_rating       numeric(3,2),

    -- Provenance and lifecycle.
    add column if not exists first_seen_term int,
    add column if not exists last_seen_term  int,
    add column if not exists is_active       boolean not null default false,
    add column if not exists created_at      timestamptz not null default now(),
    add column if not exists updated_at      timestamptz not null default now();

-- `slug` changes meaning: it was PlanetTerp's and becomes Jupiterp's own, and
-- is rewritten at the end of this file. The old value is kept here so a
-- redirect map is a query away.
update instructors set pt_slug = slug where pt_slug is null;

-- A unique index rather than a primary key: `slug` is the existing primary key
-- and moving it buys nothing.
create unique index instructors_id_key on instructors (id);

create unique index instructors_slug_key on instructors (slug);
create index instructors_name_norm_idx on instructors (name_norm);

-- Backs the API's `nameSearch` substring filter, which is otherwise a
-- sequential scan on every keystroke of the directory search.
create index instructors_name_trgm_idx
    on instructors using gin (name_norm gin_trgm_ops);

-- Every stage of resolve_instructor() narrows by surname before scoring. The
-- trigram index cannot answer `similarity(a, b) >= x`, and surname equality is
-- far more selective anyway.
create index instructors_surname_idx
    on instructors (name_surname(name_norm));

-- `active_instructors` and `/v1/instructors?activeOnly=true` both filter on
-- is_active and order by slug. About a fifth of the table is active, so without
-- this `count=true` from the directory search is a sequential scan.
create index instructors_active_slug_idx
    on instructors (slug)
    where is_active;

comment on column instructors.slug is
    'Jupiterp-owned URL slug, generated by next_instructor_slug(). Permanent '
    'once a professor page is published.';
comment on column instructors.pt_slug is
    'PlanetTerp''s slug, retained only for the one-time rating join and any '
    'future redirect table. Not used for routing.';
comment on column instructors.name is
    'Display name. Never join on this - use id, or resolve through '
    'instructor_aliases.';
comment on column instructors.is_active is
    'Whether this instructor teaches a section in the current Testudo scrape. '
    'The definition of "active" for both `/v1/instructors/active` (via the '
    'active_instructors view) and `/v1/instructors?activeOnly=true`. Written '
    'only by set_active_instructors(); do not set it by hand.';
comment on index instructors_surname_idx is
    'Candidate narrowing for resolve_instructor(). Every resolution stage '
    'filters on name_surname(name_norm) before scoring.';


create function touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

create trigger instructors_touch_updated_at
    before update on instructors
    for each row execute function touch_updated_at();


-- Allocate a slug for a new instructor, suffixing on collision: 'david-levin',
-- then 'david-levin-2'. Two professors genuinely share a name and the second
-- still needs a URL.
create function next_instructor_slug(raw_name text)
returns text
language plpgsql
as $$
declare
    base      text := slugify(raw_name);
    candidate text;
    n         int  := 1;
begin
    if base is null or base = '' then
        raise exception 'cannot slugify name %', raw_name;
    end if;

    candidate := base;
    loop
        exit when not exists (select 1 from instructors where slug = candidate);
        n := n + 1;
        candidate := base || '-' || n;
    end loop;

    return candidate;
end;
$$;


/* ========================= aliases and the queue ======================== */

-- Every spelling of a name ever observed, from any source, pointing at the one
-- instructor it means. `alias_norm` is the primary key, so a spelling cannot
-- mean two people.
--
-- Append-only. Deleting a row orphans every grade row matched through it, and
-- the resolver re-queues the name for a human who cannot know it was decided.
create table instructor_aliases (
    alias_norm    text primary key,
    -- As observed, for the audit trail: which exact string produced this link.
    alias_raw     text not null,
    instructor_id bigint not null references instructors (id) on delete cascade,
    source        text not null
        check (source in ('testudo', 'planetterp', 'registrar', 'manual')),
    -- < 1.0 means the link was inferred rather than seen.
    confidence    real not null default 1.0
        check (confidence > 0 and confidence <= 1.0),
    created_at    timestamptz not null default now()
);

create index instructor_aliases_instructor_idx
    on instructor_aliases (instructor_id);

-- The resolver's fuzzy steps compare against alias spellings too.
create index instructor_aliases_trgm_idx
    on instructor_aliases using gin (alias_norm gin_trgm_ops);

comment on table instructor_aliases is
    'Append-only. Every observed spelling -> one instructor. Deleting a row '
    'orphans the grade rows matched through it.';


-- Names the resolver refused to guess at, with the candidates that nearly
-- matched so triage is a choice rather than a search.
--
-- `candidates` is a bare bigint[] with no foreign key, so an id can outlive the
-- instructor it named; the detail view drops dead ids and merge_instructors()
-- rewrites them.
create table instructor_match_queue (
    id          bigserial primary key,
    observed    text not null,
    observed_norm text generated always as (normalize_name(observed)) stored,
    source      text not null
        check (source in ('testudo', 'planetterp', 'registrar', 'manual')),
    -- {course_code, term, sec_code} -- enough to look the section up and decide
    -- who actually taught it.
    context     jsonb,
    candidates  bigint[],
    resolved_to bigint references instructors (id),
    resolved_at timestamptz,
    -- 'backfill', 'scraper' or 'auto' for the machine; anything else is a human.
    resolved_by text,
    created_at  timestamptz not null default now()
);

-- One open entry per spelling per source. Without this, a name that appears in
-- 400 sections queues 400 identical decisions.
create unique index instructor_match_queue_open_idx
    on instructor_match_queue (observed_norm, source)
    where resolved_at is null;

create index instructor_match_queue_pending_idx
    on instructor_match_queue (created_at)
    where resolved_at is null;


/* ============================ section links ============================= */

-- The id-keyed companion to `sections.instructors[]`, which stays exactly as it
-- is: the API, the npm package and the site all read it. This table holds the
-- foreign key tying sections to instructors and feeds triage's "sections now"
-- count.
create table section_instructors (
    course_code   text not null,
    sec_code      text not null,
    instructor_id bigint not null references instructors (id) on delete cascade,
    primary key (course_code, sec_code, instructor_id)
);

create index section_instructors_instructor_idx
    on section_instructors (instructor_id);

comment on table section_instructors is
    'Lookup companion to sections.instructors[]. Rebuilt by '
    'reconcile_instructors() on every section scrape; sections.instructors '
    'remains the primary read path.';


-- The scraper uploads a run's links here in chunks (PostgREST rejects very
-- large bodies), then swap_section_instructors() replaces the live table in one
-- transaction. Emptying the live table across a dozen requests instead left a
-- window in which a cached read pinned a truncated professor list for a day.
create unlogged table section_instructors_staging (
    course_code   text   not null,
    sec_code      text   not null,
    instructor_id bigint not null,
    primary key (course_code, sec_code, instructor_id)
);

comment on table section_instructors_staging is
    'Scratch space for a scrape''s section-instructor links. Written in chunks, '
    'then swapped into section_instructors by swap_section_instructors() in a '
    'single transaction. Unlogged: it is rebuilt from Testudo every run and '
    'has no value after the swap.';


-- The resolved slug for each name in `instructors`, positionally aligned and
-- NULL where unresolved, so clients link a professor without matching on a
-- name. Stored rather than derived per request because it only changes when a
-- scrape reconciles, and deriving it cost ~127ms on a gen-ed search.
alter table sections
    add column if not exists instructor_slugs text[];

comment on column sections.instructor_slugs is
    'Resolved professor page slug for each entry in `instructors`, positionally '
    'aligned, NULL where unresolved. Maintained by '
    'refresh_section_instructor_slugs(); do not write it by hand.';


/* ================================ grades ================================ */

-- Section-level grade distributions, obtained by MPIA request.
--
-- One row per (term, course_code, sec_code). That key is what makes
-- re-ingesting a file a no-op and loading a new term additive: the loader
-- upserts and never deletes. The fifteen buckets are stored exactly as the
-- registrar reported them. `graded` and `gpa` are generated so PostgREST can
-- filter and sort on them.
create table grades (
    -- YYYY followed by the month the term begins (01 spring, 05 summer,
    -- 08 fall, 12 winter).
    term        int  not null,

    -- Matches `courses.course_code`, though a course that no longer exists
    -- has grade rows and no course row.
    course_code text not null,

    -- Normalized to the four-character form `sections.sec_code` uses; older
    -- exports dropped leading zeros and the loader restores them.
    sec_code    text not null,

    -- Exactly as printed by the registrar, "Last, First Middle". Null for the
    -- ~26% of rows the export left blank; a row where this is null but
    -- `instructor_name` is not was attributed by carrying another section's
    -- instructor forward.
    instructor      text,

    -- The effective instructor in "First Middle Last" order. The audit trail
    -- for `instructor_id`: what the registrar wrote, before any resolution.
    instructor_name text,

    -- How `instructor_name` was arrived at. Precedence
    -- reported > testudo > lead > course.
    --   'reported'  named on this row by the registrar (74% of rows)
    --   'testudo'   the section's scheduled instructor per Testudo, where the
    --               registrar left it blank. Not as good as reported: the
    --               scheduled instructor is not always who assigned grades.
    --   'lead'      carried from the lead section of the same lecture group,
    --               ex. 0101 -> 0102: its discussions and labs. (21%)
    --   'course'    carried from elsewhere in the course. Unreliable -- MATH113
    --               Fall 2019 names Darcy Conant on FC05/FC06 and leaves
    --               FC01-FC04 blank -- so excluded from default aggregates. (2%)
    --   null        no section of the course was ever named. (3%)
    instructor_source text
        check (instructor_source in ('reported', 'lead', 'course', 'testudo')),

    -- Enrollment as reported. From Fall 2017 this equals the sum of the
    -- buckets; earlier terms can exceed it by students the old report did not
    -- categorize, so prefer `graded` as a denominator across eras.
    total   int not null,

    a_plus  int not null default 0,
    a       int not null default 0,
    a_minus int not null default 0,
    b_plus  int not null default 0,
    b       int not null default 0,
    b_minus int not null default 0,
    c_plus  int not null default 0,
    c       int not null default 0,
    c_minus int not null default 0,
    d_plus  int not null default 0,
    d       int not null default 0,
    d_minus int not null default 0,
    f       int not null default 0,
    w       int not null default 0,
    other   int not null default 0,

    -- Students who received a letter grade; the GPA denominator.
    graded int generated always as (
        a_plus + a + a_minus + b_plus + b + b_minus
        + c_plus + c + c_minus + d_plus + d + d_minus + f
    ) stored,

    gpa numeric generated always as (
        umd_gpa(a_plus, a, a_minus, b_plus, b, b_minus,
                c_plus, c, c_minus, d_plus, d, d_minus, f)
    ) stored,

    primary key (term, course_code, sec_code),

    -- Nullable, and stays nullable: ~3% of rows name nobody and some names wait
    -- on triage. SET NULL, not cascade: losing an instructor record must never
    -- delete grade rows, which cannot be obtained again.
    instructor_id bigint references instructors (id) on delete set null
);

create index grades_course_idx      on grades (course_code);
create index grades_course_term_idx on grades (course_code, term);
create index grades_term_idx        on grades (term);
create index grades_instructor_idx  on grades (instructor_name);
create index grades_instructor_src_idx
    on grades (instructor_name, instructor_source);
create index grades_instructor_id_idx
    on grades (instructor_id);
create index grades_instructor_id_course_idx
    on grades (instructor_id, course_code);

-- Supplies pre-sorted normalized names to unlinked_instructor_names()'s
-- grouping, and the lookup the triage functions use to move grade rows.
create index grades_instructor_name_norm_idx
    on grades (normalize_name(instructor_name));

comment on column grades.instructor_id is
    'Resolved instructor. Null where the export named nobody, or where the '
    'name is still in instructor_match_queue. Backfilled by '
    'scripts/backfill_instructor_ids.py, maintained by the loader thereafter.';


-- Which source file produced which term. The loader skips files already
-- logged here; `file_sha256` means an amended file is recognized as new even
-- under the same name.
create table grade_ingests (
    id          bigserial primary key,
    term        int  not null,
    source_file text not null,
    file_sha256 text not null,
    row_count   int  not null,
    -- Rows where `total` exceeded the sum of the buckets, and how many students
    -- that accounts for. Non-zero for terms before Fall 2017.
    unaccounted_rows     int not null default 0,
    unaccounted_students int not null default 0,
    warnings    text[],
    ingested_at timestamptz not null default now(),
    -- A stale matview has no symptom: the site serves last term's numbers and
    -- looks healthy. refresh_grade_matviews() stamps these and ci.py fails when
    -- the newest ingest has no refresh against it.
    matviews_refreshed_at timestamptz,
    matview_refresh_ms    int
);

create unique index grade_ingests_term_hash_idx
    on grade_ingests (term, file_sha256);


/* ============================ grade rollups ============================= */

-- The default instructor aggregates count reported, testudo and lead
-- attributions. The `course` tier is sometimes demonstrably wrong and is left
-- to the `_all` view, behind `includeCarried=true`.

-- One row per course, over every section of every term.
create view course_grades as
select
    course_code,
    count(*)::int             as section_count,
    count(distinct term)::int as term_count,
    min(term)                 as first_term,
    max(term)                 as last_term,
    sum(total)::int   as total,
    sum(graded)::int  as graded,
    sum(a_plus)::int  as a_plus,
    sum(a)::int       as a,
    sum(a_minus)::int as a_minus,
    sum(b_plus)::int  as b_plus,
    sum(b)::int       as b,
    sum(b_minus)::int as b_minus,
    sum(c_plus)::int  as c_plus,
    sum(c)::int       as c,
    sum(c_minus)::int as c_minus,
    sum(d_plus)::int  as d_plus,
    sum(d)::int       as d,
    sum(d_minus)::int as d_minus,
    sum(f)::int       as f,
    sum(w)::int       as w,
    sum(other)::int   as other,
    umd_gpa(sum(a_plus)::int, sum(a)::int, sum(a_minus)::int,
            sum(b_plus)::int, sum(b)::int, sum(b_minus)::int,
            sum(c_plus)::int, sum(c)::int, sum(c_minus)::int,
            sum(d_plus)::int, sum(d)::int, sum(d_minus)::int,
            sum(f)::int) as gpa
from grades
group by course_code;


-- One row per course per term: "has this course gotten harder?".
create view course_term_grades as
select
    course_code,
    term,
    count(*)::int as section_count,
    sum(total)::int   as total,
    sum(graded)::int  as graded,
    sum(a_plus)::int  as a_plus,
    sum(a)::int       as a,
    sum(a_minus)::int as a_minus,
    sum(b_plus)::int  as b_plus,
    sum(b)::int       as b,
    sum(b_minus)::int as b_minus,
    sum(c_plus)::int  as c_plus,
    sum(c)::int       as c,
    sum(c_minus)::int as c_minus,
    sum(d_plus)::int  as d_plus,
    sum(d)::int       as d,
    sum(d_minus)::int as d_minus,
    sum(f)::int       as f,
    sum(w)::int       as w,
    sum(other)::int   as other,
    umd_gpa(sum(a_plus)::int, sum(a)::int, sum(a_minus)::int,
            sum(b_plus)::int, sum(b)::int, sum(b_minus)::int,
            sum(c_plus)::int, sum(c)::int, sum(c_minus)::int,
            sum(d_plus)::int, sum(d)::int, sum(d_minus)::int,
            sum(f)::int) as gpa
from grades
group by course_code, term;


-- Per-term totals and GPA. Materialized because as a plain view it was a full
-- aggregate over every grade row on each cache miss, at ~2s against anon's 3s
-- statement_timeout.
create materialized view grade_terms as
select term,
       count(*)::integer                    as section_count,
       count(distinct course_code)::integer as course_count,
       sum(total)::integer                  as total,
       sum(graded)::integer                 as graded,
       umd_gpa(sum(a_plus)::integer, sum(a)::integer, sum(a_minus)::integer,
               sum(b_plus)::integer, sum(b)::integer, sum(b_minus)::integer,
               sum(c_plus)::integer, sum(c)::integer, sum(c_minus)::integer,
               sum(d_plus)::integer, sum(d)::integer, sum(d_minus)::integer,
               sum(f)::integer)             as gpa
from grades
group by term;

-- `refresh ... concurrently` needs a unique index; without one a refresh takes
-- an ACCESS EXCLUSIVE lock and blocks every reader.
create unique index grade_terms_term_idx on grade_terms (term);

comment on materialized view grade_terms is
    'Per-term grade totals and GPA. Materialized in 0029: as a plain view this '
    'was a full aggregate over grades on every cache miss, at ~2s against the '
    'anon role''s 3s statement_timeout. Refreshed by refresh_grade_matviews().';


-- Grade distribution per (course, instructor): the professor page's grade chip.
-- Materialized for the same reason as grade_terms.
create materialized view course_instructor_grades as
select
    g.course_code,
    g.instructor_id,
    i.name as instructor,
    i.slug as instructor_slug,
    count(*)::int             as section_count,
    count(distinct g.term)::int as term_count,
    min(g.term) as first_term,
    max(g.term) as last_term,
    sum(g.total)::int   as total,
    sum(g.graded)::int  as graded,
    sum(g.a_plus)::int  as a_plus,
    sum(g.a)::int       as a,
    sum(g.a_minus)::int as a_minus,
    sum(g.b_plus)::int  as b_plus,
    sum(g.b)::int       as b,
    sum(g.b_minus)::int as b_minus,
    sum(g.c_plus)::int  as c_plus,
    sum(g.c)::int       as c,
    sum(g.c_minus)::int as c_minus,
    sum(g.d_plus)::int  as d_plus,
    sum(g.d)::int       as d,
    sum(g.d_minus)::int as d_minus,
    sum(g.f)::int       as f,
    sum(g.w)::int       as w,
    sum(g.other)::int   as other,
    umd_gpa(sum(g.a_plus)::int, sum(g.a)::int, sum(g.a_minus)::int,
            sum(g.b_plus)::int, sum(g.b)::int, sum(g.b_minus)::int,
            sum(g.c_plus)::int, sum(g.c)::int, sum(g.c_minus)::int,
            sum(g.d_plus)::int, sum(g.d)::int, sum(g.d_minus)::int,
            sum(g.f)::int) as gpa
from grades g
join instructors i on i.id = g.instructor_id
where g.instructor_id is not null
  and g.instructor_source in ('reported', 'lead', 'testudo')
group by g.course_code, g.instructor_id, i.name, i.slug;

create unique index course_instructor_grades_key
    on course_instructor_grades (course_code, instructor_id);
create index course_instructor_grades_instructor_idx
    on course_instructor_grades (instructor_id);
create index course_instructor_grades_slug_idx
    on course_instructor_grades (instructor_slug);


-- Wider coverage, lower confidence. A plain view: it is only served behind an
-- explicit opt-in.
create view course_instructor_grades_all as
select
    g.course_code,
    g.instructor_id,
    i.name as instructor,
    i.slug as instructor_slug,
    count(*)::int             as section_count,
    count(distinct g.term)::int as term_count,
    min(g.term) as first_term,
    max(g.term) as last_term,
    sum(g.total)::int   as total,
    sum(g.graded)::int  as graded,
    sum(g.a_plus)::int  as a_plus,
    sum(g.a)::int       as a,
    sum(g.a_minus)::int as a_minus,
    sum(g.b_plus)::int  as b_plus,
    sum(g.b)::int       as b,
    sum(g.b_minus)::int as b_minus,
    sum(g.c_plus)::int  as c_plus,
    sum(g.c)::int       as c,
    sum(g.c_minus)::int as c_minus,
    sum(g.d_plus)::int  as d_plus,
    sum(g.d)::int       as d,
    sum(g.d_minus)::int as d_minus,
    sum(g.f)::int       as f,
    sum(g.w)::int       as w,
    sum(g.other)::int   as other,
    umd_gpa(sum(g.a_plus)::int, sum(g.a)::int, sum(g.a_minus)::int,
            sum(g.b_plus)::int, sum(g.b)::int, sum(g.b_minus)::int,
            sum(g.c_plus)::int, sum(g.c)::int, sum(g.c_minus)::int,
            sum(g.d_plus)::int, sum(g.d)::int, sum(g.d_minus)::int,
            sum(g.f)::int) as gpa
from grades g
join instructors i on i.id = g.instructor_id
where g.instructor_id is not null
group by g.course_code, g.instructor_id, i.name, i.slug;


-- One row per instructor across every course: the professor page's headline
-- "3.12 average GPA across 6 courses".
create materialized view instructor_grades as
select
    g.instructor_id,
    i.name as instructor,
    i.slug as instructor_slug,
    count(*)::int                      as section_count,
    count(distinct g.course_code)::int as course_count,
    count(distinct g.term)::int        as term_count,
    min(g.term) as first_term,
    max(g.term) as last_term,
    sum(g.total)::int   as total,
    sum(g.graded)::int  as graded,
    sum(g.a_plus)::int  as a_plus,
    sum(g.a)::int       as a,
    sum(g.a_minus)::int as a_minus,
    sum(g.b_plus)::int  as b_plus,
    sum(g.b)::int       as b,
    sum(g.b_minus)::int as b_minus,
    sum(g.c_plus)::int  as c_plus,
    sum(g.c)::int       as c,
    sum(g.c_minus)::int as c_minus,
    sum(g.d_plus)::int  as d_plus,
    sum(g.d)::int       as d,
    sum(g.d_minus)::int as d_minus,
    sum(g.f)::int       as f,
    sum(g.w)::int       as w,
    sum(g.other)::int   as other,
    umd_gpa(sum(g.a_plus)::int, sum(g.a)::int, sum(g.a_minus)::int,
            sum(g.b_plus)::int, sum(g.b)::int, sum(g.b_minus)::int,
            sum(g.c_plus)::int, sum(g.c)::int, sum(g.c_minus)::int,
            sum(g.d_plus)::int, sum(g.d)::int, sum(g.d_minus)::int,
            sum(g.f)::int) as gpa
from grades g
join instructors i on i.id = g.instructor_id
where g.instructor_id is not null
  and g.instructor_source in ('reported', 'lead', 'testudo')
group by g.instructor_id, i.name, i.slug;

create unique index instructor_grades_key
    on instructor_grades (instructor_id);
create index instructor_grades_slug_idx
    on instructor_grades (instructor_slug);
-- Sorting the professor directory by GPA.
create index instructor_grades_gpa_idx
    on instructor_grades (gpa desc nulls last);


-- The "is this professor getting harsher?" trend chart. A plain view: it is
-- always filtered to one instructor, and materializing it would multiply the
-- refresh cost by the number of terms.
create view instructor_term_grades as
select
    g.instructor_id,
    g.term,
    i.name as instructor,
    i.slug as instructor_slug,
    count(*)::int                      as section_count,
    count(distinct g.course_code)::int as course_count,
    sum(g.total)::int   as total,
    sum(g.graded)::int  as graded,
    sum(g.a_plus)::int  as a_plus,
    sum(g.a)::int       as a,
    sum(g.a_minus)::int as a_minus,
    sum(g.b_plus)::int  as b_plus,
    sum(g.b)::int       as b,
    sum(g.b_minus)::int as b_minus,
    sum(g.c_plus)::int  as c_plus,
    sum(g.c)::int       as c,
    sum(g.c_minus)::int as c_minus,
    sum(g.d_plus)::int  as d_plus,
    sum(g.d)::int       as d,
    sum(g.d_minus)::int as d_minus,
    sum(g.f)::int       as f,
    sum(g.w)::int       as w,
    sum(g.other)::int   as other,
    umd_gpa(sum(g.a_plus)::int, sum(g.a)::int, sum(g.a_minus)::int,
            sum(g.b_plus)::int, sum(g.b)::int, sum(g.b_minus)::int,
            sum(g.c_plus)::int, sum(g.c)::int, sum(g.c_minus)::int,
            sum(g.d_plus)::int, sum(g.d)::int, sum(g.d_minus)::int,
            sum(g.f)::int) as gpa
from grades g
join instructors i on i.id = g.instructor_id
where g.instructor_id is not null
  and g.instructor_source in ('reported', 'lead', 'testudo')
group by g.instructor_id, g.term, i.name, i.slug;


-- Which courses a professor taught in which terms, without the buckets. Feeds
-- the professor page's course filter chips.
create view instructor_course_terms as
select
    g.instructor_id,
    g.course_code,
    count(distinct g.term)::int as term_count,
    min(g.term) as first_term,
    max(g.term) as last_term,
    sum(g.graded)::int as graded,
    array_agg(distinct g.term order by g.term desc) as terms
from grades g
where g.instructor_id is not null
  and g.instructor_source in ('reported', 'lead', 'testudo')
group by g.instructor_id, g.course_code;


/* =============================== reviews ================================ */

-- Hosting reviews of named individuals is a different liability posture from
-- hosting a catalogue, and the schema carries most of that weight. Three
-- invariants are structural rather than left to application code:
--
--   1. No review is readable before it is approved. Public reads go through
--      `public_reviews`, which does not select the identity columns at all.
--      anon has no grant on `reviews`.
--   2. Raw email addresses are never stored. Only a peppered SHA-256.
--   3. Every moderation decision, automated or human, is recorded.

-- 'unverified' submitted, email not yet confirmed
-- 'pending'    verified, awaiting a triage decision
-- 'escalated'  automated triage declined to decide; a human must act
-- 'approved'   publicly visible
-- 'rejected'   refused; the reviewer may appeal or resubmit
-- 'withdrawn'  retracted by the reviewer
create type review_status as enum
    ('unverified', 'pending', 'escalated', 'approved', 'rejected', 'withdrawn');


create table reviews (
    id            uuid primary key default gen_random_uuid(),
    -- CASCADE: deleting an instructor destroys their reviews, which is why
    -- merge_instructors() reassigns reviews before it deletes anything.
    instructor_id bigint not null references instructors (id) on delete cascade,

    -- Nullable: a review of the professor generally, not of one course.
    course_code   text,
    term          int,

    -- 1-5 in half steps. The scale matches PlanetTerp's so the imported
    -- baseline blends without rescaling, and the check refuses 4.3 rather than
    -- silently averaging it in.
    rating numeric(2,1) not null
        check (rating >= 1 and rating <= 5 and rating * 2 = floor(rating * 2)),

    expected_grade text check (expected_grade in
        ('A+','A','A-','B+','B','B-','C+','C','C-','D+','D','D-','F','W','Other')),
    title text check (char_length(title) <= 120),
    body  text check (char_length(body)  <= 5000),

    status review_status not null default 'unverified',

    -- Identity. The raw address is NEVER stored. The pepper lives in Secret
    -- Manager, not here, so a database disclosure alone does not permit a
    -- dictionary attack on a guessable address space. Treat it as permanent:
    -- rotating it invalidates every dedupe check ever made.
    email_hash   text not null,
    email_domain text not null,

    -- sha256 of the manage key, which is shown to the reviewer once.
    edit_key_hash text not null,

    -- Abuse forensics. Hashed, and purged on the privacy policy's schedule.
    submit_ip_hash  text,
    user_agent_hash text,

    submitted_at timestamptz not null default now(),
    verified_at  timestamptz,
    moderated_at timestamptz,
    moderator    text,
    reject_reason text,
    edited_at    timestamptz,

    -- Automated triage scheduling. `next_triage_at` is set when classification
    -- is deferred on the model's daily quota. `triage_attempts` caps retries so
    -- a broken API key escalates to a human instead of parking reviews forever.
    triage_attempts int not null default 0,
    next_triage_at  timestamptz,

    -- Reserved for a future accounts system; always null in v1.
    user_id uuid
);

-- One live review per person per professor per course. Partial, so a rejected
-- or withdrawn review does not block the appeal path.
create unique index reviews_one_per_person
    on reviews (instructor_id, coalesce(course_code, ''), email_hash)
    where status in ('unverified', 'pending', 'approved');

create index reviews_instructor_approved_idx
    on reviews (instructor_id, submitted_at desc) where status = 'approved';

create index reviews_moderation_idx
    on reviews (status, submitted_at) where status in ('pending', 'escalated');

-- Drives the deferred-triage retry sweep.
create index reviews_triage_retry_idx
    on reviews (next_triage_at) where next_triage_at is not null;

-- Drives the abandoned-submission purge.
create index reviews_unverified_idx
    on reviews (submitted_at) where status = 'unverified';


-- Every triage decision ever made. Append-only: the audit trail for a disputed
-- decision, and the dataset for whether the classifier agrees with humans
-- before it is allowed to act alone.
create table moderation_decisions (
    id         bigserial primary key,
    review_id  uuid not null references reviews (id) on delete cascade,
    decision   text not null check (decision in ('approve', 'reject', 'escalate')),
    decided_by text not null check (decided_by in ('ai', 'human', 'rule')),

    -- A moderator identifier, or the pinned model id. A provider silently
    -- swapping the model is a policy change nobody decided to make.
    actor      text not null,
    -- Prompt/ruleset version, so a decision can be reproduced later.
    policy_version text,

    confidence real,      -- null for human decisions
    categories text[],    -- policy categories the classifier flagged
    reason     text,
    -- Whether this changed `reviews.status` or was only recorded. False for
    -- every row in shadow mode, which makes enabling automation a config change.
    applied    boolean not null default false,
    raw_response jsonb,
    created_at timestamptz not null default now()
);

create index moderation_decisions_review_idx
    on moderation_decisions (review_id, created_at desc);

-- The shadow-mode agreement query.
create index moderation_decisions_agreement_idx
    on moderation_decisions (decided_by, decision, created_at desc);


-- Single-use capabilities for verifying, managing and withdrawing a review
-- without an account. Only the hash is stored.
create table review_tokens (
    token_hash text primary key,
    review_id  uuid not null references reviews (id) on delete cascade,
    -- 'verify'   emailed to the reviewer to confirm their address
    -- 'manage'   returned once; lets the reviewer edit or withdraw
    -- 'moderate' reserved and unused: a forwardable decision link is a
    --            decision anyone can take
    purpose    text not null check (purpose in ('verify', 'manage', 'moderate')),
    expires_at timestamptz not null,
    used_at    timestamptz,
    created_at timestamptz not null default now()
);

create index review_tokens_review_idx on review_tokens (review_id, purpose);
create index review_tokens_expiry_idx on review_tokens (expires_at) where used_at is null;


-- A professor's entire recourse path in v1, which makes response time on these
-- load-bearing.
create table review_reports (
    id         bigserial primary key,
    review_id  uuid not null references reviews (id) on delete cascade,
    reason     text not null,
    detail     text,
    reporter_email_hash text,
    created_at timestamptz not null default now(),
    resolved_at timestamptz,
    resolution text
);

create index review_reports_open_idx
    on review_reports (created_at) where resolved_at is null;


-- Queued transactional mail. Hitting the provider's daily cap defers a send;
-- letting submissions through unverified instead would make exhausting the cap
-- a way around email verification.
create table email_outbox (
    id          bigserial primary key,
    review_id   uuid references reviews (id) on delete cascade,
    -- Held only long enough to send, then nulled.
    recipient   text,
    template    text not null check (template in
        ('verify', 'manage_key', 'rejected', 'resend_verify')),
    payload     jsonb not null default '{}'::jsonb,

    status      text not null default 'queued'
        check (status in ('queued', 'sent', 'failed', 'abandoned')),
    attempts    int not null default 0,
    next_attempt_at timestamptz not null default now(),
    last_error  text,
    created_at  timestamptz not null default now(),
    sent_at     timestamptz
);

create index email_outbox_due_idx
    on email_outbox (next_attempt_at) where status = 'queued';

comment on table email_outbox is
    'Queued transactional mail. Exists so that hitting the provider daily cap '
    'defers a send rather than bypassing email verification.';


-- The only path by which a review reaches the public. A view rather than a
-- policy, so the identity columns cannot be selected at all. It runs as its
-- owner, so anon's missing grant on `reviews` does not break it.
create view public_reviews as
select
    r.id,
    r.instructor_id,
    i.slug as instructor_slug,
    r.course_code,
    r.term,
    r.rating,
    r.expected_grade,
    r.title,
    r.body,
    r.submitted_at,
    r.edited_at
from reviews r
join instructors i on i.id = r.instructor_id
where r.status = 'approved';

comment on view public_reviews is
    'The only public path to review content. Approved rows only, and the '
    'identity columns are not selectable through it at all.';


/* ============================ rate limiting ============================= */

-- In Postgres rather than process memory: Cloud Run autoscales, so a
-- per-instance limiter is bypassed by retrying until a cold instance answers.
-- `bucket` is a hashed identifier, never a raw IP.
create table rate_limit_counters (
    bucket       text        not null,   -- 'ip:<hash>' | 'email:<hash>' | 'instructor:<id>'
    action       text        not null,
    window_start timestamptz not null,
    count        int         not null default 0,
    primary key (bucket, action, window_start)
);

create index rate_limit_counters_window_idx
    on rate_limit_counters (window_start);


-- A sliding-window counter: sub-buckets at a tenth of the window, and the count
-- is the sum over the trailing window. Fixed windows allowed a double burst
-- either side of a boundary, and the per-instructor limit exists precisely to
-- catch bursts. Windows align to the Unix epoch.
--
-- Called inside the transaction of the write it guards. The increment conflicts
-- on the same row, so two concurrent submissions serialize on its lock and
-- neither can observe a count below the limit and proceed.
create function bump_rate_limit(
    p_bucket text,
    p_action text,
    p_window interval
)
returns int
language plpgsql
as $$
declare
    -- floor(), not a bare cast. See above.
    win_secs bigint := greatest(floor(extract(epoch from p_window))::bigint, 1);
    step     bigint := greatest(win_secs / 10, 1);
    now_secs bigint := floor(extract(epoch from now()))::bigint;
    slot     timestamptz := to_timestamp(now_secs - (now_secs % step));
    total    int;
begin
    -- The increment still happens first and in the same statement that
    -- conflicts, so two concurrent submissions contend on the same row: the
    -- second blocks on the first's lock and reads the committed value after it
    -- commits. Neither can observe a count below the limit and proceed.
    insert into rate_limit_counters (bucket, action, window_start, count)
    values (p_bucket, p_action, slot, 1)
    on conflict (bucket, action, window_start)
    do update set count = rate_limit_counters.count + 1;

    -- Served entirely by the primary key, which leads on (bucket, action).
    select coalesce(sum(c.count), 0)::int
      into total
      from rate_limit_counters c
     where c.bucket = p_bucket
       and c.action = p_action
       and c.window_start > to_timestamp(now_secs - win_secs)
       and c.window_start <= slot;

    return total;
end;
$$;

comment on function bump_rate_limit(text, text, interval) is
    'Increment a caller''s counter and return their count over the trailing '
    'window. Sliding, to within a tenth of the window; there is no boundary at '
    'which the count resets.';


-- The default is well clear of the longest window in use (24 hours). Called
-- by the hourly sweep.
create function prune_rate_limits(
    p_older_than interval default interval '48 hours'
)
returns int
language plpgsql
as $$
declare
    removed int;
begin
    delete from rate_limit_counters
     where window_start < now() - p_older_than;

    get diagnostics removed = row_count;
    return removed;
end;
$$;

comment on function prune_rate_limits(interval) is
    'Delete rate-limit counters older than the longest live window. Called by '
    'POST /v1/admin/sweep.';


/* ============================= rating model ============================= */

-- Recency-decayed Jupiterp reviews, blended with the frozen PlanetTerp
-- baseline, shrunk toward the global mean. Recomputed on a schedule, not by a
-- trigger: the decay makes ratings change on days when no review does.

-- One row of tunables. They are guesses, and keeping them here means the
-- sensitivity sweep can re-run the model with other values without a deploy.
create table rating_config (
    id boolean primary key default true check (id),

    -- Half-life of a review's weight. Four years is roughly one undergraduate
    -- cohort: a review falls to half weight about when the last student who
    -- could have taken that section has graduated.
    review_half_life_years numeric not null default 4.0,

    -- Half-life of the PlanetTerp baseline from its snapshot date. Shorter,
    -- because it is a frozen number that ages badly.
    pt_half_life_years numeric not null default 2.0,

    -- After this many years PlanetTerp's contribution is dropped entirely.
    pt_max_age_years numeric not null default 6.0,

    -- Cap on PlanetTerp's weight, in equivalent reviews, so 400 old reviews do
    -- not pin a professor to their 2026 rating.
    pt_weight_cap numeric not null default 50,

    -- Bayesian shrinkage, in equivalent reviews at the global mean. Stops a
    -- three-review 4.9 outranking a sixty-review 4.6. This decides what a
    -- rating is; min_weight_to_display decides whether to show one.
    shrinkage_reviews numeric not null default 5.0,

    -- Below this much total weight no rating is displayed.
    min_weight_to_display numeric not null default 3.0,

    updated_at timestamptz not null default now()
);

-- Displayed from the first review. Zero is safe rather than a special case: the
-- model returns null when the combined weight is zero, before the threshold is
-- consulted.
insert into rating_config (id, min_weight_to_display) values (true, 0);


-- Every instructor's rating under a given set of constants. Parameterised so
-- the sensitivity sweep is this same function with different arguments.
create function compute_instructor_ratings(
    p_review_half_life numeric default null,
    p_pt_half_life     numeric default null,
    p_pt_max_age       numeric default null,
    p_pt_weight_cap    numeric default null,
    p_shrinkage        numeric default null
)
returns table (
    instructor_id      bigint,
    jupiterp_rating    numeric,
    jupiterp_reviews   int,
    jupiterp_weight    numeric,
    pt_weight          numeric,
    combined_rating    numeric,
    total_weight       numeric
)
language plpgsql
stable
as $$
declare
    cfg          rating_config%rowtype;
    review_hl    numeric;
    pt_hl        numeric;
    pt_max_age   numeric;
    pt_cap       numeric;
    shrink       numeric;
    global_mean  numeric;
begin
    select * into cfg from rating_config where id;

    review_hl  := coalesce(p_review_half_life, cfg.review_half_life_years);
    pt_hl      := coalesce(p_pt_half_life,     cfg.pt_half_life_years);
    pt_max_age := coalesce(p_pt_max_age,       cfg.pt_max_age_years);
    pt_cap     := coalesce(p_pt_weight_cap,    cfg.pt_weight_cap);
    shrink     := coalesce(p_shrinkage,        cfg.shrinkage_reviews);

    -- The prior. Weighted by the same decay as everything else, so it is the
    -- mean of what the site currently believes rather than of all history.
    -- Falls back to the scale midpoint before any reviews exist, which is the
    -- only defensible value when there is nothing to average.
    select coalesce(
               sum(r.rating * power(0.5, (extract(epoch from now() - r.submitted_at) / 31557600.0) / review_hl))
               / nullif(sum(power(0.5, (extract(epoch from now() - r.submitted_at) / 31557600.0) / review_hl)), 0),
               3.0)
      into global_mean
      from reviews r
     where r.status = 'approved';

    return query
    with jupiterp as (
        select
            r.instructor_id as iid,
            sum(power(0.5, (extract(epoch from now() - r.submitted_at) / 31557600.0) / review_hl)) as w,
            sum(r.rating * power(0.5, (extract(epoch from now() - r.submitted_at) / 31557600.0) / review_hl)) as weighted_sum,
            count(*)::int as n
        from reviews r
        where r.status = 'approved'
        group by r.instructor_id
    ),
    planetterp as (
        select
            i.id as iid,
            i.pt_average_rating as pt_rating,
            case
                when i.pt_average_rating is null or i.pt_snapshot_at is null then 0
                when (extract(epoch from now() - i.pt_snapshot_at) / 31557600.0) > pt_max_age then 0
                else least(coalesce(i.pt_review_count, 0), pt_cap)
                     * power(0.5, (extract(epoch from now() - i.pt_snapshot_at) / 31557600.0) / pt_hl)
            end as w
        from instructors i
    )
    select
        i.id,
        -- Jupiterp's own decayed average, shown alongside the blend rather
        -- than folded invisibly into it.
        case when coalesce(j.w, 0) > 0 then round(j.weighted_sum / j.w, 2) end,
        coalesce(j.n, 0),
        round(coalesce(j.w, 0), 4),
        round(coalesce(p.w, 0), 4),
        -- The displayed number: both sources plus `shrink` notional reviews
        -- sitting at the global mean.
        case
            when coalesce(j.w, 0) + coalesce(p.w, 0) <= 0 then null
            else round(
                (shrink * global_mean
                 + coalesce(j.weighted_sum, 0)
                 + coalesce(p.w, 0) * coalesce(p.pt_rating, 0))
                / (shrink + coalesce(j.w, 0) + coalesce(p.w, 0)),
                2)
        end,
        round(coalesce(j.w, 0) + coalesce(p.w, 0), 4)
    from instructors i
    left join jupiterp   j on j.iid = i.id
    left join planetterp p on p.iid = i.id;
end;
$$;


-- Write the computed ratings back onto `instructors`. Run nightly.
--
-- `combined_rating` is written null below the display floor rather than
-- computed and hidden, so anything sorting on the column gets the answer the
-- page shows. `average_rating` is the legacy v0 field (`real`) kept in step
-- with it, and is part of the change test: a row whose other three columns
-- already matched used to keep a stale legacy rating forever.
create function refresh_instructor_ratings()
returns integer
language plpgsql
as $function$
declare
    cfg      rating_config%rowtype;
    affected int;
begin
    select * into cfg from rating_config where id;

    with computed as (
        select * from compute_instructor_ratings()
    )
    update instructors i
       set jupiterp_rating       = c.jupiterp_rating,
           jupiterp_review_count = c.jupiterp_reviews,
           combined_rating       = case
               when c.total_weight >= cfg.min_weight_to_display then c.combined_rating
               else null
           end,
           -- The v0 string field stays aliased to the displayed rating so
           -- existing clients keep working through the semantic change.
           average_rating = case
               when c.total_weight >= cfg.min_weight_to_display then c.combined_rating::real
               else null
           end
      from computed c
     where c.instructor_id = i.id
       and (i.jupiterp_rating       is distinct from c.jupiterp_rating
         or i.jupiterp_review_count is distinct from c.jupiterp_reviews
         or i.combined_rating       is distinct from case
                when c.total_weight >= cfg.min_weight_to_display then c.combined_rating
                else null
            end
         or i.average_rating        is distinct from case
                when c.total_weight >= cfg.min_weight_to_display then c.combined_rating::real
                else null
            end);

    get diagnostics affected = row_count;
    return affected;
end;
$function$;

comment on function refresh_instructor_ratings() is
    'Recompute and store every instructor rating. Nightly. Ratings decay with '
    'time, so they change on days when no review does.';


-- The same model at 2/4/8-year half-lives. If rankings barely move, the
-- constant is not worth arguing about.
create view rating_sensitivity_sweep as
with sweeps as (
    select 2.0 as half_life, * from compute_instructor_ratings(2.0)
    union all
    select 4.0 as half_life, * from compute_instructor_ratings(4.0)
    union all
    select 8.0 as half_life, * from compute_instructor_ratings(8.0)
)
select
    s.half_life,
    s.instructor_id,
    i.name,
    s.combined_rating,
    s.total_weight,
    rank() over (partition by s.half_life order by s.combined_rating desc nulls last) as rank
from sweeps s
join instructors i on i.id = s.instructor_id
where s.total_weight >= 3;

comment on view rating_sensitivity_sweep is
    'Same model at 2/4/8-year half-lives, for comparing rankings. Expensive; '
    'run it deliberately, not on a page load.';


/* ========================== active instructors ========================== */

-- The dashboard version was a materialized view matching `instructors.name`
-- against `sections.instructors` -- the name join this whole migration exists
-- to remove -- refreshed once a night by a pg_cron job, which is unscheduled
-- further down. `create or replace view` cannot convert a matview, so it is
-- dropped first.
--
-- `instructors.is_active` is the single definition of active: it is what
-- `/v1/instructors?activeOnly=true` filters on, and its only writer refuses an
-- empty scrape. Note the response widens from three columns to all of
-- `instructors`.
drop materialized view if exists active_instructors;

create view active_instructors as
select i.*
from instructors i
where i.is_active;

comment on view active_instructors is
    'Instructors currently teaching, per `instructors.is_active`. That column '
    'is the single definition of active; `set_active_instructors()` is its only '
    'writer and refuses an empty scrape. Was defined over `section_instructors` '
    'until 0035.';


-- `sections` with its stored instructor_slugs, kept as a stable name for
-- clients that read it.
create view sections_with_instructors as
select course_code,
       sec_code,
       instructors,
       meetings,
       open_seats,
       total_seats,
       waitlist,
       holdfile,
       instructor_slugs
from sections;

comment on view sections_with_instructors is
    'sections, including the stored instructor_slugs. Retained as a stable name '
    'for clients; the column now lives on the table.';


/* ============================== resolver ================================ */

-- Resolution lives in SQL and nowhere else, so the grade backfill and the
-- nightly scrape can never disagree about who a name is. Python calls these
-- through PostgREST rpc(); see instructor_registry.py.

-- Find the instructor a name refers to. Read-only.
--
-- Steps run in order and the first that produces exactly ONE candidate wins. A
-- step with two or more stops the search and reports them for a human: a
-- fuzzier step cannot resolve an ambiguity a stricter one could not.
--
--   1.0   exact alias hit
--   0.9   first + last, middle names dropped
--   0.7   first initial + last
--   sim   trigram similarity >= 0.85, within the same surname only
--
-- Steps 2-4 never match across surnames, which is what keeps "David Levin"
-- from ever being linked to "David Levine".
create function resolve_instructor(observed text)
returns table (instructor_id bigint, confidence real, method text, candidates bigint[])
language plpgsql
stable
set search_path = public, extensions, pg_catalog
as $$
declare
    norm     text := normalize_name(observed);
    surname  text;
    initial  text;
    matches  bigint[];
begin
    if norm is null or is_instructor_denylisted(observed) then
        return;
    end if;

    -- 1. Exact alias hit.
    select array_agg(a.instructor_id)
      into matches
      from instructor_aliases a
     where a.alias_norm = norm;

    if array_length(matches, 1) = 1 then
        return query select matches[1], 1.0::real, 'exact'::text, matches;
        return;
    elsif array_length(matches, 1) > 1 then
        -- Two instructors claiming the same spelling is a data error, not an
        -- ambiguity to resolve automatically.
        return query select null::bigint, null::real, 'ambiguous_alias'::text, matches;
        return;
    end if;

    surname := name_surname(norm);

    -- 2. First + last, middles dropped, within this surname.
    select array_agg(distinct id)
      into matches
      from (
          select i.id
            from instructors i
           where i.name_norm is not null
             and name_surname(i.name_norm) = surname
             and name_first_last(i.name_norm) = name_first_last(norm)
           union
          select a.instructor_id
            from instructor_aliases a
           where name_surname(a.alias_norm) = surname
             and name_first_last(a.alias_norm) = name_first_last(norm)
      ) s;

    if array_length(matches, 1) = 1 then
        return query select matches[1], 0.9::real, 'first_last'::text, matches;
        return;
    elsif array_length(matches, 1) > 1 then
        return query select null::bigint, null::real, 'ambiguous_first_last'::text, matches;
        return;
    end if;

    -- 3. First initial + last. "s walsh" matches "shane walsh" only if it is
    --    the only Walsh whose first name starts with s.
    initial := left(name_first(norm), 1);

    select array_agg(distinct id)
      into matches
      from (
          select i.id
            from instructors i
           where i.name_norm is not null
             and name_surname(i.name_norm) = surname
             and left(name_first(i.name_norm), 1) = initial
           union
          select a.instructor_id
            from instructor_aliases a
           where name_surname(a.alias_norm) = surname
             and left(name_first(a.alias_norm), 1) = initial
      ) s;

    if array_length(matches, 1) = 1 then
        return query select matches[1], 0.7::real, 'first_initial'::text, matches;
        return;
    elsif array_length(matches, 1) > 1 then
        return query select null::bigint, null::real, 'ambiguous_initial'::text, matches;
        return;
    end if;

    -- 4. Trigram similarity, to catch typos and transliteration differences
    --    only. Still confined to an exact surname match, so this can correct
    --    "Steven" vs "Stephen" but never "Levin" vs "Levine".
    return query
    with scored as (
        select i.id,
               similarity(i.name_norm, norm) as sim
          from instructors i
         where i.name_norm is not null
           and name_surname(i.name_norm) = surname
           and similarity(i.name_norm, norm) >= 0.85
    )
    select s.id, s.sim::real, 'trigram'::text, array_agg(s.id) over ()
      from scored s
     order by s.sim desc
     limit 1;
end;
$$;


-- Resolve a name and record the outcome. The only resolver entry point the
-- scraper and the backfill call.
--
-- A confident match writes the alias, so the next occurrence is an exact hit,
-- and closes any queue entry for that spelling with a machine actor. No match
-- or an ambiguity queues the name and returns null; it never guesses.
--
-- `create_if_missing` separates the callers. The Testudo scrape passes true: a
-- professor teaching this term is a real person. The grade backfill passes
-- false, because a sixteen-year-old spelling with no current section is exactly
-- where a human should confirm before a new professor page appears.
--
-- The parameter names collide with queue and alias columns and are called by
-- name through PostgREST, so they stay. `use_column` settles the conflict
-- target and every parameter reference is qualified.
create function link_instructor(
    observed          text,
    source            text,
    context           jsonb   default null,
    create_if_missing boolean default false,
    seen_term         int     default null
)
returns bigint
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
#variable_conflict use_column
declare
    norm       text := normalize_name(link_instructor.observed);
    r          record;
    new_id     bigint;
    auto_actor text := case link_instructor.source
                           when 'registrar' then 'backfill'
                           when 'testudo'   then 'scraper'
                           else 'auto'
                       end;
begin
    if norm is null or is_instructor_denylisted(link_instructor.observed) then
        return null;
    end if;

    select * into r from resolve_instructor(link_instructor.observed);

    if r.instructor_id is not null then
        insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
        values (norm, link_instructor.observed, r.instructor_id,
                link_instructor.source, r.confidence)
        on conflict (alias_norm) do nothing;

        if link_instructor.seen_term is not null then
            update instructors
               set first_seen_term = least(coalesce(first_seen_term, link_instructor.seen_term),
                                           link_instructor.seen_term),
                   last_seen_term  = greatest(coalesce(last_seen_term, link_instructor.seen_term),
                                              link_instructor.seen_term)
             where id = r.instructor_id;
        end if;

        -- This spelling was queued on an earlier pass and has now been
        -- settled. Only ever closes a row this call actually resolved.
        update instructor_match_queue q
           set resolved_to = r.instructor_id,
               resolved_at = now(),
               resolved_by = auto_actor
         where q.observed_norm = norm
           and q.source        = link_instructor.source
           and q.resolved_at is null;

        return r.instructor_id;
    end if;

    if link_instructor.create_if_missing and r.method is null then
        insert into instructors (name, slug, first_seen_term, last_seen_term, is_active)
        values (link_instructor.observed,
                next_instructor_slug(link_instructor.observed),
                link_instructor.seen_term, link_instructor.seen_term, true)
        returning id into new_id;

        insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
        values (norm, link_instructor.observed, new_id, link_instructor.source, 1.0)
        on conflict (alias_norm) do nothing;

        update instructor_match_queue q
           set resolved_to = new_id,
               resolved_at = now(),
               resolved_by = auto_actor
         where q.observed_norm = norm
           and q.source        = link_instructor.source
           and q.resolved_at is null;

        return new_id;
    end if;

    insert into instructor_match_queue (observed, source, context, candidates)
    values (link_instructor.observed, link_instructor.source,
            link_instructor.context, r.candidates)
    on conflict (observed_norm, source) where resolved_at is null
    do update set context = coalesce(instructor_match_queue.context, excluded.context);

    return null;
end;
$$;

comment on function link_instructor(text, text, jsonb, boolean, int) is
    'Single entry point for instructor resolution. Called by the Testudo '
    'scrape (create_if_missing => true) and the grade backfill '
    '(create_if_missing => false). Returns null when the name was queued.';


/* ========================== backfill helpers ============================ */

-- Set-at-a-time helpers for scripts/backfill_instructor_ids.py, which otherwise
-- made ~28,000 PostgREST round trips. Each is one bounded batch, so the backfill
-- stays interruptible and resumable -- the reason it is a script and not part
-- of this migration.

-- Distinct unlinked names, aggregated server-side. `variants` is every raw
-- spelling that normalizes to the name, so the write-back links all of them
-- ("Jonathan K. Lazar" and "Jonathan K Lazar"). Context comes from the most
-- recent term the name appears in. The denylist is applied after grouping,
-- where it runs once per name instead of once per grade row.
create function unlinked_instructor_names(
    page_limit  int default 1000,
    page_offset int default 0
)
returns table (
    name_norm         text,
    observed          text,
    variants          text[],
    row_count         bigint,
    course_code       text,
    term              int,
    sec_code          text,
    instructor_source text
)
language sql
stable
set search_path = public, extensions, pg_catalog
as $$
    with kept as (
        select g.instructor_name,
               normalize_name(g.instructor_name) as nn,
               g.course_code, g.term, g.sec_code, g.instructor_source
        from grades g
        where g.instructor_name is not null
          and g.instructor_id is null
          and normalize_name(g.instructor_name) is not null
    ),
    grouped as (
        select nn,
               (array_agg(instructor_name   order by term desc, instructor_name))[1] as observed,
               array_agg(distinct instructor_name)                                   as variants,
               count(*)                                                              as row_count,
               (array_agg(course_code       order by term desc, instructor_name))[1] as course_code,
               (array_agg(term              order by term desc, instructor_name))[1] as term,
               (array_agg(sec_code          order by term desc, instructor_name))[1] as sec_code,
               (array_agg(instructor_source order by term desc, instructor_name))[1] as instructor_source
        from kept
        group by nn
    )
    select name_norm, observed, variants, row_count,
           course_code, term, sec_code, instructor_source
    from (
        select nn as name_norm, observed, variants, row_count,
               course_code, term, sec_code, instructor_source
        from grouped
        where not is_instructor_denylisted(observed)
    ) filtered
    order by name_norm
    limit page_limit offset page_offset
$$;

comment on function unlinked_instructor_names(int, int) is
    'Distinct unlinked instructor names in grades, with every raw spelling '
    'that normalizes to each. Paged; used by the backfill.';


-- Resolve a batch through link_instructor(). Parameters are `p_` prefixed to
-- avoid the column-name collision link_instructor has.
create function link_instructors_bulk(
    batch               jsonb,
    p_source            text,
    p_create_if_missing boolean default false
)
returns jsonb
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare
    item   jsonb;
    result jsonb := '[]'::jsonb;
    rid    bigint;
begin
    for item in select value from jsonb_array_elements(batch)
    loop
        rid := link_instructor(
            item->>'observed',
            p_source,
            item->'context',
            p_create_if_missing,
            nullif(item->>'seen_term', '')::int
        );

        result := result || jsonb_build_array(jsonb_build_object(
            'name_norm',     item->>'name_norm',
            'instructor_id', rid
        ));
    end loop;

    return result;
end;
$$;

comment on function link_instructors_bulk(jsonb, text, boolean) is
    'Resolve a batch of observed names through link_instructor(). Returns one '
    '{name_norm, instructor_id} per input; instructor_id null means queued.';


-- Write instructor_id back for a batch. The variants are flattened with a
-- lateral join so the match is plain equality the planner can serve from
-- grades_instructor_idx; `= any(array_column)` degraded into a scan per batch
-- and hit the statement timeout.
create function apply_instructor_ids(batch jsonb)
returns bigint
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare
    n bigint;
begin
    with mapping as (
        select (e->>'instructor_id')::bigint as iid,
               v.variant
        from jsonb_array_elements(batch) e
        cross join lateral jsonb_array_elements_text(e->'variants') as v(variant)
        where e->>'instructor_id' is not null
    )
    update grades g
       set instructor_id = m.iid
      from mapping m
     where g.instructor_id is null
       and g.instructor_name = m.variant;

    get diagnostics n = row_count;
    return n;
end;
$$;

comment on function apply_instructor_ids(jsonb) is
    'Write instructor_id onto grade rows for a batch of resolved names, '
    'covering every raw spelling that normalized to each name.';


/* ============================ triage (admin) ============================ */

-- Point a spelling at a different instructor than the resolver chose. Moves
-- the alias, the grade rows, and the queue row together: repointing the alias
-- alone leaves the professor page empty, and moving the rows alone means the
-- next scrape silently undoes the correction. Safe to re-run.
create function override_instructor_match(
    p_observed_norm text,
    p_instructor_id bigint,
    p_actor         text
)
returns bigint
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare
    moved bigint;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'p_actor is required: an override has to name who made it';
    end if;
    if p_actor in ('backfill', 'scraper', 'auto') then
        raise exception 'p_actor % is reserved for automated resolution', p_actor;
    end if;
    if not exists (select 1 from instructors where id = p_instructor_id) then
        raise exception 'no instructor with id %', p_instructor_id;
    end if;

    -- 1. The alias, so future resolutions of this spelling agree.
    -- 'manual' rather than 'human': instructor_aliases.source is constrained to
    -- ('testudo','planetterp','registrar','manual') and 'manual' is already the
    -- schema's name for a human-entered alias.
    insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
    values (p_observed_norm, p_observed_norm, p_instructor_id, 'manual', 1.0)
    on conflict (alias_norm)
    do update set instructor_id = excluded.instructor_id,
                  source        = 'manual',
                  confidence    = 1.0;

    -- 2. The grade rows already attributed under this spelling. Matching on
    --    the normalized form catches every raw variant at once, and uses
    --    grades_instructor_name_norm_idx.
    update grades
       set instructor_id = p_instructor_id
     where normalize_name(instructor_name) = p_observed_norm
       and instructor_id is distinct from p_instructor_id;
    get diagnostics moved = row_count;

    -- 3. The queue row, whether it was open or auto-closed.
    update instructor_match_queue q
       set resolved_to = p_instructor_id,
           resolved_at = now(),
           resolved_by = p_actor
     where q.observed_norm = p_observed_norm;

    return moved;
end;
$$;

comment on function override_instructor_match(text, bigint, text) is
    'Human correction of an instructor match. Repoints the alias, moves the '
    'grade rows, and records who decided. Matviews are NOT refreshed; call '
    'refresh_grade_matviews() when a batch of corrections is done.';


-- What the machine decided on its own. `outcome = created` -- a record made
-- from a registrar spelling nothing resembled -- is the set most worth a human
-- eye.
create view instructor_match_auto_resolved as
select q.id,
       q.observed,
       q.observed_norm,
       q.source,
       q.resolved_by,
       q.resolved_at,
       q.resolved_to        as instructor_id,
       i.name               as instructor_name,
       i.slug               as instructor_slug,
       coalesce(array_length(q.candidates, 1), 0) as candidate_count,
       case when coalesce(array_length(q.candidates, 1), 0) = 0
            then 'created'  else 'matched' end     as outcome,
       (select count(*) from grades g where g.instructor_id = q.resolved_to) as grade_rows
from instructor_match_queue q
join instructors i on i.id = q.resolved_to
where q.resolved_by in ('backfill', 'scraper', 'auto');

comment on view instructor_match_auto_resolved is
    'Queue entries settled without a human. Review surface for '
    'override_instructor_match(); `outcome = created` is the higher-risk set.';


-- Open queue entries with candidates hydrated, including how much data each
-- carries: choosing between "Hector Bravo" and "Hector Corrada Bravo" is
-- guesswork on names alone and not once one of them has 340 grade rows. Dead
-- candidate ids are dropped rather than shown blank; an entry whose candidates
-- all disappeared still appears, because it still needs a decision.
create view instructor_match_queue_detail as
select q.id,
       q.observed,
       q.observed_norm,
       q.source,
       q.context,
       q.created_at,
       coalesce(
           (
               select jsonb_agg(
                          jsonb_build_object(
                              'id',         i.id,
                              'name',       i.name,
                              'slug',       i.slug,
                              'is_active',  i.is_active,
                              'grade_rows', (select count(*) from grades g where g.instructor_id = i.id),
                              'sections',   (select count(*) from section_instructors s where s.instructor_id = i.id),
                              'first_term', i.first_seen_term,
                              'last_term',  i.last_seen_term
                          )
                          order by i.name
                      )
               from unnest(q.candidates) as c(cid)
               join instructors i on i.id = c.cid
           ),
           '[]'::jsonb
       ) as candidates
from instructor_match_queue q
where q.resolved_at is null;

comment on view instructor_match_queue_detail is
    'Open instructor_match_queue entries with candidates hydrated into JSON, '
    'including how much data each candidate carries. Backs /admin/professors.';


-- Merge duplicate instructor records into one.
--
-- Not a DELETE, because three of the five foreign keys into `instructors`
-- cascade: deleting a duplicate would destroy its reviews and aliases, null
-- its grade attribution, and fail outright on `instructor_match_queue.
-- resolved_to`. Everything is reassigned first and the delete is last, when it
-- cascades over nothing.
--
-- Two records with different PlanetTerp ratings are evidence of two people who
-- share a name. That is returned as `needs_confirmation` rather than raised, so
-- the admin screen can show the moderator both ratings instead of a generic
-- 500.
create function merge_instructors(
    p_keep      bigint,
    p_merge_ids bigint[],
    p_actor     text,
    p_force     boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    keeper   instructors%rowtype;
    ids      bigint[];
    conflict jsonb;
    donor    instructors%rowtype;
    moved_grades   bigint := 0;
    moved_reviews  bigint := 0;
    moved_aliases  bigint := 0;
    moved_sections bigint := 0;
    dropped_links  bigint := 0;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'p_actor is required: a merge has to name who made it';
    end if;
    if p_actor in ('backfill', 'scraper', 'auto') then
        raise exception 'p_actor % is reserved for automated resolution', p_actor;
    end if;

    select * into keeper from instructors where id = p_keep;
    if not found then
        raise exception 'no instructor with id % to keep', p_keep;
    end if;

    -- Distinct, and never the keeper: a caller that sends the survivor in both
    -- lists is asking for it to be deleted at the end.
    select coalesce(array_agg(distinct x), '{}')
      into ids
      from unnest(coalesce(p_merge_ids, '{}')) t(x)
     where x <> p_keep;

    if cardinality(ids) = 0 then
        raise exception 'merge_instructors needs at least one record to merge into %', p_keep;
    end if;

    if exists (select 1 from unnest(ids) t(x)
                where not exists (select 1 from instructors where id = t.x)) then
        raise exception 'one or more ids in % do not exist', ids;
    end if;

    /* ------------------------- the one hard stop ------------------------- */
    --
    -- 0023's reasoning, enforced instead of written down: two records with two
    -- DIFFERENT PlanetTerp ratings are evidence of two different people, not of
    -- one person recorded twice. PlanetTerp rated them separately, which means
    -- students distinguished them. Merging fuses two professors' reputations
    -- into one page and is not reversible from the merged state.
    --
    -- Returned rather than raised. The admin API flattens a SQL exception into
    -- a generic 500 (`sendInternalError`), so raising here would tell the
    -- moderator only that something went wrong -- and the whole point is to
    -- show them the two ratings and let them decide. This mirrors how
    -- `resolve_instructor_match` returns `already_resolved`.
    if not p_force then
        select jsonb_agg(jsonb_build_object(
                   'id', i.id, 'name', i.name, 'slug', i.slug,
                   'pt_average_rating', i.pt_average_rating,
                   'pt_review_count', i.pt_review_count))
          into conflict
          from instructors i
         where i.id = any(ids)
           and i.pt_average_rating is not null
           and keeper.pt_average_rating is not null
           and i.pt_average_rating <> keeper.pt_average_rating;

        if conflict is not null then
            return jsonb_build_object(
                'status', 'needs_confirmation',
                'reason', 'planetterp_ratings_differ',
                'detail', 'These records carry different PlanetTerp ratings, '
                       || 'which usually means they are two different people who '
                       || 'share a name rather than one person recorded twice. '
                       || 'Merging fuses both reputations into one page and '
                       || 'cannot be undone.',
                'keep', jsonb_build_object(
                    'id', keeper.id, 'name', keeper.name, 'slug', keeper.slug,
                    'pt_average_rating', keeper.pt_average_rating,
                    'pt_review_count', keeper.pt_review_count),
                'conflicts', conflict);
        end if;
    end if;

    /* ------------------------ reassign everything ------------------------ */

    -- Reviews first, because this is the one that cannot be reconstructed.
    -- A grade row can be re-derived from the term's file and an alias from the
    -- next scrape; a student's review exists once.
    update reviews set instructor_id = p_keep where instructor_id = any(ids);
    get diagnostics moved_reviews = row_count;

    update grades set instructor_id = p_keep where instructor_id = any(ids);
    get diagnostics moved_grades = row_count;

    update instructor_aliases set instructor_id = p_keep where instructor_id = any(ids);
    get diagnostics moved_aliases = row_count;

    -- `section_instructors` is keyed (course_code, sec_code, instructor_id), so
    -- a section that listed both records -- exactly what a co-taught duplicate
    -- looks like -- would collide on the update. Drop the losing side first.
    delete from section_instructors si
     where si.instructor_id = any(ids)
       and exists (select 1 from section_instructors k
                    where k.course_code = si.course_code
                      and k.sec_code    = si.sec_code
                      and k.instructor_id = p_keep);
    get diagnostics dropped_links = row_count;

    update section_instructors set instructor_id = p_keep where instructor_id = any(ids);
    get diagnostics moved_sections = row_count;

    -- Earlier decisions that resolved to a record being merged away. The
    -- foreign key is NO ACTION, so leaving these would make the delete below
    -- fail; and the answer they record is still correct, just under a different
    -- id now.
    update instructor_match_queue set resolved_to = p_keep where resolved_to = any(ids);

    -- Candidate arrays are a bare bigint[] with no foreign key, so a merged-away
    -- id simply rots there: 0028's detail view joins candidates to `instructors`
    -- and drops the ones that no longer resolve, which is how two open entries
    -- ended up showing fewer options than they were queued with. Rewrite them
    -- to the survivor instead.
    update instructor_match_queue q
       set candidates = sub.rewritten
      from (
        select q2.id,
               (select array_agg(distinct case when x = any(ids) then p_keep else x end)
                  from unnest(q2.candidates) t(x)) as rewritten
          from instructor_match_queue q2
         where q2.candidates && ids
      ) sub
     where q.id = sub.id;

    /* ------------------- carry the survivor's facts over ------------------ */

    -- The donor with the most PlanetTerp reviews is the one worth inheriting
    -- from when the keeper has no PlanetTerp record of its own. Only ever fills
    -- a NULL: a keeper that already has a rating keeps it, and the case where
    -- both have one and they disagree was stopped above.
    select * into donor
      from instructors
     where id = any(ids) and pt_slug is not null
     order by coalesce(pt_review_count, 0) desc, id
     limit 1;

    update instructors i
       set first_seen_term = least(
               i.first_seen_term,
               (select min(d.first_seen_term) from instructors d where d.id = any(ids))),
           last_seen_term = greatest(
               i.last_seen_term,
               (select max(d.last_seen_term) from instructors d where d.id = any(ids))),
           -- Active if any of them was. The next scrape overwrites this from
           -- what it actually sees; until then, dropping the flag would hide a
           -- professor who is teaching right now.
           is_active = i.is_active
               or coalesce((select bool_or(d.is_active) from instructors d where d.id = any(ids)), false),
           pt_slug           = coalesce(i.pt_slug,           donor.pt_slug),
           pt_average_rating = coalesce(i.pt_average_rating, donor.pt_average_rating),
           pt_review_count   = coalesce(i.pt_review_count,   donor.pt_review_count),
           pt_snapshot_at    = coalesce(i.pt_snapshot_at,    donor.pt_snapshot_at),
           updated_at        = now()
     where i.id = p_keep;

    -- Every merged-away spelling becomes an alias of the survivor.
    --
    -- Without this the merge undoes itself: `reconcile_instructors` sees the
    -- old name in the next Testudo scrape, resolves nothing, and creates the
    -- duplicate again -- or queues it, putting the same decision back in front
    -- of the next moderator. Their existing aliases moved above; this covers
    -- the name on the record itself, which need never have had one.
    insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
    select normalize_name(d.name), d.name, p_keep, 'manual', 1.0
      from instructors d
     where d.id = any(ids)
       and normalize_name(d.name) is not null
       and btrim(normalize_name(d.name)) <> ''
    on conflict (alias_norm)
    do update set instructor_id = excluded.instructor_id,
                  source        = 'manual',
                  confidence    = 1.0;

    -- Nothing points here any more, so the cascades have nothing to take.
    delete from instructors where id = any(ids);

    -- Reviews moved, so the survivor's review count and combined rating are
    -- now wrong on their public page. This is guarded by `is distinct from`
    -- internally and takes about a second over the whole table, which is worth
    -- it to keep a merge from leaving a visibly wrong number up until the
    -- nightly run.
    perform refresh_instructor_ratings();

    return jsonb_build_object(
        'status',          'merged',
        'kept',            p_keep,
        'kept_slug',       (select slug from instructors where id = p_keep),
        'merged',          to_jsonb(ids),
        'moved_reviews',   moved_reviews,
        'moved_grade_rows',moved_grades,
        'moved_aliases',   moved_aliases,
        'moved_sections',  moved_sections,
        'dropped_duplicate_section_links', dropped_links,
        -- Same convention as 0028: a batch of decisions should pay for one
        -- refresh, not one per click.
        'matviews_stale',  true);
end;
$$;

comment on function merge_instructors(bigint, bigint[], text, boolean) is
    'Merge duplicate instructor records into one, reassigning reviews, grades, '
    'aliases, section links and past queue decisions before deleting the '
    'duplicates. Returns needs_confirmation instead of merging when the records '
    'carry different PlanetTerp ratings; pass p_force to override. Grade '
    'matviews are NOT refreshed -- call refresh_grade_matviews() after a batch.';


-- Resolve one queue entry, in one transaction:
--
--   link     the observed spelling belongs to an existing instructor
--   merge    several candidates are one professor: merge them, then link
--   create   it is a professor with no record yet
--   dismiss  it is not a person, or not worth a record
--
-- The alias and the grade rows move together, for the same reason as
-- override_instructor_match(). Returns what happened so the caller can report
-- it rather than guess.
create function resolve_instructor_match(
    p_queue_id      bigint,
    p_action        text,
    p_instructor_id bigint  default null,
    p_actor         text    default null,
    p_merge_ids     bigint[] default null,
    p_force         boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    entry        instructor_match_queue%rowtype;
    target       bigint;
    moved        bigint := 0;
    created_slug text;
    merge_result jsonb;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'p_actor is required: a decision has to name who made it';
    end if;
    if p_actor in ('backfill', 'scraper', 'auto') then
        raise exception 'p_actor % is reserved for automated resolution', p_actor;
    end if;

    select * into entry from instructor_match_queue where id = p_queue_id;
    if not found then
        raise exception 'no queue entry %', p_queue_id;
    end if;
    if entry.resolved_at is not null then
        -- Idempotent rather than an error: two moderators with the queue open
        -- is normal, and the second one losing their click to an exception
        -- teaches them to distrust the screen.
        return jsonb_build_object('status', 'already_resolved',
                                  'resolved_by', entry.resolved_by,
                                  'resolved_to', entry.resolved_to);
    end if;

    if p_action = 'dismiss' then
        update instructor_match_queue
           set resolved_at = now(), resolved_by = p_actor, resolved_to = null
         where id = p_queue_id;
        return jsonb_build_object('status', 'dismissed', 'moved_grade_rows', 0);

    elsif p_action = 'create' then
        insert into instructors (name, slug, first_seen_term, last_seen_term, is_active)
        values (entry.observed,
                next_instructor_slug(entry.observed),
                (entry.context->>'term')::int,
                (entry.context->>'term')::int,
                false)
        returning id, slug into target, created_slug;

    elsif p_action = 'link' then
        if p_instructor_id is null then
            raise exception 'link requires p_instructor_id';
        end if;
        if not exists (select 1 from instructors where id = p_instructor_id) then
            raise exception 'no instructor with id %', p_instructor_id;
        end if;
        target := p_instructor_id;

    elsif p_action = 'merge' then
        -- The moderator recognised several candidates as one professor. Fold
        -- them together first, then link the observed spelling to whatever
        -- survived, in this same transaction -- a merge that commits without
        -- the link leaves the queue entry open and pointing at ids that no
        -- longer exist, which is a worse queue than the one they started with.
        if p_instructor_id is null then
            raise exception 'merge requires p_instructor_id: the record to keep';
        end if;

        merge_result := merge_instructors(p_instructor_id, p_merge_ids, p_actor, p_force);

        -- Not merged, and deliberately so. Returned straight through with the
        -- queue entry untouched, so the moderator can confirm and retry.
        if merge_result->>'status' = 'needs_confirmation' then
            return merge_result;
        end if;

        target := p_instructor_id;

    else
        raise exception 'p_action must be link, merge, create, or dismiss (got %)', p_action;
    end if;

    -- Alias first, so the next scrape resolves this spelling the same way.
    insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
    values (entry.observed_norm, entry.observed, target, 'manual', 1.0)
    on conflict (alias_norm)
    do update set instructor_id = excluded.instructor_id,
                  source        = 'manual',
                  confidence    = 1.0;

    -- Then the grade rows carrying any spelling that normalises to this one.
    update grades
       set instructor_id = target
     where normalize_name(instructor_name) = entry.observed_norm
       and instructor_id is distinct from target;
    get diagnostics moved = row_count;

    update instructor_match_queue
       set resolved_at = now(), resolved_by = p_actor, resolved_to = target
     where id = p_queue_id;

    return jsonb_build_object(
        'status',           case p_action
                                when 'create' then 'created'
                                when 'merge'  then 'merged'
                                else 'linked'
                            end,
        'instructor_id',    target,
        'slug',             coalesce(created_slug, (select slug from instructors where id = target)),
        -- Grade rows this queue entry's own spelling moved. The merge moved its
        -- own, counted separately under `merge`.
        'moved_grade_rows', moved,
        'merge',            merge_result
    );
end;
$$;

comment on function resolve_instructor_match(bigint, text, bigint, text, bigint[], boolean) is
    'Resolve one instructor_match_queue entry: link to an existing instructor, '
    'merge several duplicate records and link to the survivor, create a new '
    'one, or dismiss. Moves the alias and the grade rows together. Matviews are '
    'NOT refreshed -- call refresh_grade_matviews() after a batch.';


/* ============================ scrape writers ============================ */

-- Set is_active for a whole scrape in one statement, so a reader sees the
-- previous scrape's set or this one's and never neither. A clear-then-set over
-- several requests left a window in which a cached empty list could be pinned
-- for a day.
--
-- An empty id list means resolution produced nothing -- Testudo changed shape,
-- the term was wrong -- and the right response is to keep the previous answer,
-- not to deactivate everyone. SECURITY DEFINER because it writes `instructors`,
-- which anon and authenticated cannot.
create function set_active_instructors(
    p_ids       bigint[],
    p_seen_term int default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    affected int;
begin
    -- Refusing an empty set is a safety property, not an optimisation.
    --
    -- Every caller reaches this after resolving the names in a scrape. An
    -- empty array means the resolution step produced nothing -- Testudo
    -- changed shape, the term was wrong, the request failed -- and the correct
    -- response to that is to leave the previous scrape's answer in place, not
    -- to mark all 15,000 instructors inactive because this run learned
    -- nothing. The Python guard that used to do this is kept as well; this is
    -- the one that cannot be forgotten by a new caller.
    if p_ids is null or cardinality(p_ids) = 0 then
        raise exception 'set_active_instructors called with no ids; refusing to '
            'deactivate every instructor on the strength of an empty scrape';
    end if;

    update instructors i
       set is_active      = (i.id = any(p_ids)),
           last_seen_term = case
               when i.id = any(p_ids) and p_seen_term is not null then p_seen_term
               else i.last_seen_term
           end,
           updated_at     = now()
     where i.is_active is distinct from (i.id = any(p_ids))
        or (i.id = any(p_ids)
            and p_seen_term is not null
            and i.last_seen_term is distinct from p_seen_term);

    get diagnostics affected = row_count;
    return affected;
end;
$$;

comment on function set_active_instructors(bigint[], int) is
    'Set is_active for every instructor in one statement, from the id list a '
    'scrape resolved. Atomic: there is no moment at which no instructor is '
    'active. Refuses an empty list.';


-- Replace section_instructors from the staging table in one transaction.
-- Refuses an empty staging table for the same reason set_active_instructors()
-- refuses an empty list.
create function swap_section_instructors()
returns int
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    staged  int;
    applied int;
begin
    select count(*) into staged from section_instructors_staging;

    -- An empty staging table means the scrape resolved nothing. Replacing the
    -- live table with that would empty `active_instructors` for real and leave
    -- it empty until someone noticed -- the permanent version of the bug this
    -- function exists to fix. The previous scrape's answer is stale; it is not
    -- wrong.
    if staged = 0 then
        raise exception 'swap_section_instructors called with an empty staging table; '
            'refusing to deactivate every instructor on the strength of a scrape '
            'that resolved nothing';
    end if;

    -- One transaction, so no reader observes the gap. Under MVCC a concurrent
    -- select sees either the previous scrape's rows or this one's.
    delete from section_instructors;

    insert into section_instructors (course_code, sec_code, instructor_id)
    select s.course_code, s.sec_code, s.instructor_id
      from section_instructors_staging s;

    get diagnostics applied = row_count;

    -- Left empty rather than dropped, so the next run starts clean even if it
    -- fails partway through uploading.
    truncate section_instructors_staging;

    return applied;
end;
$$;

comment on function swap_section_instructors() is
    'Replace section_instructors with the contents of the staging table in one '
    'transaction. Refuses an empty staging table.';


-- Recompute sections.instructor_slugs wholesale. `sections` is a single-term
-- snapshot of ~8,500 rows, so a full recompute is cheap and cannot drift the
-- way an incremental one can. Called by reconcile_instructors() after it has
-- resolved a scrape's names; a scrape that fails before this leaves the column
-- null, which the API renders as unlinked rather than as an error.
create function refresh_section_instructor_slugs()
returns bigint
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    touched bigint;
begin
    with resolved as (
        select s.course_code,
               s.sec_code,
               (
                   select array_agg(i.slug order by u.ord)
                   from unnest(s.instructors) with ordinality as u(nm, ord)
                   left join instructor_aliases a on a.alias_norm = normalize_name(u.nm)
                   left join instructors i on i.id = a.instructor_id
               ) as slugs
        from sections s
    )
    update sections s
       set instructor_slugs = r.slugs
      from resolved r
     where r.course_code = s.course_code
       and r.sec_code = s.sec_code
       and s.instructor_slugs is distinct from r.slugs;

    get diagnostics touched = row_count;
    return touched;
end;
$$;

comment on function refresh_section_instructor_slugs is
    'Recompute sections.instructor_slugs from instructor_aliases. Run after '
    'every section scrape, once instructor reconciliation has finished.';


-- Refresh every grade matview and stamp the ingests it covers. Called after
-- each grade ingest and after any change to grades.instructor_id.
--
-- A function, not a procedure, because PostgREST exposes only functions; and
-- REFRESH ... CONCURRENTLY is allowed inside one. SECURITY DEFINER because
-- refresh is gated on ownership, which no grant can confer on service_role,
-- with search_path pinned so a caller cannot substitute their own relation.
create function refresh_grade_matviews()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    started timestamptz := clock_timestamp();
    elapsed int;
begin
    refresh materialized view concurrently course_instructor_grades;
    refresh materialized view concurrently instructor_grades;
    refresh materialized view concurrently grade_terms;

    elapsed := (extract(epoch from (clock_timestamp() - started)) * 1000)::int;

    -- Every ingest not yet covered by a refresh is now covered by this one.
    update grade_ingests
       set matviews_refreshed_at = now(),
           matview_refresh_ms    = elapsed
     where matviews_refreshed_at is null;
end;
$$;

comment on function refresh_grade_matviews is
    'Refreshes the grade matviews (course_instructor_grades, instructor_grades, '
    'grade_terms) and stamps grade_ingests.matviews_refreshed_at. SECURITY '
    'DEFINER because refresh is gated on ownership and the callers run as '
    'service_role. A function, not a procedure, so PostgREST can call it.';


/* ========================== row level security ========================== */

-- The API proxies PostgREST with the anon key, so whatever anon can select is
-- public. Grade distributions and instructor records are public records.
alter table grades              enable row level security;
alter table grade_ingests       enable row level security;
alter table instructors         enable row level security;
alter table instructor_aliases  enable row level security;
alter table section_instructors enable row level security;
alter table departments         enable row level security;
alter table sections            enable row level security;

create policy grades_public_read on grades
    for select using (true);

create policy grade_ingests_public_read on grade_ingests
    for select using (true);

drop policy if exists instructors_public_read on instructors;
create policy instructors_public_read on instructors
    for select using (true);

create policy instructor_aliases_public_read on instructor_aliases
    for select using (true);

-- Mirrors data already public in `sections.instructors`.
create policy section_instructors_public_read on section_instructors
    for select using (true);

-- These two had RLS on and no policy, so anon read `[]` from them without an
-- error. `user_data` deliberately gets none: its rows belong to a person, and
-- the right policy depends on authentication that does not exist yet.
drop policy if exists departments_public_read on departments;
create policy departments_public_read on departments
    for select using (true);

drop policy if exists sections_public_read on sections;
create policy sections_public_read on sections
    for select using (true);

-- Enabled with no policy: everything below is denied to anon and authenticated
-- and reached only by service_role, which bypasses RLS.
alter table instructor_match_queue      enable row level security;
alter table section_instructors_staging enable row level security;
alter table reviews                     enable row level security;
alter table review_tokens               enable row level security;
alter table review_reports              enable row level security;
alter table moderation_decisions        enable row level security;
alter table email_outbox                enable row level security;
alter table rate_limit_counters         enable row level security;


/* ================================ grants ================================ */

-- A table with no grant is unreachable whatever its policies say, and the
-- failure is a `200 []` or a `permission denied` long after this ran. Grants
-- are per object, never `on all tables`, because that would hand anon
-- `reviews` and `review_tokens`. service_role is named on reads too: it
-- bypasses RLS, not privileges.
--
-- The revokes are belt and braces. RLS is the backstop, not the perimeter; the
-- API handlers are the perimeter, and this has to hold when one of them is
-- wrong.

-- Every object created above starts from no grants at all.
--
-- Supabase projects normally carry default privileges that hand anon,
-- authenticated and service_role ALL on anything new in `public`. Production
-- has them; the rehearsal clone does not. Left in place they would let anon
-- write `rating_config`, which has no RLS, and update or delete rows through
-- `active_instructors`, `sections_with_instructors` and
-- `instructor_match_queue_detail` -- simple views run as their owner, so the
-- tables' RLS never applies. Revoking first makes the grants below the whole
-- access model on either kind of project.
revoke all
    on table grades, grade_ingests, instructor_aliases, instructor_match_queue,
             section_instructors, section_instructors_staging,
             reviews, review_tokens, review_reports, moderation_decisions,
             email_outbox, rate_limit_counters, rating_config,
             grade_terms, course_instructor_grades, instructor_grades,
             course_grades, course_term_grades, course_instructor_grades_all,
             instructor_term_grades, instructor_course_terms,
             active_instructors, sections_with_instructors, public_reviews,
             rating_sensitivity_sweep, instructor_match_auto_resolved,
             instructor_match_queue_detail
    from anon, authenticated, service_role;

revoke all
    on sequence instructors_id_seq, grade_ingests_id_seq, instructor_match_queue_id_seq,
                email_outbox_id_seq, moderation_decisions_id_seq, review_reports_id_seq
    from anon, authenticated, service_role;

revoke all
    on function normalize_name(text),
                slugify(text),
                is_instructor_denylisted(text),
                name_surname(text),
                name_first(text),
                name_first_last(text),
                umd_gpa(int, int, int, int, int, int, int, int, int, int, int, int, int),
                touch_updated_at(),
                next_instructor_slug(text),
                bump_rate_limit(text, text, interval),
                prune_rate_limits(interval),
                compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric),
                refresh_instructor_ratings(),
                resolve_instructor(text),
                link_instructor(text, text, jsonb, boolean, int),
                unlinked_instructor_names(int, int),
                link_instructors_bulk(jsonb, text, boolean),
                apply_instructor_ids(jsonb),
                override_instructor_match(text, bigint, text),
                merge_instructors(bigint, bigint[], text, boolean),
                resolve_instructor_match(bigint, text, bigint, text, bigint[], boolean),
                set_active_instructors(bigint[], int),
                swap_section_instructors(),
                refresh_section_instructor_slugs(),
                refresh_grade_matviews()
    from anon, authenticated, service_role;

-- Public reads.
grant select on grades        to anon, authenticated;
grant select on grade_ingests to anon, authenticated;

grant select on grade_terms, course_grades, course_term_grades,
                course_instructor_grades, course_instructor_grades_all,
                instructor_grades, instructor_term_grades, instructor_course_terms,
                active_instructors, sections_with_instructors, public_reviews
    to anon, authenticated, service_role;

-- Only the service role writes.
revoke insert, update, delete on grades, instructors, instructor_aliases, section_instructors
    from anon, authenticated;

-- Internal: workflow state, user content, and the expensive sweep.
revoke all on instructor_match_queue, section_instructors_staging,
              reviews, review_tokens, review_reports, moderation_decisions,
              email_outbox, rate_limit_counters, rating_sensitivity_sweep
    from anon, authenticated;

grant select on instructor_match_auto_resolved, instructor_match_queue_detail to service_role;

-- The scraper, the grade loader, the backfill, and the API's write client.
grant select, insert, update, delete
    on grades, grade_ingests, section_instructors, section_instructors_staging,
       instructor_aliases, instructor_match_queue, reviews, review_tokens,
       review_reports, moderation_decisions, email_outbox, rate_limit_counters,
       rating_config
    to service_role;

-- `serial` columns only. Identity columns advance without sequence privileges.
grant usage, select
    on sequence grade_ingests_id_seq, instructor_match_queue_id_seq,
                email_outbox_id_seq, moderation_decisions_id_seq, review_reports_id_seq
    to service_role;


-- Functions are executable by PUBLIC on creation, and PostgREST exposes every
-- one as `POST /rest/v1/rpc/<name>`. For a SECURITY DEFINER routine that is the
-- whole defence gone, so each is locked to its caller here.
--
-- Revoked per function, not `on all functions`, because the three below are
-- load-bearing for anon's reads: umd_gpa runs inside the grade views, and the
-- site searches on the normalized name. Extension functions stay callable for
-- the same reason.
grant execute on function normalize_name(text) to anon, authenticated, service_role;
grant execute on function slugify(text)        to anon, authenticated, service_role;
grant execute on function umd_gpa(int, int, int, int, int, int, int, int, int, int, int, int, int)
    to anon, authenticated, service_role;

revoke execute
    on function next_instructor_slug(text),
                is_instructor_denylisted(text),
                name_surname(text),
                name_first(text),
                name_first_last(text),
                resolve_instructor(text),
                link_instructor(text, text, jsonb, boolean, int),
                link_instructors_bulk(jsonb, text, boolean),
                unlinked_instructor_names(int, int),
                apply_instructor_ids(jsonb),
                override_instructor_match(text, bigint, text),
                merge_instructors(bigint, bigint[], text, boolean),
                resolve_instructor_match(bigint, text, bigint, text, bigint[], boolean),
                compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric),
                refresh_instructor_ratings(),
                bump_rate_limit(text, text, interval),
                refresh_section_instructor_slugs(),
                refresh_grade_matviews()
    from public, anon, authenticated;

grant execute
    on function next_instructor_slug(text),
                is_instructor_denylisted(text),
                name_surname(text),
                name_first(text),
                name_first_last(text),
                resolve_instructor(text),
                link_instructor(text, text, jsonb, boolean, int),
                link_instructors_bulk(jsonb, text, boolean),
                unlinked_instructor_names(int, int),
                apply_instructor_ids(jsonb),
                override_instructor_match(text, bigint, text),
                merge_instructors(bigint, bigint[], text, boolean),
                resolve_instructor_match(bigint, text, bigint, text, bigint[], boolean),
                compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric),
                refresh_instructor_ratings(),
                bump_rate_limit(text, text, interval),
                refresh_section_instructor_slugs(),
                refresh_grade_matviews()
    to service_role;

revoke all
    on function set_active_instructors(bigint[], int),
                swap_section_instructors(),
                prune_rate_limits(interval)
    from public, anon, authenticated;

-- The scrape's two snapshot swaps and the API's hourly sweep. Named here
-- rather than left to default privileges, which a project may not have: without
-- them the scrape fails at the swap.
grant execute
    on function set_active_instructors(bigint[], int),
                swap_section_instructors(),
                prune_rate_limits(interval)
    to service_role;

alter default privileges in schema public
    revoke execute on functions from public;


-- Created in the dashboard, and called nightly on production by the pg_cron job
-- "Refresh active_instructors view". The matview it refreshed is gone, so the
-- job would fail every night and the function would raise on anon's public
-- RPC surface; both go. Guarded, because a project without pg_cron (the clone,
-- a local stack) has no job to remove.
do $$
declare
    job record;
begin
    if to_regclass('cron.job') is null then
        return;
    end if;
    for job in select jobid from cron.job where command ilike '%refresh_active_instructors%' loop
        perform cron.unschedule(job.jobid);
    end loop;
end $$;

drop function if exists refresh_active_instructors();

-- Fail this migration, rather than ship, if anything in `public` is still
-- executable by anon other than the three deliberate helpers, trigger functions
-- (not callable directly), and extension functions. A routine added through the
-- dashboard is how the one above arrived.
do $$
declare
    stragglers text;
begin
    select string_agg(p.proname, ', ' order by p.proname)
      into stragglers
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and has_function_privilege('anon', p.oid, 'EXECUTE')
       -- Deliberately public: pure, side-effect free, and load-bearing for
       -- reads. See the note in 0030.
       and p.proname not in ('normalize_name', 'slugify', 'umd_gpa')
       -- Trigger functions cannot be invoked directly and are not exposed by
       -- PostgREST; their EXECUTE is checked at CREATE TRIGGER time.
       and p.prorettype <> 'pg_catalog.trigger'::regtype
       -- Owned by an extension, not by us.
       and not exists (
           select 1 from pg_depend d
            where d.objid = p.oid
              and d.classid = 'pg_proc'::regclass
              and d.deptype = 'e'
       );

    if stragglers is not null then
        raise exception
            'these public functions are still executable by anon: %. '
            'Add them to the revoke list (or to the deliberate-public list) '
            'before this migration can pass.', stragglers;
    end if;
end;
$$;


/* ========================= one-time data fixes ========================== */

-- Everything above is schema. These rewrite rows production already has, and
-- run last so every table a delete could cascade into exists.

-- Every slug becomes slugify(name). PlanetTerp's slugs came in three unrelated
-- shapes (`abadi_daniel`, `abasi`, `wyss-gallifent`), and this is the last
-- moment it is free: professor pages are not live, so no link points at the
-- old URLs. The old value is in `pt_slug`. Every foreign key references
-- `id`, so this cascades nowhere.
--
-- The whole normalized name, not first+last, which would truncate
-- `justin-wyss-gallifent` to `justin-gallifent` and multiply collisions.
--
-- Parked first: a row's new slug can be another row's current one, and the
-- primary key is not deferrable.
update instructors set slug = 'migrating-' || id;

-- Ties go to the lowest id, so the result is deterministic.
with target as (
    select id,
           case
               when row_number() over (partition by slugify(name) order by id) = 1
                   then slugify(name)
               else slugify(name) || '-' ||
                    row_number() over (partition by slugify(name) order by id)
           end as new_slug
    from instructors
)
update instructors i
   set slug = t.new_slug
  from target t
 where t.id = i.id;

do $$
declare
    bad int;
begin
    select count(*) into bad from instructors where slug like 'migrating-%';
    if bad > 0 then
        raise exception '% instructors still parked; the rename did not complete', bad;
    end if;

    select count(*) into bad
      from instructors
     where slug is distinct from slugify(name)
       and slug !~ ('^' || slugify(name) || '-[0-9]+$');
    if bad > 0 then
        raise exception '% slugs are neither slugify(name) nor a numbered variant', bad;
    end if;
end $$;


-- Duplicate records the rename surfaced as collisions, each checked by hand
-- against the rehearsal clone:
--
--   * `Steven Ault Priscilla Novak`, twice (once with newlines in the name):
--     a co-taught section's two instructors crammed into one cell. Both people
--     already exist as their own records.
--   * `Annie Foster Ahmed` and `Phuong Nguyen Le`: spaced duplicates of the
--     hyphenated `Annie Foster-Ahmed` and `Phuong Nguyen-Le`.
--
-- Matched by name, not by the ids seen on the clone: ids are assigned by the
-- identity column added above, in each database's own row order, so the same id
-- need not be the same person here. Each duplicate is removed only if the
-- record it duplicates exists, and the whole step refuses to run if any of them
-- carries data a delete would cascade into -- they were empty shells on the
-- clone, and anything else is a merge_instructors() decision.
--
-- NOT merged: the two `Douglas Hamilton`s carry different PlanetTerp ratings
-- (2.14 and 4.80), and the two `William Martin`s carry PlanetTerp's own
-- collision suffix. Both are evidence of two people who share a name, and both
-- keep a `-2` slug.
do $$
declare
    doomed bigint[];
begin
    select coalesce(array_agg(d.id order by d.id), '{}')
      into doomed
      from instructors d
     where (d.name_norm = 'steven ault priscilla novak'
            and exists (select 1 from instructors k where k.name_norm = 'steven ault')
            and exists (select 1 from instructors k where k.name_norm = 'priscilla novak'))
        or (d.name = 'Annie Foster Ahmed'
            and exists (select 1 from instructors k where k.name = 'Annie Foster-Ahmed'))
        or (d.name = 'Phuong Nguyen Le'
            and exists (select 1 from instructors k where k.name = 'Phuong Nguyen-Le'));

    if exists (select 1 from grades                 where instructor_id = any(doomed))
       or exists (select 1 from reviews             where instructor_id = any(doomed))
       or exists (select 1 from instructor_aliases  where instructor_id = any(doomed))
       or exists (select 1 from section_instructors where instructor_id = any(doomed))
       or exists (select 1 from instructor_match_queue where resolved_to = any(doomed)) then
        raise exception 'duplicate instructor records % carry data; resolve them '
            'with merge_instructors() rather than deleting them', doomed;
    end if;

    delete from instructors where id = any(doomed);
end $$;

-- A survivor left on a `-2` it no longer needs reads as though a bare slug
-- exists somewhere, and it does not.
update instructors
   set slug = regexp_replace(slug, '-[0-9]+$', '')
 where slug ~ '-[0-9]+$'
   and not exists (
       select 1 from instructors other
        where other.slug = regexp_replace(instructors.slug, '-[0-9]+$', '')
   );

do $$
declare
    dupes int;
begin
    select count(*) into dupes
      from (select slug from instructors group by slug having count(*) > 1) d;
    if dupes > 0 then
        raise exception '% duplicate slugs remain', dupes;
    end if;
end $$;


-- Bring the derived ratings in line with the rows above. Runs again after the
-- PlanetTerp snapshot; until then ratings read as none.
select refresh_instructor_ratings();


-- `sections.instructor_slugs` is deliberately NOT refreshed here. This is the
-- statement that timed out and rolled back the first attempt at this migration
-- (57014, at `select refresh_section_instructor_slugs()`), and it could only
-- ever have been a no-op.
--
-- The column resolves through `instructor_aliases`, which this file creates
-- empty and never backfills: every alias row is written at runtime by
-- link_instructor(). So here every lookup misses, and the call can only write
-- an array of NULLs into all ~8,500 sections -- which is what the `add column`
-- above already left behind.
--
-- The same emptiness is what makes it slow. With no rows and no statistics on
-- `instructor_aliases`, the planner estimates it at the default 560 rows,
-- costs the correlated subquery as though it runs once, and picks a Seq Scan
-- of `instructors` over the `instructors_id_key` lookup. The subquery then
-- runs once per section for the SET and again for the IS DISTINCT FROM guard:
-- 15,000 instructors x 8,500 sections x 2 is ~244M rows scanned, against a
-- statement_timeout it cannot possibly meet. Populated, the same function
-- plans as index lookups and takes ~200ms -- there is nothing to fix in it.
--
-- The scrape calls it once reconciliation has actually resolved the names
-- (instructor_registry.py), which is the first moment it has anything to
-- resolve and the first moment the plan is sane. Until that run lands, a NULL
-- column renders professors unlinked -- the same degraded state the function's
-- own header describes for a scrape that fails before reaching it.
