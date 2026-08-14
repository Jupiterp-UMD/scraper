-- `section_instructors`, and `active_instructors` redefined against it.
--
-- IMPORTANT: capture the current definition of `active_instructors` before
-- applying this. It was created in the Supabase dashboard and exists nowhere
-- in version control, so this migration is the point at which the old one
-- becomes unrecoverable.
--
--   psql "$DATABASE_DIRECT_URL" -Atf db/baseline/capture.sql \
--        > db/baseline/current_schema.sql

-- Join table between Testudo sections and resolved instructors.
--
-- `sections.instructors text[]` stays exactly as it is: the API, the npm
-- package, and the site's `Section` type all read it, and removing it is a
-- breaking change that buys nothing. This table is populated alongside it and
-- used for *lookup* — "which instructors are currently teaching" — which the
-- text array cannot answer without a scan and a name match.
create table if not exists section_instructors (
    course_code   text not null,
    sec_code      text not null,
    instructor_id bigint not null references instructors (id) on delete cascade,
    primary key (course_code, sec_code, instructor_id)
);

create index if not exists section_instructors_instructor_idx
    on section_instructors (instructor_id);

comment on table section_instructors is
    'Lookup companion to sections.instructors[]. Rebuilt by '
    'reconcile_instructors() on every section scrape; sections.instructors '
    'remains the primary read path.';


-- Instructors currently teaching something.
--
-- The previous definition matched on name strings against
-- `sections.instructors`, which is exactly the failure mode this whole
-- migration exists to remove: a professor whose Testudo spelling differs from
-- their `instructors.name` spelling silently drops out of the active list.
create or replace view active_instructors as
select i.*
from instructors i
where exists (
    select 1
    from section_instructors si
    where si.instructor_id = i.id
);

comment on view active_instructors is
    'Instructors with at least one section in the current Testudo scrape. '
    'Keyed on instructor_id, not on name matching.';
