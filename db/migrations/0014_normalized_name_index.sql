-- Make unlinked_instructor_names() fast enough to run through PostgREST.
--
-- 0013 moved the distinct-name aggregation into the database, which is the
-- right shape but took ~11s: it computed normalize_name() across every one of
-- the 200k unlinked grade rows, then sorted them to group. Through psql that
-- is merely slow; through PostgREST it exceeded the statement timeout and came
-- back as
--
--     canceling statement due to statement timeout  (57014)
--
-- Both `normalize_name` and `is_instructor_denylisted` are IMMUTABLE, so the
-- expression can be indexed. The index supplies the normalized values already
-- computed and already in order, which removes both the per-row function call
-- and the sort ahead of the grouping.
--
-- Not partial on `instructor_id is null`. That predicate matches almost every
-- row today and almost none once the backfill finishes, so a partial index
-- would be sized for exactly the window in which it stops being needed. The
-- loader resolves instructors on every subsequent ingest and wants this same
-- lookup permanently.
create index if not exists grades_instructor_name_norm_idx
    on grades (normalize_name(instructor_name));

-- A safety net rather than the fix. The index is what makes this fast; the
-- override keeps a one-off aggregation over a much larger `grades` from
-- failing at the transport layer years from now. It applies only for the
-- duration of this function, and only to a batch maintenance path that no
-- user-facing request calls.
alter function unlinked_instructor_names(int, int) set statement_timeout = '120s';
