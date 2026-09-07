-- Rewrite every instructor slug as `first-last`, from the professor's name.
--
-- The table currently holds two conventions at once. 14,016 rows carry slugs
-- inherited from PlanetTerp, in three unrelated shapes -- `abadi_daniel`,
-- `abasi`, `wyss-gallifent` -- while the 1,140 instructors created during this
-- migration got `slugify(name)` from next_instructor_slug(), which is already
-- `daniel-abadi`. Which URL a professor gets is therefore decided by whether
-- PlanetTerp happened to know about them, which is not a rule anyone would
-- choose.
--
-- This is the last moment it is free. `slugify`'s own docstring says the format
-- is frozen once professor pages are indexed, because changing it breaks every
-- shared link -- but the pages are not live yet, so nothing points at the old
-- URLs.
--
-- FORMAT. `slugify(name)`: the whole normalized name, hyphenated. Not
-- `name_first_last`, which keeps only the first and last token and so
-- truncates hyphenated surnames into something wrong:
--
--     Justin Wyss-Gallifent  ->  justin-gallifent      (loses "Wyss")
--     Jamaal Abdul-Alim      ->  jamaal-alim           (loses "Abdul")
--     Hazim Abdullah-Smith   ->  hazim-smith           (loses "Abdullah")
--
-- 1,801 instructors (11.9%) have a middle token, and for those the full-name
-- form keeps it: `sandra-l-saperstein`. That also holds collisions to 5 rather
-- than 77, because middle names are frequently the only thing distinguishing
-- two real people.
--
-- SAFETY. `slug` is the primary key of `instructors`, but every foreign key in
-- the database references `instructors(id)` -- grades, reviews,
-- section_instructors, instructor_aliases, instructor_match_queue -- so
-- rewriting slugs cascades nowhere.
--
-- The old value is not lost: `pt_slug` already holds it for all 14,017 legacy
-- rows (0002 backfilled `pt_slug = slug`), so a redirect map is a query away
-- if one is ever wanted.

/* ===================== pass 1: park every slug ========================== */

-- The rename permutes values inside a unique column: a row's new slug can be
-- another row's current slug. A single UPDATE would trip the primary key
-- mid-statement even though the final state is unique, and the key is not
-- deferrable. Parking everything on a value that cannot collide first makes
-- the second pass conflict-free.
update instructors set slug = 'migrating-' || id;


/* ==================== pass 2: the real slugs ============================ */

-- Ties are broken by id, so the lowest id keeps the bare slug and later ones
-- take -2, -3. Deterministic, and stable if this ever has to be re-derived.
with target as (
    select id,
           case
               when row_number() over (partition by slugify(name) order by id) = 1
                   then slugify(name)
               else slugify(name) || '-' ||
                    row_number() over (partition by slugify(name) order by id)
           end as new_slug
    from instructors
)
update instructors i
   set slug = t.new_slug
  from target t
 where t.id = i.id;


/* ========================= prove it landed ============================== */

do $$
declare
    bad int;
begin
    select count(*) into bad from instructors where slug like 'migrating-%';
    if bad > 0 then
        raise exception '% instructors still parked; the rename did not complete', bad;
    end if;

    select count(*) into bad
      from instructors
     where slug is distinct from slugify(name)
       and slug !~ ('^' || slugify(name) || '-[0-9]+$');
    if bad > 0 then
        raise exception '% slugs are neither slugify(name) nor a numbered variant', bad;
    end if;
end $$;

-- `instructor_grades` and `course_instructor_grades` embed instructor_slug and
-- are now stale. They are refreshed by refresh_grade_matviews() rather than
-- here: a migration should not hold a transaction open across two full matview
-- rebuilds, and the caller has to run it anyway after any instructor change.
