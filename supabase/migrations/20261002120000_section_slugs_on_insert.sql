-- Fill `sections.instructor_slugs` as part of the insert that creates the rows,
-- from the aliases that already exist.
--
-- `upload_data()` replaces `sections` wholesale -- delete everything, insert the
-- fresh scrape -- and the rows it inserts carry no slugs. They stayed null until
-- reconcile_instructors() finished and called
-- refresh_section_instructor_slugs(), about fifteen seconds later. Any
-- `/v1/courses/withSections` request answered in that window was cached by the
-- API for fifteen minutes with every professor unlinked, and then by browsers
-- for up to fifteen more. Which searches it hit was down to timing: on
-- 2026-10-02 `@"Larry Herman"` rendered as plain text while `cmsc216` linked
-- him, because only the first was fetched mid-scrape.
--
-- Nearly every name in a scrape was resolved by an earlier one, so looking it
-- up here closes the window for all of them. A name seen for the first time has
-- no alias yet and stays null, exactly as before;
-- refresh_section_instructor_slugs() still runs after reconciliation and fills
-- it in. The lookup is that function's.
--
-- Statement-level, over the transition table, rather than BEFORE INSERT per
-- row. Both produce identical slugs for all 7,247 rows of the current term, but
-- the scraper inserts the whole term in one PostgREST request under
-- authenticator's 8s statement_timeout, and a per-row lookup took that insert
-- from 13ms to 2.4s; this takes it to 0.43s. A timeout there would fail the
-- upload outright, which is far worse than the problem being fixed.
--
-- The update is inside the inserting statement, so no reader ever sees these
-- rows without their slugs.
--
-- SECURITY DEFINER because the scraper inserts as service_role, which has no
-- execute on normalize_name() and no read on instructor_aliases.

create function fill_section_instructor_slugs()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
    update sections s
       set instructor_slugs = r.slugs
      from (
        select n.course_code,
               n.sec_code,
               (
                   select array_agg(i.slug order by u.ord)
                   from unnest(n.instructors) with ordinality as u(nm, ord)
                   left join instructor_aliases a on a.alias_norm = normalize_name(u.nm)
                   left join instructors i on i.id = a.instructor_id
               ) as slugs
          from inserted n
         -- A writer that supplies slugs is trusted with them.
         where n.instructor_slugs is null
      ) r
     where s.course_code = r.course_code
       and s.sec_code = r.sec_code
       and r.slugs is not null;
    return null;
end;
$$;

comment on function fill_section_instructor_slugs() is
    'Trigger: resolve newly inserted sections'' instructor names to slugs through '
    'instructor_aliases, within the inserting statement, so a scrape''s rows are '
    'never visible unlinked. Names with no alias yet stay null for '
    'refresh_section_instructor_slugs().';

create trigger sections_fill_instructor_slugs
    after insert on sections
    referencing new table as inserted
    for each statement execute function fill_section_instructor_slugs();

revoke execute on function fill_section_instructor_slugs()
    from public, anon, authenticated;

comment on column sections.instructor_slugs is
    'Jupiterp slug for each name in `instructors`, at the same index; null for a '
    'name not yet resolved. Filled on insert by fill_section_instructor_slugs() '
    'from existing aliases, and recomputed by refresh_section_instructor_slugs() '
    'after each scrape''s reconciliation. Do not write it by hand.';
