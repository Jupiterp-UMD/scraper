-- swap_section_instructors(): give the delete a WHERE clause.
--
-- Supabase loads `pg_safeupdate` into every session PostgREST opens. It rejects
-- a DELETE or UPDATE with no WHERE clause, including one inside a function
-- called over RPC, so the bare `delete from section_instructors` in
-- 20260912200959 failed every scheduled sections run with
--
--     21000: DELETE requires a WHERE clause
--
-- The sections upload and instructor resolution before it had already
-- succeeded. The error rolled the swap back, leaving section_instructors as the
-- previous scrape left it, and reconcile_instructors() died before
-- set_active_instructors() and refresh_section_instructor_slugs() could run.
--
-- psql and `supabase db push` connect as postgres, without the extension, so
-- the statement only ever fails when it is called through the API.
--
-- `where true` satisfies the extension -- it checks that a WHERE clause exists,
-- not what it says -- and deletes the same rows. Do not tidy it away:
-- tests/test_migrations_safeupdate.py fails on any function body without one.
--
-- `create or replace` keeps the function's owner, grants and comment, so the
-- revoke from anon/authenticated and the grant to service_role in
-- 20260912200959 still apply.

create or replace function swap_section_instructors()
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
    --
    -- `where true` is required: PostgREST sessions load pg_safeupdate, which
    -- rejects a DELETE with no WHERE clause. See the head of this file.
    delete from section_instructors where true;

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
