-- Make apply_instructor_ids() plan properly.
--
-- 0013 built the batch as one mapping row per resolved name, carrying that
-- name's spellings as a text[], and matched with
-- `g.instructor_name = any(m.variants)`. That is a correct predicate and an
-- unplannable one: `= any(array)` against a joined array column cannot drive
-- an index lookup on grades_instructor_idx, so a 500-name batch degraded into
-- a scan of `grades` per batch and hit the statement timeout:
--
--     canceling statement due to statement timeout  (57014)
--
-- The resolution phase had already finished, so the run created 991
-- instructors and wrote 13,773 aliases and then failed at the write-back with
-- nothing on `grades` -- the expensive work done and none of it visible.
--
-- Flattening the variants with a lateral join turns the predicate into plain
-- equality between two columns, which the planner can satisfy with the
-- existing index on grades (instructor_name).

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
               v.variant
        from jsonb_array_elements(batch) e
        cross join lateral jsonb_array_elements_text(e->'variants') as v(variant)
        where e->>'instructor_id' is not null
    )
    update grades g
       set instructor_id = m.iid
      from mapping m
     where g.instructor_id is null
       and g.instructor_name = m.variant;

    get diagnostics n = row_count;
    return n;
end;
$$;

comment on function apply_instructor_ids(jsonb) is
    'Write instructor_id onto grade rows for a batch of resolved names, '
    'covering every raw spelling that normalized to each name.';
