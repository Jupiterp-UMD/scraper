-- Store the resolved instructor slugs on `sections` instead of deriving them
-- on every request.
--
-- 0024 added `sections_with_instructors`, a view that resolved each section's
-- instructor names to slugs through `instructor_aliases` with a lateral join.
-- Correct, but it re-did that work for every request: a gen-ed search returning
-- 180 courses walks roughly 900 instructor names, calling normalize_name() on
-- each and probing the alias index, and measured ~127ms slower than the same
-- query against the raw table.
--
-- The answer never changes between scrapes. `sections` is a snapshot rebuilt by
-- the scraper, and the aliases it resolves against only change when
-- reconcile_instructors() runs -- in the same command, immediately after. So
-- the slug array can be computed once per scrape and stored.
--
-- The column is nullable and the API tolerates a null array (it renders the
-- professor unlinked), so a scrape that uploads sections and fails before
-- reconciling degrades to the pre-0024 behaviour rather than to an error.

alter table sections
    add column if not exists instructor_slugs text[];

comment on column sections.instructor_slugs is
    'Resolved professor page slug for each entry in `instructors`, positionally '
    'aligned, NULL where unresolved. Maintained by '
    'refresh_section_instructor_slugs(); do not write it by hand.';


/* ===================== the one place that fills it ====================== */

-- Recompute the whole column. Cheap enough to do wholesale -- `sections` is a
-- single-term snapshot of roughly 8,500 rows -- and a full recompute cannot
-- drift the way an incremental update can.
--
-- Called by reconcile_instructors() after it has resolved the scrape's names,
-- and safe to call at any time.
create or replace function refresh_section_instructor_slugs()
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

select refresh_section_instructor_slugs();


/* ===================== the view becomes a passthrough =================== */

-- Kept, rather than dropped and the API repointed at `sections`, so that
-- anything already reading it keeps working. It no longer computes anything.
create or replace view sections_with_instructors as
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
