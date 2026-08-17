-- Resolve the duplicate instructor records the slug rename surfaced.
--
-- Rewriting slugs to `first-last` in 0022 produced five collisions. Each was a
-- pair of rows that PlanetTerp had imported separately, and looking at them
-- individually is the only way to tell a genuine duplicate from two people who
-- happen to share a name. Three of the five are removed here; two are
-- deliberately left alone, and why is recorded below so nobody has to redo the
-- reasoning.
--
-- Every row touched here has zero grade rows, zero sections, zero reviews,
-- zero aliases, and nothing in instructor_match_queue pointing at it -- checked
-- before writing this. They are empty PlanetTerp shells, so the merge is a
-- delete rather than a reassignment, and no grade history moves.

/* ================== the malformed co-taught records ===================== */

-- `Steven Ault\n\n\n...\nPriscilla Novak` (#9186) and
-- `Steven Ault Priscilla Novak` (#9185) are two people crammed into one name
-- field, twice -- the registrar wrote both instructors of a co-taught section
-- into a single cell, once with the newlines intact.
--
-- Splitting them into two people requires creating nobody: both already exist
-- as correct records with their own history and ratings.
--
--     Steven Ault      #519   steven-ault      PT 3.50    5 grade rows
--     Priscilla Novak  #9184  priscilla-novak  PT 2.67   20 grade rows
--
-- So the shells are simply removed. Leaving them would publish two professor
-- pages titled with two people's names joined together, both empty, competing
-- with the real pages for the same search traffic.
delete from instructors where id in (9185, 9186);


/* ===================== genuine spelling duplicates ====================== */

-- Same person, imported twice under a spaced and a hyphenated spelling of a
-- compound surname. Neither row carries data, so the hyphenated spelling is
-- kept: it is the form that survives normalization identically either way
-- (`normalize_name` maps the hyphen to a space), and it is the more likely
-- rendering of a compound surname when nothing else distinguishes them.
--
--     Annie Foster Ahmed  (#132)   removed, keeping  Annie Foster-Ahmed (#3898)
--     Phuong Nguyen Le    (#7149)  removed, keeping  Phuong Nguyen-Le   (#9115)
--
-- If registrar data later shows the spaced form is correct, the fix is to
-- rename the surviving row, not to resurrect the deleted one.
delete from instructors where id in (132, 7149);


/* ==================== NOT merged, and why =============================== */

-- Douglas Hamilton  #4951 (pt_slug `hamilton`,        PT rating 2.14)
-- Douglas Hamilton  #4954 (pt_slug `hamilton_douglas`, PT rating 4.80)
--
--   Two different PlanetTerp ratings for the same name is evidence of two
--   different people, not one person recorded twice. Merging them would fuse
--   two professors' reputations into one page, which is the single worst
--   outcome available here and is not reversible from the merged state.
--
-- William Martin    #8044 (pt_slug `martin_william`)
-- William Martin    #8045 (pt_slug `martin_william_1`)
--
--   The `_1` is PlanetTerp's own collision suffix: their import had already
--   decided these were two distinct people. Nothing here contradicts that.
--
-- Both pairs keep their `-2` slug variant from 0022, which is the correct
-- outcome for two people who share a name. Revisit only with evidence from the
-- registrar -- a shared employee id, or grade rows that place them in the same
-- department in overlapping terms.


/* ========================== leftover slugs ============================== */

-- Deleting one side of a collision frees the bare slug, leaving the survivor
-- on a `-2` it no longer needs. `annie-foster-ahmed-2` reads as though there is
-- an `annie-foster-ahmed` somewhere, and there is not.
update instructors
   set slug = regexp_replace(slug, '-[0-9]+$', '')
 where slug ~ '-[0-9]+$'
   and not exists (
       select 1 from instructors other
        where other.slug = regexp_replace(instructors.slug, '-[0-9]+$', '')
   );

do $$
declare
    dupes int;
begin
    select count(*) into dupes
      from (select slug from instructors group by slug having count(*) > 1) d;
    if dupes > 0 then
        raise exception '% duplicate slugs remain', dupes;
    end if;
end $$;
