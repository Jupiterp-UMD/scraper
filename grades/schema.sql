-- Jupiterp grade distribution schema.
--
-- Run once against the Supabase project (SQL editor, or `psql $DATABASE_URL`).
-- Every statement is idempotent, so re-running after an edit is safe.
--
-- Design notes
-- ------------
-- * One row per (term, course_code, sec_code). That triple is the primary key,
--   which is what makes re-ingesting a file a no-op and makes ingesting a
--   single new term additive: the loader upserts and never deletes.
-- * The fifteen grade buckets are stored exactly as the registrar reported
--   them. Nothing is rebalanced or back-filled.
-- * `graded` and `gpa` are generated columns, so PostgREST can filter and sort
--   on them (`?gpa=gte.3.5&order=gpa.desc`) with no application code.
-- * Aggregates live in views rather than in the API, keeping the Go service the
--   thin proxy it already is.


/* ============================== FUNCTIONS =============================== */

-- GPA on the UMD 4.0 scale.
--
-- Withdrawals and non-letter outcomes are excluded from both the numerator and
-- the denominator, matching how UMD computes a term GPA and how PlanetTerp
-- reports course GPA. A section in which nobody earned a letter grade has no
-- GPA and returns null.
--
-- Marked immutable so it can be used in a generated column and indexed.
create or replace function umd_gpa(
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


/* ================================ TABLES ================================ */

create table if not exists grades (
    -- Six-digit term code, as used elsewhere in Jupiterp: YYYY followed by the
    -- month the term begins (01 spring, 05 summer, 08 fall, 12 winter).
    term        int  not null,

    -- Four letters, three digits, optional trailing letter. Matches
    -- `courses.course_code`, though a course that no longer exists will have
    -- grade rows and no course row.
    course_code text not null,

    -- Normalized to the four-character form used by `sections.sec_code`; the
    -- older exports dropped leading zeros and the loader restores them.
    sec_code    text not null,

    -- Exactly as printed by the registrar, "Last, First Middle". Null for the
    -- ~26% of rows the export left blank, which is the audit trail: any row
    -- where `instructor` is null but `instructor_name` is not was attributed by
    -- carrying the lead section's instructor forward.
    instructor      text,

    -- The effective instructor in "First Middle Last" order, for matching
    -- against `sections.instructors` and `instructors.name`. Populated either
    -- from this row or from the lead section of its lecture; see
    -- `instructor_source` before trusting it.
    instructor_name text,

    -- How `instructor_name` was arrived at:
    --   'reported'  named on this row by the registrar (74% of rows)
    --   'lead'      carried from the lead section of the same lecture group,
    --               ex. 0101 -> 0102. These are that lecture's discussion and
    --               lab sections. (21%)
    --   'course'    carried from elsewhere in the course - a different lecture
    --               group (0101 -> 0201) or a differently-coded offering
    --               (0101 -> FC01). Unreliable: MATH113 in Fall 2019 names
    --               Darcy Conant on FC05 and FC06 while leaving FC01-FC04
    --               blank, so carrying the lecturer into those rows would
    --               misattribute them. Excluded from the default instructor
    --               aggregates. (2%)
    --   null        no section of the course was ever named. (3%)
    instructor_source text
        check (instructor_source in ('reported', 'lead', 'course')),

    -- Enrollment as reported. From Fall 2017 (term 201708) this equals the sum
    -- of the fifteen buckets exactly. In earlier terms it can exceed that sum
    -- by a few students whose outcome the older report did not categorize, so
    -- prefer `graded` as a denominator when comparing across eras.
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

    primary key (term, course_code, sec_code)
);

create index if not exists grades_course_idx      on grades (course_code);
create index if not exists grades_course_term_idx on grades (course_code, term);
create index if not exists grades_term_idx        on grades (term);
create index if not exists grades_instructor_idx  on grades (instructor_name);
create index if not exists grades_instructor_src_idx
    on grades (instructor_name, instructor_source);


-- Provenance: which source file produced which term, and when.
--
-- The loader consults this before doing any work, so re-running it over a
-- directory only touches files it has not already seen. `file_sha256` means an
-- amended file from the registrar is recognized as new even if the name is
-- unchanged.
create table if not exists grade_ingests (
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
    ingested_at timestamptz not null default now()
);

create unique index if not exists grade_ingests_term_hash_idx
    on grade_ingests (term, file_sha256);


/* ================================ VIEWS ================================= */

-- Every term present in the database, newest first.
create or replace view grade_terms as
select
    term,
    count(*)::int              as section_count,
    count(distinct course_code)::int as course_count,
    sum(total)::int            as total,
    sum(graded)::int           as graded,
    umd_gpa(sum(a_plus)::int, sum(a)::int, sum(a_minus)::int,
            sum(b_plus)::int, sum(b)::int, sum(b_minus)::int,
            sum(c_plus)::int, sum(c)::int, sum(c_minus)::int,
            sum(d_plus)::int, sum(d)::int, sum(d_minus)::int,
            sum(f)::int) as gpa
from grades
group by term;


-- One row per course, summed over every section of every term on file.
create or replace view course_grades as
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


-- One row per course per term; the shape a "has this course gotten harder?"
-- chart wants.
create or replace view course_term_grades as
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


-- One row per (course, instructor): "who should I take CMSC132 with?".
--
-- Counts only attributions the export supports: instructors it named, plus the
-- discussion and lab sections of their own lectures. See `instructor_source`.
create or replace view course_instructor_grades as
select
    course_code,
    instructor_name as instructor,
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
where instructor_name is not null
  and instructor_source in ('reported', 'lead')
group by course_code, instructor_name;


-- As above, but also counting sections whose instructor was carried across
-- lecture groups or into a differently-coded offering. Wider coverage, lower
-- confidence; served by `/v0/grades/summary?groupBy=instructor&includeCarried=true`.
create or replace view course_instructor_grades_all as
select
    course_code,
    instructor_name as instructor,
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
where instructor_name is not null
group by course_code, instructor_name;


/* ========================== ROW LEVEL SECURITY =========================== */
-- Grade distributions are public records; reads are open and writes are
-- restricted to the service role the loader runs as. Adjust to match whatever
-- the other Jupiterp tables already do before applying.

alter table grades        enable row level security;
alter table grade_ingests enable row level security;

drop policy if exists grades_public_read on grades;
create policy grades_public_read on grades
    for select using (true);

drop policy if exists grade_ingests_public_read on grade_ingests;
create policy grade_ingests_public_read on grade_ingests
    for select using (true);
