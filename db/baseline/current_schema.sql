-- Pre-migration definitions of objects created through the Supabase dashboard.
--
-- PARTIAL CAPTURE. Recovered from the test clone on 2026-08-16, after 0001 and
-- 0002 had already been applied to it, because `capture.sql` was never run
-- against production before migrating began -- and would not have recorded the
-- object below even if it had been: it filtered on relkind = 'v', and
-- `active_instructors` is a materialized view. That filter is fixed now.
--
-- The definition below is unaffected by 0001 and 0002, so it is the genuine
-- pre-migration article. The rest of the baseline (table shapes, indexes,
-- policies) is NOT recorded here. Capture it from production, which is still
-- untouched, before applying any of this there:
--
--   psql "$PROD_DIRECT_URL" -Atf db/baseline/capture.sql \
--        > db/baseline/prod_schema.sql


/* ---------- views ---------- */

-- `active_instructors`, as it existed before 0003 replaced it.
--
-- Materialized, and nothing refreshed it: no pg_cron job existed in the
-- database and no `refresh materialized view` appears anywhere in the scraper
-- or the API. Its contents were therefore as old as the last manual refresh.
--
-- The name-matching join is the failure this migration set exists to remove --
-- an instructor whose Testudo spelling differs from `instructors.name` drops
-- out of the active list silently.
create materialized view active_instructors as
 SELECT DISTINCT i.slug,
    i.name,
    i.average_rating
   FROM instructors i
     JOIN sections s ON i.name = ANY (s.instructors);

-- No indexes existed on it, so it could only ever be refreshed
-- non-concurrently (`refresh materialized view concurrently` requires a unique
-- index), which takes an ACCESS EXCLUSIVE lock and blocks reads for the
-- duration.
