-- Materialize `grade_terms`, which was running against the clock.
--
-- It was a plain view: a full aggregate over every row of `grades`, grouped by
-- term, recomputed on every cache miss to produce 31 rows. That was cheap when
-- `grades` held one term. It now holds 203,579 rows across sixteen years.
--
-- The `anon` role -- which is what every /v0 endpoint authenticates as -- has
-- `statement_timeout = 3s`. The view had reached ~2s through the pooler, and
-- during testing it crossed the line: PostgREST returned 500, the handler
-- passed it through, and /v0/grades/terms failed for the caller. A retry
-- fifteen seconds later took 1.999s and succeeded, which is the whole problem
-- -- it is not broken, it is one bad afternoon away from broken, and it gets
-- closer with every term loaded.
--
--     anon           3s      <- every /v0 request
--     authenticated  8s
--     service_role   unset
--
-- Nothing here is a new idea: `course_instructor_grades` and `instructor_grades`
-- were materialized in 0005 for exactly this reason. `grade_terms` predates
-- them and was simply never revisited, because it stayed fast enough to not
-- draw attention until it wasn't.
--
-- The 5xx is at least not cached -- `writeAndCacheResponse` refuses to store
-- anything >= 500 -- so a timeout produced one bad response rather than a
-- poisoned cache for the whole TTL. That is why this looked intermittent
-- instead of sticky, and why it went unnoticed.

/* =========================== the matview ================================ */

-- Same definition as the view it replaces; only the storage changes.
drop view if exists grade_terms;

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

-- `refresh materialized view concurrently` requires a unique index, and a
-- non-concurrent refresh takes an ACCESS EXCLUSIVE lock that would block every
-- reader for its duration -- turning a slow endpoint into an unavailable one
-- during each ingest. `term` is the group key, so it is already unique.
create unique index grade_terms_term_idx on grade_terms (term);

comment on materialized view grade_terms is
    'Per-term grade totals and GPA. Materialized in 0029: as a plain view this '
    'was a full aggregate over grades on every cache miss, at ~2s against the '
    'anon role''s 3s statement_timeout. Refreshed by refresh_grade_matviews().';

-- 0010 established that nothing SQL-created carries grants by default, and that
-- a missing grant surfaces as `200 []` rather than an error. Re-granted here
-- because dropping the view dropped its grants with it.
grant select on grade_terms to anon, authenticated, service_role;


/* ===================== fold into the existing refresh ==================== */

-- Added to the same function that refreshes the other two, so an ingest cannot
-- refresh some grade aggregates and leave this one stale. A separate refresh
-- call would eventually be forgotten in one of the paths that loads grades.
create or replace function refresh_grade_matviews()
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

-- Populate it now, so the endpoint is correct before anything reads it.
refresh materialized view grade_terms;
