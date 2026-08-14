-- The instructor resolution algorithm.
--
-- This lives in SQL and nowhere else. The backfill over sixteen years of grade
-- data and the nightly Testudo section scrape both call it, and the one thing
-- that must never happen is the two disagreeing: a name resolved one way by
-- the backfill and another way by the scraper produces a duplicate instructor
-- whose grade history is split across two professor pages.
--
-- Python calls these through PostgREST rpc(); see instructor_registry.py.

/* ============================== denylist ================================ */

-- Testudo emits these where a real instructor has not been assigned. They must
-- never become instructor records. Checked after normalization, so
-- "Instructor: TBA", "INSTRUCTOR: TBA" and "instructor tba" all collapse to
-- the same entry.
create or replace function is_instructor_denylisted(raw text)
returns boolean
language sql
immutable
parallel safe
set search_path = public, extensions, pg_catalog
as $$
    select normalize_name(raw) is null
        or normalize_name(raw) in (
            'tba', 'tbd', 'staff', 'instructor', 'instructor tba',
            'instructor tbd', 'instructor staff', 'no instructor',
            'unknown', 'not assigned', 'to be announced', 'to be determined'
        )
$$;


/* ============================ name helpers ============================== */

-- Surname is the last whitespace-separated token of a normalized name.
--
-- This is wrong for compound surnames ("garcia lopez", "van der berg"), which
-- is a known and accepted limitation: it makes the resolver *more*
-- conservative, not less, because a mismatched surname sends the name to the
-- match queue instead of linking it to the wrong person.
create or replace function name_surname(norm text)
returns text
language sql
immutable
strict
parallel safe
as $$
    select (regexp_split_to_array(norm, ' '))[array_length(regexp_split_to_array(norm, ' '), 1)]
$$;

create or replace function name_first(norm text)
returns text
language sql
immutable
strict
parallel safe
as $$
    select (regexp_split_to_array(norm, ' '))[1]
$$;

-- "shane bolles walsh" -> "shane walsh". Middle names and initials appear
-- throughout the registrar exports and almost never in Testudo, so this is the
-- single highest-yield matching step.
create or replace function name_first_last(norm text)
returns text
language sql
immutable
strict
parallel safe
as $$
    select case
        when array_length(regexp_split_to_array(norm, ' '), 1) < 2 then norm
        else name_first(norm) || ' ' || name_surname(norm)
    end
$$;


/* ============================== resolver ================================ */

-- Find the instructor a name refers to. Read-only; writes nothing.
--
-- Steps run in order and the first that produces exactly ONE candidate wins.
-- A step that produces two or more candidates stops the search and returns
-- nothing, with those candidates reported so a human can choose — it does not
-- fall through to a fuzzier step, because a fuzzier step cannot possibly
-- resolve an ambiguity that a stricter one could not.
--
--   1.0   exact alias hit
--   0.9   first + last, middle names dropped
--   0.7   first initial + last
--   sim   trigram similarity >= 0.85, within the same surname only
--
-- Steps 2-4 never match across surnames. That rule is what keeps "David Levin"
-- from ever being linked to "David Levine".
create or replace function resolve_instructor(observed text)
returns table (instructor_id bigint, confidence real, method text, candidates bigint[])
language plpgsql
stable
set search_path = public, extensions, pg_catalog
as $$
declare
    norm     text := normalize_name(observed);
    surname  text;
    initial  text;
    matches  bigint[];
begin
    if norm is null or is_instructor_denylisted(observed) then
        return;
    end if;

    -- 1. Exact alias hit.
    select array_agg(a.instructor_id)
      into matches
      from instructor_aliases a
     where a.alias_norm = norm;

    if array_length(matches, 1) = 1 then
        return query select matches[1], 1.0::real, 'exact'::text, matches;
        return;
    elsif array_length(matches, 1) > 1 then
        -- Two instructors claiming the same spelling is a data error, not an
        -- ambiguity to resolve automatically.
        return query select null::bigint, null::real, 'ambiguous_alias'::text, matches;
        return;
    end if;

    surname := name_surname(norm);

    -- 2. First + last, middles dropped, within this surname.
    select array_agg(distinct id)
      into matches
      from (
          select i.id
            from instructors i
           where i.name_norm is not null
             and name_surname(i.name_norm) = surname
             and name_first_last(i.name_norm) = name_first_last(norm)
           union
          select a.instructor_id
            from instructor_aliases a
           where name_surname(a.alias_norm) = surname
             and name_first_last(a.alias_norm) = name_first_last(norm)
      ) s;

    if array_length(matches, 1) = 1 then
        return query select matches[1], 0.9::real, 'first_last'::text, matches;
        return;
    elsif array_length(matches, 1) > 1 then
        return query select null::bigint, null::real, 'ambiguous_first_last'::text, matches;
        return;
    end if;

    -- 3. First initial + last. "s walsh" matches "shane walsh" only if it is
    --    the only Walsh whose first name starts with s.
    initial := left(name_first(norm), 1);

    select array_agg(distinct id)
      into matches
      from (
          select i.id
            from instructors i
           where i.name_norm is not null
             and name_surname(i.name_norm) = surname
             and left(name_first(i.name_norm), 1) = initial
           union
          select a.instructor_id
            from instructor_aliases a
           where name_surname(a.alias_norm) = surname
             and left(name_first(a.alias_norm), 1) = initial
      ) s;

    if array_length(matches, 1) = 1 then
        return query select matches[1], 0.7::real, 'first_initial'::text, matches;
        return;
    elsif array_length(matches, 1) > 1 then
        return query select null::bigint, null::real, 'ambiguous_initial'::text, matches;
        return;
    end if;

    -- 4. Trigram similarity, to catch typos and transliteration differences
    --    only. Still confined to an exact surname match, so this can correct
    --    "Steven" vs "Stephen" but never "Levin" vs "Levine".
    return query
    with scored as (
        select i.id,
               similarity(i.name_norm, norm) as sim
          from instructors i
         where i.name_norm is not null
           and name_surname(i.name_norm) = surname
           and similarity(i.name_norm, norm) >= 0.85
    )
    select s.id, s.sim::real, 'trigram'::text, array_agg(s.id) over ()
      from scored s
     order by s.sim desc
     limit 1;
end;
$$;


/* ============================ link or queue ============================= */

-- Resolve a name and record the outcome. This is the only function the
-- scraper and the backfill call.
--
-- On a confident match it writes the alias so the next occurrence is an exact
-- hit, which is what stops the resolver from re-deriving the same fuzzy match
-- thousands of times. On no match or an ambiguity it queues the name and
-- returns null; it never guesses.
--
-- `create_if_missing` is what separates the two callers. The Testudo scrape
-- passes true — a professor teaching a section this term is a real person who
-- should get a record. The grade backfill passes false, because a
-- sixteen-year-old registrar spelling with no current section is exactly the
-- case where a human should confirm before a new professor page appears.
create or replace function link_instructor(
    observed          text,
    source            text,
    context           jsonb   default null,
    create_if_missing boolean default false,
    seen_term         int     default null
)
returns bigint
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare
    norm    text := normalize_name(observed);
    r       record;
    new_id  bigint;
begin
    if norm is null or is_instructor_denylisted(observed) then
        return null;
    end if;

    select * into r from resolve_instructor(observed);

    if r.instructor_id is not null then
        -- Record the spelling so this is an exact hit next time. Append-only:
        -- an existing alias is never repointed here, only by a human merge.
        insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
        values (norm, observed, r.instructor_id, source, r.confidence)
        on conflict (alias_norm) do nothing;

        if seen_term is not null then
            update instructors
               set first_seen_term = least(coalesce(first_seen_term, seen_term), seen_term),
                   last_seen_term  = greatest(coalesce(last_seen_term, seen_term), seen_term)
             where id = r.instructor_id;
        end if;

        return r.instructor_id;
    end if;

    if create_if_missing and r.method is null then
        -- No candidates at all: a genuinely new professor rather than an
        -- ambiguous one. An ambiguity always goes to a human.
        insert into instructors (name, slug, first_seen_term, last_seen_term, is_active)
        values (observed, next_instructor_slug(observed), seen_term, seen_term, true)
        returning id into new_id;

        insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
        values (norm, observed, new_id, source, 1.0)
        on conflict (alias_norm) do nothing;

        return new_id;
    end if;

    -- Unresolved. One open queue row per spelling per source; a name appearing
    -- in 400 sections must not queue 400 identical decisions.
    insert into instructor_match_queue (observed, source, context, candidates)
    values (observed, source, context, r.candidates)
    on conflict (observed_norm, source) where resolved_at is null
    do update set context = coalesce(instructor_match_queue.context, excluded.context);

    return null;
end;
$$;

comment on function link_instructor(text, text, jsonb, boolean, int) is
    'Single entry point for instructor resolution. Called by the Testudo '
    'scrape (create_if_missing => true) and the grade backfill '
    '(create_if_missing => false). Returns null when the name was queued.';
