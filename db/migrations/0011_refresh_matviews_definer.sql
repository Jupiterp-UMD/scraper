-- Let the backfill actually refresh the grade matviews.
--
-- `refresh materialized view` is one of the few operations Postgres gates on
-- ownership rather than on a grantable privilege: there is no
-- `grant refresh on ...`, so no addition to 0010 can fix this. The matviews are
-- owned by `postgres`, the backfill authenticates as `service_role`, and the
-- procedure was SECURITY INVOKER -- so `refresh_grade_matviews()` failed with
-- `must be owner of materialized view course_instructor_grades`.
--
-- That failure lands at the very end of the longest step in the migration:
-- scripts/backfill_instructor_ids.py resolves ~210k rows and calls this as its
-- last act (see its refresh at the end of the run). Everything appears to have
-- worked, and the matviews still hold the pre-backfill contents -- every
-- instructor's grade history looking empty while `grades.instructor_id` is
-- fully populated.
--
-- SECURITY DEFINER makes the body run as the owner. `search_path` is pinned
-- because a SECURITY DEFINER routine that resolves object names through the
-- caller's search_path is the standard privilege-escalation shape: the caller
-- creates their own `course_instructor_grades` in a schema earlier on the
-- path and has the definer refresh that instead.

create or replace procedure refresh_grade_matviews()
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    refresh materialized view concurrently course_instructor_grades;
    refresh materialized view concurrently instructor_grades;
end;
$$;

comment on procedure refresh_grade_matviews is
    'Refreshes the grade matviews. SECURITY DEFINER because refresh is gated '
    'on ownership, and the callers (backfill, loader) run as service_role.';
