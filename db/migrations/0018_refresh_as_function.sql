-- Make refresh_grade_matviews() callable from the application, and make it
-- record that it ran.
--
-- Two separate defects, both silent.
--
-- 1. It was a PROCEDURE. PostgREST exposes functions over RPC and does not
--    expose procedures at all, so the call the backfill and the loader both
--    make could never have worked:
--
--      PGRST202: Could not find the function public.refresh_grade_matviews
--                without parameters in the schema cache
--
--    It ran fine as `call refresh_grade_matviews()` from psql, which is
--    presumably how it was tested. Nothing in Python can issue CALL -- the
--    scraper talks to PostgREST, not to Postgres.
--
--    A function is not a workaround here. The reason to reach for a procedure
--    is transaction control, and this body needs none: REFRESH MATERIALIZED
--    VIEW CONCURRENTLY is permitted inside a transaction (the restriction
--    people remember belongs to CREATE INDEX CONCURRENTLY), so the same two
--    statements work unchanged in a function.
--
-- 2. Nothing ever populated `grade_ingests.matviews_refreshed_at`. 0004 added
--    that column and ci.py fails the build when the newest ingest lacks it,
--    on the correct reasoning that a stale matview has no symptom. But no
--    writer existed, so the column was null on all 31 ingests and the check
--    would have failed every run for a reason unrelated to actual staleness.
--
--    Stamping it here ties the record to the event: a refresh covers every
--    ingest loaded before it, so it closes out all outstanding ones.
--
-- SECURITY DEFINER is retained from 0011 -- refresh is gated on ownership, the
-- callers are service_role, and no grant can substitute.

drop procedure if exists refresh_grade_matviews();

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

    elapsed := (extract(epoch from (clock_timestamp() - started)) * 1000)::int;

    -- Every ingest not yet covered by a refresh is now covered by this one.
    update grade_ingests
       set matviews_refreshed_at = now(),
           matview_refresh_ms    = elapsed
     where matviews_refreshed_at is null;
end;
$$;

comment on function refresh_grade_matviews is
    'Refreshes the grade matviews and stamps grade_ingests.matviews_refreshed_at. '
    'SECURITY DEFINER because refresh is gated on ownership and the callers run '
    'as service_role. A function, not a procedure, so PostgREST can call it.';
