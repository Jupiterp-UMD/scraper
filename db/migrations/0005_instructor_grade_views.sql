-- Instructor grade rollups, keyed on `instructor_id` rather than on a name
-- string, plus the two rollups a professor page needs and that nothing serves
-- today.
--
-- `instructor_grades` and `course_instructor_grades` are MATERIALIZED. Grade
-- data changes once per term, so the usual staleness objection barely applies,
-- and the read pattern — an aggregate over ~210k rows on every professor page
-- load — is the worst case for recomputing a plain view. Both carry the unique
-- index that `refresh materialized view concurrently` requires; without it the
-- refresh takes an exclusive lock and the site stalls behind each ingest.
--
-- `grades` itself is never materialized.

-- The default aggregates count attributions the export supports, plus Testudo's
-- scheduled instructor where the registrar left the field blank. The `course`
-- tier — carried across lecture groups or into a differently-coded offering —
-- is demonstrably wrong sometimes (MATH113 in Fall 2019 names Darcy Conant on
-- FC05/FC06 while leaving FC01-FC04 blank) and is excluded by default. The
-- `_all` views include it, behind `includeCarried=true`.


/* ==================== course x instructor (default) ===================== */

-- Was a plain view keyed on `instructor_name`. Both properties change here.
drop view if exists course_instructor_grades;
drop materialized view if exists course_instructor_grades;

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

-- Required for `refresh ... concurrently`.
create unique index if not exists course_instructor_grades_key
    on course_instructor_grades (course_code, instructor_id);
create index if not exists course_instructor_grades_instructor_idx
    on course_instructor_grades (instructor_id);
create index if not exists course_instructor_grades_slug_idx
    on course_instructor_grades (instructor_slug);


/* ====================== course x instructor (all) ======================= */

-- Wider coverage, lower confidence. Left as a plain view: it is served only
-- behind an explicit opt-in, so it does not carry professor-page traffic.
drop view if exists course_instructor_grades_all;

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


/* ========================= instructor overall =========================== */

-- One row per instructor across every course they have taught. This is the
-- professor page's headline number — "3.12 average GPA across 6 courses" —
-- and nothing in the database produces it today.
drop materialized view if exists instructor_grades;

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

create unique index if not exists instructor_grades_key
    on instructor_grades (instructor_id);
create index if not exists instructor_grades_slug_idx
    on instructor_grades (instructor_slug);
-- Sorting the professor directory by GPA.
create index if not exists instructor_grades_gpa_idx
    on instructor_grades (gpa desc nulls last);


/* ======================= instructor x term ============================== */

-- Powers the "is this professor getting harsher?" trend chart. Left as a plain
-- view: it is a much narrower scan than the overall rollup because it is
-- always filtered to one instructor, and materializing it would multiply the
-- refresh cost by the number of terms for no measured benefit.
drop view if exists instructor_term_grades;

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


/* ===================== instructor course listing ======================== */

-- Which courses a professor taught in which terms, without the fifteen grade
-- buckets. Feeds the professor page's course filter chips, which otherwise
-- would have to pull full distributions just to know what to offer.
drop view if exists instructor_course_terms;

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


/* ============================== refresh ================================= */

-- Called at the end of every ingest, after the instructor_id backfill.
--
-- `concurrently` keeps reads served from the old contents while the new ones
-- are built, which is why both matviews carry a unique index. It cannot run
-- inside a transaction block, so this is a procedure rather than a function
-- and the ingest job calls it with CALL.
create or replace procedure refresh_grade_matviews()
language plpgsql
as $$
begin
    refresh materialized view concurrently course_instructor_grades;
    refresh materialized view concurrently instructor_grades;
end;
$$;

comment on procedure refresh_grade_matviews() is
    'Run after every grade ingest AND after any instructor merge/split. A '
    'matview that is never refreshed has no symptom: the site serves stale '
    'numbers and looks healthy.';
