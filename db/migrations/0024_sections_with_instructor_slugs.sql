-- Give every section its resolved instructor slugs, so nothing has to join on
-- a name.
--
-- `sections.instructors` is the array of names exactly as Testudo prints them.
-- The planner turned each one into a link by looking it up by name in the
-- `/v0/instructors/active` response, which fails whenever the canonical record
-- spells the name differently -- Testudo writes `Aaron Kyei-Asare`, the
-- instructor record says `Aaron Kyei-asare`, and the two never meet. 75
-- scheduled instructors were unlinkable for exactly that reason, each one a
-- professor with a working page that nothing pointed at.
--
-- The resolver already answered this question once. `instructor_aliases` maps
-- every observed spelling to the instructor it was resolved to, which is the
-- authoritative answer and is immune to how Testudo capitalises anything.
--
-- Resolution goes through the aliases rather than through `section_instructors`
-- because alignment matters: `instructors` is an ordered array and the client
-- renders it by index, while `section_instructors` is an unordered set of ids
-- with nothing tying an id back to a position. Walking the array with
-- ORDINALITY keeps slot i of `instructor_slugs` describing slot i of
-- `instructors`.
--
-- Unresolved names stay in the array as NULL rather than being dropped. A
-- shorter array would silently shift every later slug onto the wrong person,
-- which is worse than the missing link this migration exists to fix.
create or replace view sections_with_instructors as
select s.course_code,
       s.sec_code,
       s.instructors,
       s.meetings,
       s.open_seats,
       s.total_seats,
       s.waitlist,
       s.holdfile,
       resolved.instructor_slugs
from sections s
left join lateral (
    select array_agg(i.slug order by u.ord) as instructor_slugs
    from unnest(s.instructors) with ordinality as u(nm, ord)
    left join instructor_aliases a on a.alias_norm = normalize_name(u.nm)
    left join instructors i on i.id = a.instructor_id
) resolved on true;

comment on view sections_with_instructors is
    'sections, plus instructor_slugs: the resolved slug for each name in '
    'instructors, positionally aligned, NULL where the name is unresolved. '
    'Lets clients link a professor without matching on their name.';

grant select on sections_with_instructors to anon, authenticated, service_role;
