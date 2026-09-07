-- Public read policies for `departments` and `sections`.
--
-- Both have row-level security enabled and no policy of any kind, which is the
-- quietest possible failure: `anon` holds a SELECT grant, the query is
-- accepted, and it returns zero rows. `/v0/deptList` and `/v0/sections` answer
-- 200 with `[]`. Nothing logs an error, and the site renders an empty course
-- planner rather than a broken one.
--
-- Every sibling table already carries the equivalent policy -- `courses` has
-- "Enable read access for all users" from the dashboard, `instructors` got one
-- in 0006, `grades` in grades/schema.sql -- so these two are an omission
-- rather than a decision.
--
-- Why this was not visible until now: the read path had been exercised with a
-- service-role key, which bypasses RLS entirely. It only appears when the API
-- runs with the anon key it actually holds in production. Worth checking which
-- key `DATABASE_KEY` is in production Secret Manager -- if it is the service
-- key, then RLS is being bypassed on every read there too, and these policies
-- are what let it be switched to anon safely.

alter table departments enable row level security;
alter table sections    enable row level security;

drop policy if exists departments_public_read on departments;
create policy departments_public_read on departments
    for select using (true);

drop policy if exists sections_public_read on sections;
create policy sections_public_read on sections
    for select using (true);

-- `user_data` is deliberately not given one. It is the only table here whose
-- rows belong to a particular person, so "readable by anon" is the wrong
-- default and the right policy depends on how the site authenticates, which is
-- not something this migration should guess at. It currently has RLS on, no
-- policy, and a grant to anon -- so it reads as empty for everyone.
