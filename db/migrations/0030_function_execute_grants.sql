-- Close the function half of the grants model.
--
-- 0010 states the rule this migration is applying: "a table with no grant is
-- unreachable no matter what its RLS policies say... the grant is what makes
-- an object reachable." That reasoning was applied carefully to every table,
-- view, and sequence, and never to functions.
--
-- Functions do not behave like tables here. `CREATE FUNCTION` grants EXECUTE to
-- PUBLIC by default, so every routine in this schema has been executable by
-- `anon` since the moment it was created, and PostgREST exposes exactly those
-- routines as `POST /rest/v1/rpc/<name>`. Nothing had to be granted for that to
-- be true, which is why it does not appear anywhere in 0010.
--
-- For SECURITY INVOKER routines this mostly does not matter: the body runs as
-- the caller, so `anon`'s missing table grants still stop the writes. For
-- SECURITY DEFINER routines it matters entirely, because the body runs as the
-- owner and the caller's grants stop nothing:
--
--   resolve_instructor_match  -- merges two professors' identities and moves
--                                their grade rows. 0028's own comment calls
--                                this irreversible.
--   refresh_grade_matviews    -- two CONCURRENTLY refreshes over ~210k rows.
--   refresh_section_instructor_slugs
--                             -- same shape.
--
-- The API guards the merge behind REVIEW_ADMIN_KEY, and that guard was the only
-- thing protecting it. The database-layer backstop the architecture assumes --
-- "RLS is the backstop, not the perimeter" in writeclient.go -- was absent for
-- this whole class of object.
--
-- Revoked per function rather than with `revoke execute on all functions`.
-- A blanket revoke is tempting and is the wrong tool here: `umd_gpa` is
-- evaluated inside `course_grades`, `course_term_grades` and `grade_terms`,
-- which `anon` selects from on ordinary page loads. Revoking it wholesale
-- would turn the public grade endpoints into permission errors, which is a
-- worse outcome than the hole being closed. The list below is therefore
-- explicit about which functions are privileged and which are plumbing.

/* ------------------------- privileged: service_role only ----------------- */

-- SECURITY DEFINER. These run as the owner and ignore the caller's grants
-- entirely, so they are the ones that actually needed this.
revoke execute on function refresh_grade_matviews()           from public, anon, authenticated;
revoke execute on function refresh_section_instructor_slugs() from public, anon, authenticated;
revoke execute on function resolve_instructor_match(bigint, text, bigint, text)
    from public, anon, authenticated;

grant execute on function refresh_grade_matviews()            to service_role;
grant execute on function refresh_section_instructor_slugs()  to service_role;
grant execute on function resolve_instructor_match(bigint, text, bigint, text)
    to service_role;

-- SECURITY INVOKER, but every one of them writes. `anon` holds no INSERT or
-- UPDATE grant on the tables underneath, so these already failed for an
-- anonymous caller -- they failed with a permission error from deep inside a
-- function body rather than at the door, which is a poor place to find out.
-- Revoking makes the refusal explicit and removes them from PostgREST's
-- reachable surface for anon.
revoke execute on function refresh_instructor_ratings()                    from public, anon, authenticated;
revoke execute on function link_instructor(text, text, jsonb, boolean, int) from public, anon, authenticated;
revoke execute on function link_instructors_bulk(jsonb, text, boolean)      from public, anon, authenticated;
revoke execute on function apply_instructor_ids(jsonb)                      from public, anon, authenticated;
revoke execute on function override_instructor_match(text, bigint, text)    from public, anon, authenticated;
revoke execute on function next_instructor_slug(text)                       from public, anon, authenticated;
revoke execute on function resolve_instructor(text)                         from public, anon, authenticated;
revoke execute on function bump_rate_limit(text, text, interval)            from public, anon, authenticated;
revoke execute on function unlinked_instructor_names(int, int)              from public, anon, authenticated;
revoke execute on function compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric)
    from public, anon, authenticated;

grant execute on function refresh_instructor_ratings()                     to service_role;
grant execute on function link_instructor(text, text, jsonb, boolean, int) to service_role;
grant execute on function link_instructors_bulk(jsonb, text, boolean)      to service_role;
grant execute on function apply_instructor_ids(jsonb)                      to service_role;
grant execute on function override_instructor_match(text, bigint, text)    to service_role;
grant execute on function next_instructor_slug(text)                       to service_role;
grant execute on function resolve_instructor(text)                         to service_role;
grant execute on function bump_rate_limit(text, text, interval)            to service_role;
grant execute on function unlinked_instructor_names(int, int)              to service_role;
grant execute on function compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric)
    to service_role;

-- bump_rate_limit deserves a note of its own. It is the counter behind every
-- rate limit on the write path. An anonymous caller able to invoke it directly
-- could exhaust the `instructor:<id>` bucket for a chosen professor and block
-- all reviews of them for an hour -- a denial of service aimed at one person,
-- using the abuse defence as the weapon.

/* --------------------- internal helpers: service_role -------------------- */
--
-- Only ever called from inside the resolver functions above, which run as
-- service_role. No caller outside the database needs them.

revoke execute on function name_first(text)               from public, anon, authenticated;
revoke execute on function name_surname(text)             from public, anon, authenticated;
revoke execute on function name_first_last(text)          from public, anon, authenticated;
revoke execute on function is_instructor_denylisted(text) from public, anon, authenticated;

grant execute on function name_first(text)                to service_role;
grant execute on function name_surname(text)              to service_role;
grant execute on function name_first_last(text)           to service_role;
grant execute on function is_instructor_denylisted(text)  to service_role;

/* ------------------------- deliberately public --------------------------- */
--
-- Pure, side-effect free, and load-bearing for reads.
--
-- normalize_name and slugify: the site normalizes a search term client-side
-- and the API filters on the normalized column, so refusing these would break
-- professor search while protecting nothing. They are also the SQL third of
-- the three-way name contract and are exercised by db/tests/name_parity.sql.
--
-- umd_gpa: evaluated inside the grade views that anon reads. Revoking it
-- breaks /v0/grades and /v1/grades.

grant execute on function normalize_name(text) to anon, authenticated, service_role;
grant execute on function slugify(text)        to anon, authenticated, service_role;
grant execute on function umd_gpa(int, int, int, int, int, int, int, int, int, int, int, int, int)
    to anon, authenticated, service_role;

/* --------------------------- the next function --------------------------- */
--
-- Without this, the next `create function` re-opens exactly the hole this
-- migration closes, and nothing will make that visible. New routines now start
-- with no PUBLIC grant and must name their caller explicitly.
--
-- Default privileges apply per granting role, so this covers functions created
-- by whichever role runs the migrations. If a function is ever created by a
-- different role (a dashboard session, say), repeat this for that role.

alter default privileges in schema public
    revoke execute on functions from public;
