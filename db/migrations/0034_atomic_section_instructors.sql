-- Swap `section_instructors` in one transaction instead of emptying it first.
--
-- This is the other half of 0032, and the more important half.
--
-- `active_instructors` is a plain view defined as "instructors with at least
-- one row in `section_instructors`" (0003). `_rebuild_section_instructors` in
-- instructor_registry.py deletes that table a chunk of course codes at a time
-- and then inserts the new rows a chunk at a time, across a dozen or more
-- separate PostgREST requests with no transaction around them. For the length
-- of that sequence, `active_instructors` is missing everyone whose sections
-- have been deleted and not yet re-inserted -- and briefly, between the last
-- delete and the first insert, it is empty.
--
-- `/v1/instructors/active` reads that view, the course planner reads that
-- endpoint on every page load to build its ratings lookup, and the response is
-- cached for twelve hours by the API and twelve more by the browser. One cache
-- miss inside the window pins a truncated or empty professor list for up to a
-- day. Nothing errors: at the instant it was read, the answer was accurate.
--
-- Fixing 0032's `is_active` flag alone would not have fixed this, because this
-- view does not consult that flag at all.
--
-- The rows still arrive in chunks -- PostgREST rejects very large bodies, and a
-- failed chunk should be identifiable -- but they arrive into a staging table
-- nothing reads. The visible switch is one statement.

create unlogged table if not exists section_instructors_staging (
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

-- Nothing but the service role touches it, and it is not published data.
alter table section_instructors_staging enable row level security;
revoke all on table section_instructors_staging from anon, authenticated;


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

revoke all on function swap_section_instructors() from public, anon, authenticated;
