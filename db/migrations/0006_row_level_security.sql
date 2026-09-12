-- Row-level security and grants for everything added by this migration set.
--
-- The API is a proxy in front of PostgREST holding the anon key, so whatever
-- `anon` can select is effectively public. Grade distributions and instructor
-- records are public records and stay open; the match queue is internal
-- workflow state and is not.

/* ============================ public reads ============================== */

alter table instructors        enable row level security;
alter table instructor_aliases enable row level security;

drop policy if exists instructors_public_read on instructors;
create policy instructors_public_read on instructors
    for select using (true);

drop policy if exists instructor_aliases_public_read on instructor_aliases;
create policy instructor_aliases_public_read on instructor_aliases
    for select using (true);

-- `section_instructors` mirrors data already public in `sections.instructors`.
alter table section_instructors enable row level security;

drop policy if exists section_instructors_public_read on section_instructors;
create policy section_instructors_public_read on section_instructors
    for select using (true);


/* ============================ internal only ============================= */

-- The match queue holds unresolved names with course/term context. Nothing in
-- it is secret, but it is workflow state rather than published data, and an
-- endpoint that lists "names we could not identify" is a needless invitation.
--
-- RLS enabled with no select policy means anon reads return zero rows. The
-- service role bypasses RLS, which is how the scraper and the admin triage
-- surface reach it.
alter table instructor_match_queue enable row level security;

drop policy if exists instructor_match_queue_public_read on instructor_match_queue;

revoke all on instructor_match_queue from anon, authenticated;


/* ========================== materialized views ========================== */

-- Materialized views do not participate in row-level security, so access is
-- controlled purely by grants — and unlike tables, PostgREST will not see them
-- at all without one. Forgetting this is the difference between a working
-- professor page and a 404 from PostgREST that looks like a routing bug.
grant select on course_instructor_grades to anon, authenticated;
grant select on instructor_grades        to anon, authenticated;

-- Plain views run with the privileges of their owner and inherit RLS from the
-- tables underneath, but still need the grant to be reachable.
grant select on course_instructor_grades_all to anon, authenticated;
grant select on instructor_term_grades       to anon, authenticated;
grant select on instructor_course_terms      to anon, authenticated;
grant select on active_instructors           to anon, authenticated;


/* ============================ write paths =============================== */

-- Only the service role writes any of this. Stated explicitly rather than
-- relying on the absence of a policy, because `instructors` is about to gain
-- a foreign key from `reviews` and a stray insert grant there is how user
-- data gets damaged.
revoke insert, update, delete on instructors        from anon, authenticated;
revoke insert, update, delete on instructor_aliases from anon, authenticated;
revoke insert, update, delete on section_instructors from anon, authenticated;
revoke insert, update, delete on grades             from anon, authenticated;
