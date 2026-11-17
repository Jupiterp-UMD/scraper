-- Replace the scraped catalog -- departments, courses, sections -- in one
-- transaction, so no reader ever sees it half-written.
--
-- The scraper used to replace each table with two PostgREST calls: delete every
-- row, then insert the fresh scrape. Between the two the table was empty, and
-- the API caches what it reads. On 2026-11-17 a `/v1/deptList` request landed
-- at 20:19:15 UTC, inside the 20:09 run's upload, and cached `[]` for two
-- hours. The site matches search input against that list, so every course
-- search on jupiterp.com returned nothing until the API was restarted.
--
-- Courses and sections had the same window, and a worse one: `sections`
-- references `courses` with `on delete cascade`, so deleting every course also
-- emptied `sections` until the sections insert landed. A
-- `/v1/courses/withSections` request in that gap cached courses with no
-- sections for two hours.
--
-- Inside one function call all of it is a single statement, so readers see the
-- old catalog until commit and the new one after, with nothing in between.
--
-- Each argument is optional; null leaves that table untouched, which is what a
-- sections-only run passes for the other two. An empty array is refused rather
-- than written: no real scrape yields zero departments, courses or sections,
-- and replacing the catalog with nothing is exactly the outage this prevents.
--
-- departments and sections are deleted and reinserted. Sections must be
-- inserted, not upserted: sections_fill_instructor_slugs() is an AFTER INSERT
-- statement trigger over the inserted rows, and an upsert's updated rows would
-- reach neither it nor carry their slugs across.
--
-- courses are upserted and only the courses that disappeared are deleted, so
-- the cascade removes just their sections. Deleting every course would also
-- empty `sections` for a run that does not replace them (`--courses` alone).
--
-- `where true` on the deletes: Supabase loads pg_safeupdate into every
-- PostgREST session, and it rejects a DELETE with no WHERE clause even inside a
-- function (see tests/test_migrations_safeupdate.py).
--
-- The whole call runs under authenticator's 8s statement_timeout. The work is
-- the same three bulk writes the scraper already made as separate requests;
-- the sections insert and its slug trigger were measured at 0.43s on the
-- current term in 20261002120000_section_slugs_on_insert.sql.
--
-- SECURITY INVOKER: the scraper calls this as service_role, which already has
-- delete and insert on all three tables.

create function replace_catalog(
    p_departments jsonb default null,
    p_courses     jsonb default null,
    p_sections    jsonb default null
)
returns void
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
    if p_departments is not null
       and (jsonb_typeof(p_departments) <> 'array' or jsonb_array_length(p_departments) = 0) then
        raise exception 'replace_catalog: p_departments must be a non-empty array';
    end if;
    if p_courses is not null
       and (jsonb_typeof(p_courses) <> 'array' or jsonb_array_length(p_courses) = 0) then
        raise exception 'replace_catalog: p_courses must be a non-empty array';
    end if;
    if p_sections is not null
       and (jsonb_typeof(p_sections) <> 'array' or jsonb_array_length(p_sections) = 0) then
        raise exception 'replace_catalog: p_sections must be a non-empty array';
    end if;

    if p_departments is not null then
        delete from departments where true;
        insert into departments
        select * from jsonb_populate_recordset(null::departments, p_departments);
    end if;

    if p_courses is not null then
        insert into courses
        select * from jsonb_populate_recordset(null::courses, p_courses)
        on conflict (course_code) do update
           set name        = excluded.name,
               min_credits = excluded.min_credits,
               max_credits = excluded.max_credits,
               gen_eds     = excluded.gen_eds,
               conditions  = excluded.conditions,
               description = excluded.description;

        delete from courses c
         where not exists (
             select 1
               from jsonb_populate_recordset(null::courses, p_courses) n
              where n.course_code = c.course_code
         );
    end if;

    if p_sections is not null then
        delete from sections where true;
        insert into sections
        select * from jsonb_populate_recordset(null::sections, p_sections);
    end if;
end;
$$;

comment on function replace_catalog(jsonb, jsonb, jsonb) is
    'Replace departments, courses and sections from a scrape in one transaction, '
    'so readers never see an empty or half-written catalog. Null leaves a table '
    'as it is; an empty array is refused.';

revoke execute on function replace_catalog(jsonb, jsonb, jsonb)
    from public, anon, authenticated;
grant execute on function replace_catalog(jsonb, jsonb, jsonb)
    to service_role;
