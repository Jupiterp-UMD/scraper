-- Close queue rows when the resolver settles the name, and give a human a way
-- to overturn that.
--
-- `link_instructor` queued a name it could not settle, but nothing ever closed
-- the row once the name was later resolved -- by a confident match on a
-- subsequent run, or by `create_if_missing` creating the professor outright.
-- After the grade backfill the queue held 1,228 open rows of which 1,013 were
-- already resolved: the moderator sees five times the real work, and the one
-- number that says how much triage is left stops meaning anything.
--
-- Auto-closed rows are stamped with a machine actor rather than left
-- indistinguishable from a human decision, because the whole point of
-- reviewing this later is being able to ask "what did the machine decide on
-- its own, and was it right?" `resolved_by` was already null on every row, so
-- there is no existing convention to break:
--
--   'backfill'  registrar names, resolved by scripts/backfill_instructor_ids.py
--   'scraper'   testudo names, resolved by reconcile_instructors()
--   anything else  a human, via override_instructor_match()

/* ===================== link_instructor: close on resolve ================= */

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
    norm       text := normalize_name(link_instructor.observed);
    r          record;
    new_id     bigint;
    auto_actor text := case link_instructor.source
                           when 'registrar' then 'backfill'
                           when 'testudo'   then 'scraper'
                           else 'auto'
                       end;
begin
    if norm is null or is_instructor_denylisted(link_instructor.observed) then
        return null;
    end if;

    select * into r from resolve_instructor(link_instructor.observed);

    if r.instructor_id is not null then
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

        -- This spelling was queued on an earlier pass and has now been
        -- settled. Only ever closes a row this call actually resolved.
        update instructor_match_queue q
           set resolved_to = r.instructor_id,
               resolved_at = now(),
               resolved_by = auto_actor
         where q.observed_norm = norm
           and q.source        = link_instructor.source
           and q.resolved_at is null;

        return r.instructor_id;
    end if;

    if link_instructor.create_if_missing and r.method is null then
        insert into instructors (name, slug, first_seen_term, last_seen_term, is_active)
        values (link_instructor.observed,
                next_instructor_slug(link_instructor.observed),
                link_instructor.seen_term, link_instructor.seen_term, true)
        returning id into new_id;

        insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
        values (norm, link_instructor.observed, new_id, link_instructor.source, 1.0)
        on conflict (alias_norm) do nothing;

        update instructor_match_queue q
           set resolved_to = new_id,
               resolved_at = now(),
               resolved_by = auto_actor
         where q.observed_norm = norm
           and q.source        = link_instructor.source
           and q.resolved_at is null;

        return new_id;
    end if;

    insert into instructor_match_queue (observed, source, context, candidates)
    values (link_instructor.observed, link_instructor.source,
            link_instructor.context, r.candidates)
    on conflict (observed_norm, source) where resolved_at is null
    do update set context = coalesce(instructor_match_queue.context, excluded.context);

    return null;
end;
$$;


/* ========================= the human override =========================== */

-- Point a spelling at a different instructor than the resolver chose.
--
-- This is the merge that 0007 reserves for a human: aliases are append-only
-- from the resolver's side precisely so that repointing one is always a
-- deliberate act recorded here.
--
-- It moves three things together, which is the reason this is a function and
-- not three statements in a runbook. Repointing the alias without moving the
-- grade rows leaves the professor page empty; moving the rows without
-- repointing the alias means the next scrape silently undoes the correction.
--
-- Returns the number of grade rows moved. Safe to re-run; the second call
-- moves nothing and re-stamps the same decision.
create or replace function override_instructor_match(
    p_observed_norm text,
    p_instructor_id bigint,
    p_actor         text
)
returns bigint
language plpgsql
set search_path = public, extensions, pg_catalog
as $$
declare
    moved bigint;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'p_actor is required: an override has to name who made it';
    end if;
    if p_actor in ('backfill', 'scraper', 'auto') then
        raise exception 'p_actor % is reserved for automated resolution', p_actor;
    end if;
    if not exists (select 1 from instructors where id = p_instructor_id) then
        raise exception 'no instructor with id %', p_instructor_id;
    end if;

    -- 1. The alias, so future resolutions of this spelling agree.
    -- 'manual' rather than 'human': instructor_aliases.source is constrained to
    -- ('testudo','planetterp','registrar','manual') and 'manual' is already the
    -- schema's name for a human-entered alias.
    insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
    values (p_observed_norm, p_observed_norm, p_instructor_id, 'manual', 1.0)
    on conflict (alias_norm)
    do update set instructor_id = excluded.instructor_id,
                  source        = 'manual',
                  confidence    = 1.0;

    -- 2. The grade rows already attributed under this spelling. Matching on
    --    the normalized form catches every raw variant at once, and uses
    --    grades_instructor_name_norm_idx.
    update grades
       set instructor_id = p_instructor_id
     where normalize_name(instructor_name) = p_observed_norm
       and instructor_id is distinct from p_instructor_id;
    get diagnostics moved = row_count;

    -- 3. The queue row, whether it was open or auto-closed.
    update instructor_match_queue q
       set resolved_to = p_instructor_id,
           resolved_at = now(),
           resolved_by = p_actor
     where q.observed_norm = p_observed_norm;

    return moved;
end;
$$;

comment on function override_instructor_match(text, bigint, text) is
    'Human correction of an instructor match. Repoints the alias, moves the '
    'grade rows, and records who decided. Matviews are NOT refreshed; call '
    'refresh_grade_matviews() when a batch of corrections is done.';


/* ================= close the rows already settled ======================= */

-- The rules above only fire when link_instructor resolves a name. Every row
-- resolved before this migration existed is still open, so it is closed here
-- on the same evidence the resolver would use: an alias for that spelling
-- means the name is settled and points at the instructor it settled on.
--
-- This is a bounded one-off over a few thousand rows, not a backfill over the
-- grade table, so it belongs in a migration.
update instructor_match_queue q
   set resolved_to = a.instructor_id,
       resolved_at = now(),
       resolved_by = case q.source
                         when 'registrar' then 'backfill'
                         when 'testudo'   then 'scraper'
                         else 'auto'
                     end
  from instructor_aliases a
 where a.alias_norm = q.observed_norm
   and q.resolved_at is null;


/* ===================== what the machine decided alone =================== */

-- The review surface. Auto-resolved entries with no candidates were created
-- from a registrar spelling alone -- nothing in the database resembled them --
-- which is the population most worth a human eye.
create or replace view instructor_match_auto_resolved as
select q.id,
       q.observed,
       q.observed_norm,
       q.source,
       q.resolved_by,
       q.resolved_at,
       q.resolved_to        as instructor_id,
       i.name               as instructor_name,
       i.slug               as instructor_slug,
       coalesce(array_length(q.candidates, 1), 0) as candidate_count,
       case when coalesce(array_length(q.candidates, 1), 0) = 0
            then 'created'  else 'matched' end     as outcome,
       (select count(*) from grades g where g.instructor_id = q.resolved_to) as grade_rows
from instructor_match_queue q
join instructors i on i.id = q.resolved_to
where q.resolved_by in ('backfill', 'scraper', 'auto');

comment on view instructor_match_auto_resolved is
    'Queue entries settled without a human. Review surface for '
    'override_instructor_match(); `outcome = created` is the higher-risk set.';

grant select on instructor_match_auto_resolved to service_role;
