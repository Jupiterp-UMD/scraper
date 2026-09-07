-- Make the rate limiter a sliding window, and stop it leaking rows.
--
-- Two problems with the original `bump_rate_limit`, one of them arithmetic and
-- one of them design.
--
-- ## The window reset half a second early
--
-- The window start was computed as
--
--     date_trunc('second', now())
--       - (extract(epoch from (now() - date_trunc('day', now())))::bigint
--          % extract(epoch from p_window)::bigint) * interval '1 second'
--
-- `::bigint` on a numeric *rounds*, it does not truncate. So in the last half
-- second of every window the seconds-since-midnight figure rounds up to the
-- next window boundary, the modulo comes out zero, and the expression returns
-- `now()` itself -- a brand new bucket with a count of one, half a second
-- before the window was due to roll. Every limiter in the system had a small
-- hole in it at the top of each hour.
--
-- ## Fixed windows allow a double burst
--
-- Even with the arithmetic right, aligning buckets to midnight means the count
-- resets on a clock rather than relative to the caller. Five submissions at
-- 10:59 and five more at 11:01 are ten in two minutes against a stated limit of
-- five an hour. That is standard fixed-window behaviour and it is not what the
-- comments on `limitPerIP` and `limitPerInstructor` describe -- the
-- per-instructor limit exists to catch brigading, which is precisely a burst.
--
-- ## What this does instead
--
-- Sub-buckets at a tenth of the window, and the count is the sum over the
-- trailing window rather than the value of one bucket. That is the usual
-- sliding-window-counter approximation: accurate to within one sub-bucket,
-- bounded at ten rows per caller per window instead of one, and still a single
-- round trip.
--
-- Windows are aligned to the Unix epoch rather than to local midnight, which
-- for the 1h and 24h windows in use is the same alignment with none of the
-- double rounding.

create or replace function bump_rate_limit(
    p_bucket text,
    p_action text,
    p_window interval
)
returns int
language plpgsql
as $$
declare
    -- floor(), not a bare cast. See above.
    win_secs bigint := greatest(floor(extract(epoch from p_window))::bigint, 1);
    step     bigint := greatest(win_secs / 10, 1);
    now_secs bigint := floor(extract(epoch from now()))::bigint;
    slot     timestamptz := to_timestamp(now_secs - (now_secs % step));
    total    int;
begin
    -- The increment still happens first and in the same statement that
    -- conflicts, so two concurrent submissions contend on the same row: the
    -- second blocks on the first's lock and reads the committed value after it
    -- commits. Neither can observe a count below the limit and proceed.
    insert into rate_limit_counters (bucket, action, window_start, count)
    values (p_bucket, p_action, slot, 1)
    on conflict (bucket, action, window_start)
    do update set count = rate_limit_counters.count + 1;

    -- Served entirely by the primary key, which leads on (bucket, action).
    select coalesce(sum(c.count), 0)::int
      into total
      from rate_limit_counters c
     where c.bucket = p_bucket
       and c.action = p_action
       and c.window_start > to_timestamp(now_secs - win_secs)
       and c.window_start <= slot;

    return total;
end;
$$;

comment on function bump_rate_limit(text, text, interval) is
    'Increment a caller''s counter and return their count over the trailing '
    'window. Sliding, to within a tenth of the window; there is no boundary at '
    'which the count resets.';


-- Nothing ever deleted from this table.
--
-- One row per (caller, action, sub-bucket), forever. It was slow growth and it
-- was never going to be noticed, because the table is only ever read by an
-- indexed lookup on a recent window -- so the query stays fast while the
-- storage, the autovacuum cost and every full backup keep growing. The sweep
-- already runs hourly and is where this belongs.
--
-- The default is well clear of the longest window in use (24 hours, for the
-- per-address limit): nothing older than about 25 hours can still be summed.
create or replace function prune_rate_limits(
    p_older_than interval default interval '48 hours'
)
returns int
language plpgsql
as $$
declare
    removed int;
begin
    delete from rate_limit_counters
     where window_start < now() - p_older_than;

    get diagnostics removed = row_count;
    return removed;
end;
$$;

comment on function prune_rate_limits(interval) is
    'Delete rate-limit counters older than the longest live window. Called by '
    'POST /v1/admin/sweep.';

revoke all on function bump_rate_limit(text, text, interval) from public, anon, authenticated;
revoke all on function prune_rate_limits(interval)           from public, anon, authenticated;
