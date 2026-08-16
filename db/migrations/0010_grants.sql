-- Grants for everything created by migrations and by grades/schema.sql.
--
-- This file exists because the project has no default privileges configured:
-- `pg_default_acl` for schema `public` is empty. The tables created through
-- the Supabase dashboard -- courses, sections, departments, instructors,
-- user_data -- carry grants because the dashboard issues them explicitly at
-- creation. Every object created by psql since then carries none.
--
-- A table with no grant is unreachable no matter what its RLS policies say.
-- The two mechanisms compose the other way round from how it reads: the grant
-- decides whether a role may touch the object at all, and the policy then
-- filters which rows it sees. `grades` has a `for select using (true)` policy
-- and was still unreadable by every role, because a policy that filters rows
-- for a role which cannot reach the table filters nothing.
--
-- 0006 and 0008 granted the objects they created and stopped there. The gap is
-- grades/schema.sql, which issues no grants at all, plus the write path for
-- service_role across both migration sets.
--
-- Grants are stated per object rather than as `grant ... on all tables in
-- schema public`, because `all tables` would also hand out `reviews` and
-- `review_tokens`, and 0008's central invariant is that no role except
-- service_role can read an unapproved review or an identity column.

/* ======================== public read surfaces ========================== */
--
-- The API is a proxy in front of PostgREST holding the anon key, so whatever
-- anon can select is effectively public. Grade distributions are public
-- records obtained by MPIA request and stay open, matching the treatment of
-- the instructor and grade objects 0006 already granted.

grant select on grades             to anon, authenticated, service_role;
grant select on grade_terms        to anon, authenticated, service_role;
grant select on course_grades      to anon, authenticated, service_role;
grant select on course_term_grades to anon, authenticated, service_role;

-- service_role appears on the view lines above, and on the ones 0006 and 0008
-- already granted, below. It is easy to leave off on the assumption that a
-- privileged role reads everything by default -- it does not. The grade
-- loader's `terms` command reads `grade_terms` as service_role and fails with
-- `permission denied for view grade_terms` without this.

grant select on course_instructor_grades     to service_role;
grant select on course_instructor_grades_all to service_role;
grant select on instructor_grades            to service_role;
grant select on instructor_term_grades       to service_role;
grant select on instructor_course_terms      to service_role;
grant select on active_instructors           to service_role;
grant select on public_reviews               to service_role;

-- `grade_ingests` is the per-file load log: filename, SHA-256, row count, and
-- `unaccounted_students`. Granted because grades/schema.sql declares
-- `grade_ingests_public_read ... using (true)`, which is an explicit statement
-- that it should be readable; the policy was simply inert without this. It
-- carries no personal data, but it is the one line here that is a judgement
-- call rather than a mechanical consequence -- revoke it if the load history
-- should not be public.
grant select on grade_ingests to anon, authenticated;

/* ========================= service_role writes ========================== */
--
-- service_role is what the scraper, the grade loader, the backfill scripts,
-- and the Go API's write client authenticate as. It bypasses RLS but still
-- needs table privileges like any other role.

-- Grade loading and the instructor backfill.
grant select, insert, update, delete on grades        to service_role;
grant select, insert, update, delete on grade_ingests to service_role;

-- Instructor identity, rebuilt on every section scrape by
-- reconcile_instructors() and read by link_instructor(), which is SECURITY
-- INVOKER and therefore runs with the caller's privileges.
grant select, insert, update, delete on section_instructors    to service_role;
grant select, insert, update, delete on instructor_aliases     to service_role;
grant select, insert, update, delete on instructor_match_queue to service_role;

-- The review write path. anon is deliberately absent from every line here:
-- public reads go through the `public_reviews` view, which 0008 granted and
-- which cannot expose an unapproved row or an identity column.
grant select, insert, update, delete on reviews              to service_role;
grant select, insert, update, delete on review_tokens        to service_role;
grant select, insert, update, delete on review_reports       to service_role;
grant select, insert, update, delete on moderation_decisions to service_role;
grant select, insert, update, delete on email_outbox         to service_role;
grant select, insert, update, delete on rate_limit_counters  to service_role;

-- The rating model's tunable constants, rewritten by the sensitivity sweep.
grant select, insert, update, delete on rating_config to service_role;

/* ============================== sequences =============================== */
--
-- Only the `serial` columns need this. `instructors.id` and `user_data.id` are
-- identity columns, which the system advances without consulting sequence
-- privileges, so they are correctly absent from this list.

grant usage, select on sequence grade_ingests_id_seq           to service_role;
grant usage, select on sequence instructor_match_queue_id_seq  to service_role;
grant usage, select on sequence email_outbox_id_seq            to service_role;
grant usage, select on sequence moderation_decisions_id_seq    to service_role;
grant usage, select on sequence review_reports_id_seq          to service_role;
