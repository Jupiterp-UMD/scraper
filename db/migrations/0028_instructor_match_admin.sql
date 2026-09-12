-- The data layer for the instructor-matching admin screen.
--
-- `instructor_match_queue` has held the unresolved names since 0007 and there
-- has never been a way to work it except by hand in SQL. 257 entries are open,
-- every one of them a professor whose grade history is split or missing until
-- someone decides which record they are.
--
-- Two pieces: a view that answers "what am I choosing between", and one
-- function that performs the choice atomically.

/* ===================== what the moderator is shown ====================== */

-- Open queue entries with their candidates resolved to real instructors.
--
-- Candidates are stored as a bare `bigint[]` with no foreign key, so an id can
-- outlive the instructor it named -- two entries already point at records that
-- 0023 merged away. The join drops those rather than showing a blank row, and
-- an entry whose candidates have all disappeared still appears, with an empty
-- array, because it still needs a decision.
--
-- The per-candidate counts are the decision. Choosing between "Hector Bravo"
-- and "Hector Corrada Bravo" is guesswork on names alone; knowing one carries
-- 340 grade rows and eleven terms while the other carries none is not.
create or replace view instructor_match_queue_detail as
select q.id,
       q.observed,
       q.observed_norm,
       q.source,
       q.context,
       q.created_at,
       coalesce(
           (
               select jsonb_agg(
                          jsonb_build_object(
                              'id',         i.id,
                              'name',       i.name,
                              'slug',       i.slug,
                              'is_active',  i.is_active,
                              'grade_rows', (select count(*) from grades g where g.instructor_id = i.id),
                              'sections',   (select count(*) from section_instructors s where s.instructor_id = i.id),
                              'first_term', i.first_seen_term,
                              'last_term',  i.last_seen_term
                          )
                          order by i.name
                      )
               from unnest(q.candidates) as c(cid)
               join instructors i on i.id = c.cid
           ),
           '[]'::jsonb
       ) as candidates
from instructor_match_queue q
where q.resolved_at is null;

comment on view instructor_match_queue_detail is
    'Open instructor_match_queue entries with candidates hydrated into JSON, '
    'including how much data each candidate carries. Backs /admin/professors.';

grant select on instructor_match_queue_detail to service_role;


/* ========================== performing the choice ======================= */

-- Resolve one queue entry. Three outcomes, one transaction.
--
--   link     the observed spelling belongs to an existing instructor
--   create   it is a professor with no record yet
--   dismiss  it is not a person, or not worth a record
--
-- Everything a decision touches moves together. Repointing the alias without
-- moving the grade rows leaves a professor page empty; moving the rows without
-- the alias means the next scrape silently undoes the correction. That is why
-- this is one function rather than three statements a UI issues in sequence.
--
-- Returns what happened, so the caller can report it rather than guess.
create or replace function resolve_instructor_match(
    p_queue_id      bigint,
    p_action        text,
    p_instructor_id bigint default null,
    p_actor         text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    entry        instructor_match_queue%rowtype;
    target       bigint;
    moved        bigint := 0;
    created_slug text;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'p_actor is required: a decision has to name who made it';
    end if;
    if p_actor in ('backfill', 'scraper', 'auto') then
        raise exception 'p_actor % is reserved for automated resolution', p_actor;
    end if;

    select * into entry from instructor_match_queue where id = p_queue_id;
    if not found then
        raise exception 'no queue entry %', p_queue_id;
    end if;
    if entry.resolved_at is not null then
        -- Idempotent rather than an error: two moderators with the queue open
        -- is normal, and the second one losing their click to an exception
        -- teaches them to distrust the screen.
        return jsonb_build_object('status', 'already_resolved',
                                  'resolved_by', entry.resolved_by,
                                  'resolved_to', entry.resolved_to);
    end if;

    if p_action = 'dismiss' then
        update instructor_match_queue
           set resolved_at = now(), resolved_by = p_actor, resolved_to = null
         where id = p_queue_id;
        return jsonb_build_object('status', 'dismissed', 'moved_grade_rows', 0);

    elsif p_action = 'create' then
        insert into instructors (name, slug, first_seen_term, last_seen_term, is_active)
        values (entry.observed,
                next_instructor_slug(entry.observed),
                (entry.context->>'term')::int,
                (entry.context->>'term')::int,
                false)
        returning id, slug into target, created_slug;

    elsif p_action = 'link' then
        if p_instructor_id is null then
            raise exception 'link requires p_instructor_id';
        end if;
        if not exists (select 1 from instructors where id = p_instructor_id) then
            raise exception 'no instructor with id %', p_instructor_id;
        end if;
        target := p_instructor_id;

    else
        raise exception 'p_action must be link, create, or dismiss (got %)', p_action;
    end if;

    -- Alias first, so the next scrape resolves this spelling the same way.
    insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
    values (entry.observed_norm, entry.observed, target, 'manual', 1.0)
    on conflict (alias_norm)
    do update set instructor_id = excluded.instructor_id,
                  source        = 'manual',
                  confidence    = 1.0;

    -- Then the grade rows carrying any spelling that normalises to this one.
    update grades
       set instructor_id = target
     where normalize_name(instructor_name) = entry.observed_norm
       and instructor_id is distinct from target;
    get diagnostics moved = row_count;

    update instructor_match_queue
       set resolved_at = now(), resolved_by = p_actor, resolved_to = target
     where id = p_queue_id;

    return jsonb_build_object(
        'status',           case when p_action = 'create' then 'created' else 'linked' end,
        'instructor_id',    target,
        'slug',             coalesce(created_slug, (select slug from instructors where id = target)),
        'moved_grade_rows', moved
    );
end;
$$;

comment on function resolve_instructor_match(bigint, text, bigint, text) is
    'Resolve one instructor_match_queue entry: link to an existing instructor, '
    'create a new one, or dismiss. Moves the alias and the grade rows together. '
    'Matviews are NOT refreshed -- call refresh_grade_matviews() after a batch.';
