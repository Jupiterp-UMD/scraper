-- Fix `column reference "source" is ambiguous` in link_instructor().
--
-- Three of the function's parameters -- `observed`, `source`, `context` -- are
-- also column names on `instructor_match_queue`, and `source` is a column on
-- `instructor_aliases` too. PL/pgSQL's default `variable_conflict` setting is
-- `error`, so any bare reference that could mean either aborts the call:
--
--     column reference "source" is ambiguous
--     It could refer to either a PL/pgSQL variable or a table column.
--
-- The specific line that raised it is the queue insert's conflict target,
-- `on conflict (observed_norm, source)`. An index inference clause has to name
-- real columns, but the parser sees the parameter of the same name first.
--
-- This aborted every call that reached the queue insert -- that is, every name
-- the resolver could not settle confidently. Both callers are affected:
-- scripts/backfill_instructor_ids.py over sixteen years of registrar
-- spellings, and reconcile_instructors() on every nightly section scrape.
-- Neither could ever have queued an ambiguous name for triage.
--
-- The parameter names are left alone on purpose. Both callers invoke this
-- through PostgREST with named arguments (`{"observed": ..., "source": ...}`),
-- so renaming the parameters would move the breakage into Python rather than
-- fix it.
--
-- `use_column` resolves a genuine ambiguity in favour of the column, which is
-- what the conflict target needs. Every reference that is meant to be the
-- parameter is then qualified as `link_instructor.<name>`, so the intent of
-- each one is stated rather than inferred from the pragma.

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
#variable_conflict use_column
declare
    norm    text := normalize_name(link_instructor.observed);
    r       record;
    new_id  bigint;
begin
    if norm is null or is_instructor_denylisted(link_instructor.observed) then
        return null;
    end if;

    select * into r from resolve_instructor(link_instructor.observed);

    if r.instructor_id is not null then
        -- Record the spelling so this is an exact hit next time. Append-only:
        -- an existing alias is never repointed here, only by a human merge.
        insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
        values (norm, link_instructor.observed, r.instructor_id,
                link_instructor.source, r.confidence)
        on conflict (alias_norm) do nothing;

        if link_instructor.seen_term is not null then
            update instructors
               set first_seen_term = least(coalesce(first_seen_term, link_instructor.seen_term),
                                           link_instructor.seen_term),
                   last_seen_term  = greatest(coalesce(last_seen_term, link_instructor.seen_term),
                                              link_instructor.seen_term)
             where id = r.instructor_id;
        end if;

        return r.instructor_id;
    end if;

    if link_instructor.create_if_missing and r.method is null then
        -- No candidates at all: a genuinely new professor rather than an
        -- ambiguous one. An ambiguity always goes to a human.
        insert into instructors (name, slug, first_seen_term, last_seen_term, is_active)
        values (link_instructor.observed,
                next_instructor_slug(link_instructor.observed),
                link_instructor.seen_term, link_instructor.seen_term, true)
        returning id into new_id;

        insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
        values (norm, link_instructor.observed, new_id, link_instructor.source, 1.0)
        on conflict (alias_norm) do nothing;

        return new_id;
    end if;

    -- Unresolved. One open queue row per spelling per source; a name appearing
    -- in 400 sections must not queue 400 identical decisions.
    insert into instructor_match_queue (observed, source, context, candidates)
    values (link_instructor.observed, link_instructor.source,
            link_instructor.context, r.candidates)
    on conflict (observed_norm, source) where resolved_at is null
    do update set context = coalesce(instructor_match_queue.context, excluded.context);

    return null;
end;
$$;

comment on function link_instructor(text, text, jsonb, boolean, int) is
    'Single entry point for instructor resolution. Called by the Testudo '
    'scrape (create_if_missing => true) and the grade backfill '
    '(create_if_missing => false). Returns null when the name was queued.';
