-- Server-side helpers for scripts/backfill_instructor_ids.py.
--
-- The backfill was making roughly 28,000 HTTP round trips to PostgREST:
--
--   ~201  paging all 200k unlinked grade rows to compute a distinct set of
--         ~14k names in Python
--   13958  one link_instructor() call per distinct name
--   ~14045  one UPDATE per raw spelling to write instructor_id back
--
-- Every one of those is a request, a plan, and a round trip for a few hundred
-- bytes of payload. The work itself is trivial; the transport is the cost.
-- These three functions do the same work set-at-a-time, taking the round trip
-- count to roughly 70.
--
-- The script stays a script. Each function is one bounded batch, so the run is
-- still interruptible and resumable between batches -- which is why the
-- backfill was not written as a migration in the first place.

/* ===================== 1. distinct names, server-side ==================== */

-- Replaces the paged scan. Aggregates in the database and returns one row per
-- normalized name instead of shipping 200k rows to Python to be deduplicated
-- there.
--
-- `variants` is the part that matters for correctness, not just speed. 14,045
-- distinct raw spellings in `grades` collapse to 13,958 normalized names --
-- "Jonathan K. Lazar" and "Jonathan K Lazar" are one person written two ways.
-- The Python collection kept only the first spelling it saw per normalized
-- name, and the write-back matched grade rows on that exact string, so rows
-- carrying any other spelling were never linked. Returning every spelling lets
-- the write-back catch all of them.
--
-- The context columns come from the most recent term the name appears in
-- rather than from whichever row the scan happened to reach first. A current
-- spelling resolves against a current instructor more often.
create or replace function unlinked_instructor_names(
    page_limit  int default 1000,
    page_offset int default 0
)
returns table (
    name_norm         text,
    observed          text,
    variants          text[],
    row_count         bigint,
    course_code       text,
    term              int,
    sec_code          text,
    instructor_source text
)
language sql
stable
set search_path = public, extensions, pg_catalog
as $$
    with kept as (
        select g.instructor_name,
               normalize_name(g.instructor_name) as nn,
               g.course_code, g.term, g.sec_code, g.instructor_source
        from grades g
        where g.instructor_name is not null
          and g.instructor_id is null
          and normalize_name(g.instructor_name) is not null
          and not is_instructor_denylisted(g.instructor_name)
    )
    select nn,
           (array_agg(instructor_name   order by term desc, instructor_name))[1],
           array_agg(distinct instructor_name),
           count(*),
           (array_agg(course_code       order by term desc, instructor_name))[1],
           (array_agg(term              order by term desc, instructor_name))[1],
           (array_agg(sec_code          order by term desc, instructor_name))[1],
           (array_agg(instructor_source order by term desc, instructor_name))[1]
    from kept
    group by nn
    order by nn
    limit page_limit offset page_offset
$$;

comment on function unlinked_instructor_names(int, int) is
    'Distinct unlinked instructor names in grades, with every raw spelling '
    'that normalizes to each. Paged; used by the backfill.';


/* ======================= 2. batched resolution ========================== */

-- One call resolves a whole batch instead of one name per round trip.
--
-- Parameters are prefixed `p_` because link_instructor's are not, and its
-- collision between parameter and column names is what 0012 had to repair.
create or replace function link_instructors_bulk(
    batch               jsonb,
    p_source            text,
    p_create_if_missing boolean default false
)
returns jsonb
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare
    item   jsonb;
    result jsonb := '[]'::jsonb;
    rid    bigint;
begin
    for item in select value from jsonb_array_elements(batch)
    loop
        rid := link_instructor(
            item->>'observed',
            p_source,
            item->'context',
            p_create_if_missing,
            nullif(item->>'seen_term', '')::int
        );

        result := result || jsonb_build_array(jsonb_build_object(
            'name_norm',     item->>'name_norm',
            'instructor_id', rid
        ));
    end loop;

    return result;
end;
$$;

comment on function link_instructors_bulk(jsonb, text, boolean) is
    'Resolve a batch of observed names through link_instructor(). Returns one '
    '{name_norm, instructor_id} per input; instructor_id null means queued.';


/* ====================== 3. batched write-back =========================== */

-- Replaces one UPDATE per spelling with one UPDATE per batch.
--
-- Matches on `instructor_name = any(variants)`, which uses the existing
-- grades_instructor_idx, rather than on a function of the column, which would
-- not.
create or replace function apply_instructor_ids(batch jsonb)
returns bigint
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare
    n bigint;
begin
    with mapping as (
        select (e->>'instructor_id')::bigint as iid,
               array(select jsonb_array_elements_text(e->'variants')) as variants
        from jsonb_array_elements(batch) e
        where e->>'instructor_id' is not null
    )
    update grades g
       set instructor_id = m.iid
      from mapping m
     where g.instructor_id is null
       and g.instructor_name = any(m.variants);

    get diagnostics n = row_count;
    return n;
end;
$$;

comment on function apply_instructor_ids(jsonb) is
    'Write instructor_id onto grade rows for a batch of resolved names, '
    'covering every raw spelling that normalized to each name.';
