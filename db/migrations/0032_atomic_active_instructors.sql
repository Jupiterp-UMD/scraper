-- Set `instructors.is_active` for a whole scrape in one statement.
--
-- `_mark_active` in instructor_registry.py did this in two phases: clear the
-- flag for everyone, then set it back in chunks of 500 over six or more
-- separate PostgREST requests. Nothing wrapped that in a transaction, so
-- between the first request and the last there was a window -- seconds to a
-- minute, every nightly run -- in which `active_instructors` was empty and
-- `/v1/instructors?activeOnly=true` correctly returned nothing.
--
-- On its own that is a brief blip. What makes it a day-long outage is the
-- caching either side of it. `instructorsTTL` is twelve hours and the API now
-- sends a matching `Cache-Control`, so the service's own LRU and every browser
-- and CDN in front of it can each hold a response for that long. A single
-- cache miss landing inside the window pins an empty instructor list for up to
-- twenty-four hours: the planner renders every professor unlinked and shows no
-- ratings, and nothing anywhere logs an error, because at the moment it was
-- read the answer was true.
--
-- One statement means there is no observable intermediate state. A reader sees
-- either the previous scrape's set or this one's, never neither.

create or replace function set_active_instructors(
    p_ids       bigint[],
    p_seen_term int default null
)
returns int
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    affected int;
begin
    -- Refusing an empty set is a safety property, not an optimisation.
    --
    -- Every caller reaches this after resolving the names in a scrape. An
    -- empty array means the resolution step produced nothing -- Testudo
    -- changed shape, the term was wrong, the request failed -- and the correct
    -- response to that is to leave the previous scrape's answer in place, not
    -- to mark all 15,000 instructors inactive because this run learned
    -- nothing. The Python guard that used to do this is kept as well; this is
    -- the one that cannot be forgotten by a new caller.
    if p_ids is null or cardinality(p_ids) = 0 then
        raise exception 'set_active_instructors called with no ids; refusing to '
            'deactivate every instructor on the strength of an empty scrape';
    end if;

    update instructors i
       set is_active      = (i.id = any(p_ids)),
           last_seen_term = case
               when i.id = any(p_ids) and p_seen_term is not null then p_seen_term
               else i.last_seen_term
           end,
           updated_at     = now()
     where i.is_active is distinct from (i.id = any(p_ids))
        or (i.id = any(p_ids)
            and p_seen_term is not null
            and i.last_seen_term is distinct from p_seen_term);

    get diagnostics affected = row_count;
    return affected;
end;
$$;

comment on function set_active_instructors(bigint[], int) is
    'Set is_active for every instructor in one statement, from the id list a '
    'scrape resolved. Atomic: there is no moment at which no instructor is '
    'active. Refuses an empty list.';

-- `security definer` because the function writes `instructors`, which anon and
-- authenticated are revoked from in 0006. The scraper calls it with the service
-- role today; definer means that stays true if it is ever called with anything
-- else, and the explicit search_path is what stops the usual definer footgun.
revoke all on function set_active_instructors(bigint[], int) from public, anon, authenticated;
