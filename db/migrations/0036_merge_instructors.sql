-- Let a moderator resolve a queue entry against several duplicate records at
-- once, by merging them.
--
-- `resolve_instructor_match` (0028) offers one choice of one candidate. That is
-- the wrong shape whenever the candidate list contains the same professor
-- twice, which is common: PlanetTerp was imported under one spelling, the
-- registrar under another, and 0022's slug rewrite surfaced five such pairs in
-- one go. The moderator picks one, the other keeps its grade rows and its
-- professor page, and the split the queue entry exists to fix survives the
-- decision that was supposed to fix it.
--
-- Merging by hand is what 0023 did, and it was only safe there because every
-- row it touched had been checked to carry nothing: zero grades, zero sections,
-- zero reviews, zero aliases. That is not the general case and it is not what a
-- moderator can verify from the admin screen.
--
-- ## Why this cannot be a DELETE
--
-- Three of the five foreign keys into `instructors` are ON DELETE CASCADE:
--
--     grades.instructor_id                 set null
--     instructor_aliases.instructor_id     cascade
--     reviews.instructor_id                cascade
--     section_instructors.instructor_id    cascade
--     instructor_match_queue.resolved_to   no action
--
-- So `delete from instructors where id = <duplicate>` silently destroys that
-- record's student reviews and every alias that resolved to it, nulls its grade
-- attribution, and -- because `resolved_to` is NO ACTION -- fails outright if
-- the record was ever the answer to an earlier queue entry. Every one of those
-- is a worse outcome than the duplicate. Everything is therefore reassigned
-- first and the delete is the last statement, at which point it cascades over
-- nothing.

create or replace function merge_instructors(
    p_keep      bigint,
    p_merge_ids bigint[],
    p_actor     text,
    p_force     boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
    keeper   instructors%rowtype;
    ids      bigint[];
    conflict jsonb;
    donor    instructors%rowtype;
    moved_grades   bigint := 0;
    moved_reviews  bigint := 0;
    moved_aliases  bigint := 0;
    moved_sections bigint := 0;
    dropped_links  bigint := 0;
begin
    if p_actor is null or btrim(p_actor) = '' then
        raise exception 'p_actor is required: a merge has to name who made it';
    end if;
    if p_actor in ('backfill', 'scraper', 'auto') then
        raise exception 'p_actor % is reserved for automated resolution', p_actor;
    end if;

    select * into keeper from instructors where id = p_keep;
    if not found then
        raise exception 'no instructor with id % to keep', p_keep;
    end if;

    -- Distinct, and never the keeper: a caller that sends the survivor in both
    -- lists is asking for it to be deleted at the end.
    select coalesce(array_agg(distinct x), '{}')
      into ids
      from unnest(coalesce(p_merge_ids, '{}')) t(x)
     where x <> p_keep;

    if cardinality(ids) = 0 then
        raise exception 'merge_instructors needs at least one record to merge into %', p_keep;
    end if;

    if exists (select 1 from unnest(ids) t(x)
                where not exists (select 1 from instructors where id = t.x)) then
        raise exception 'one or more ids in % do not exist', ids;
    end if;

    /* ------------------------- the one hard stop ------------------------- */
    --
    -- 0023's reasoning, enforced instead of written down: two records with two
    -- DIFFERENT PlanetTerp ratings are evidence of two different people, not of
    -- one person recorded twice. PlanetTerp rated them separately, which means
    -- students distinguished them. Merging fuses two professors' reputations
    -- into one page and is not reversible from the merged state.
    --
    -- Returned rather than raised. The admin API flattens a SQL exception into
    -- a generic 500 (`sendInternalError`), so raising here would tell the
    -- moderator only that something went wrong -- and the whole point is to
    -- show them the two ratings and let them decide. This mirrors how
    -- `resolve_instructor_match` returns `already_resolved`.
    if not p_force then
        select jsonb_agg(jsonb_build_object(
                   'id', i.id, 'name', i.name, 'slug', i.slug,
                   'pt_average_rating', i.pt_average_rating,
                   'pt_review_count', i.pt_review_count))
          into conflict
          from instructors i
         where i.id = any(ids)
           and i.pt_average_rating is not null
           and keeper.pt_average_rating is not null
           and i.pt_average_rating <> keeper.pt_average_rating;

        if conflict is not null then
            return jsonb_build_object(
                'status', 'needs_confirmation',
                'reason', 'planetterp_ratings_differ',
                'detail', 'These records carry different PlanetTerp ratings, '
                       || 'which usually means they are two different people who '
                       || 'share a name rather than one person recorded twice. '
                       || 'Merging fuses both reputations into one page and '
                       || 'cannot be undone.',
                'keep', jsonb_build_object(
                    'id', keeper.id, 'name', keeper.name, 'slug', keeper.slug,
                    'pt_average_rating', keeper.pt_average_rating,
                    'pt_review_count', keeper.pt_review_count),
                'conflicts', conflict);
        end if;
    end if;

    /* ------------------------ reassign everything ------------------------ */

    -- Reviews first, because this is the one that cannot be reconstructed.
    -- A grade row can be re-derived from the term's file and an alias from the
    -- next scrape; a student's review exists once.
    update reviews set instructor_id = p_keep where instructor_id = any(ids);
    get diagnostics moved_reviews = row_count;

    update grades set instructor_id = p_keep where instructor_id = any(ids);
    get diagnostics moved_grades = row_count;

    update instructor_aliases set instructor_id = p_keep where instructor_id = any(ids);
    get diagnostics moved_aliases = row_count;

    -- `section_instructors` is keyed (course_code, sec_code, instructor_id), so
    -- a section that listed both records -- exactly what a co-taught duplicate
    -- looks like -- would collide on the update. Drop the losing side first.
    delete from section_instructors si
     where si.instructor_id = any(ids)
       and exists (select 1 from section_instructors k
                    where k.course_code = si.course_code
                      and k.sec_code    = si.sec_code
                      and k.instructor_id = p_keep);
    get diagnostics dropped_links = row_count;

    update section_instructors set instructor_id = p_keep where instructor_id = any(ids);
    get diagnostics moved_sections = row_count;

    -- Earlier decisions that resolved to a record being merged away. The
    -- foreign key is NO ACTION, so leaving these would make the delete below
    -- fail; and the answer they record is still correct, just under a different
    -- id now.
    update instructor_match_queue set resolved_to = p_keep where resolved_to = any(ids);

    -- Candidate arrays are a bare bigint[] with no foreign key, so a merged-away
    -- id simply rots there: 0028's detail view joins candidates to `instructors`
    -- and drops the ones that no longer resolve, which is how two open entries
    -- ended up showing fewer options than they were queued with. Rewrite them
    -- to the survivor instead.
    update instructor_match_queue q
       set candidates = sub.rewritten
      from (
        select q2.id,
               (select array_agg(distinct case when x = any(ids) then p_keep else x end)
                  from unnest(q2.candidates) t(x)) as rewritten
          from instructor_match_queue q2
         where q2.candidates && ids
      ) sub
     where q.id = sub.id;

    /* ------------------- carry the survivor's facts over ------------------ */

    -- The donor with the most PlanetTerp reviews is the one worth inheriting
    -- from when the keeper has no PlanetTerp record of its own. Only ever fills
    -- a NULL: a keeper that already has a rating keeps it, and the case where
    -- both have one and they disagree was stopped above.
    select * into donor
      from instructors
     where id = any(ids) and pt_slug is not null
     order by coalesce(pt_review_count, 0) desc, id
     limit 1;

    update instructors i
       set first_seen_term = least(
               i.first_seen_term,
               (select min(d.first_seen_term) from instructors d where d.id = any(ids))),
           last_seen_term = greatest(
               i.last_seen_term,
               (select max(d.last_seen_term) from instructors d where d.id = any(ids))),
           -- Active if any of them was. The next scrape overwrites this from
           -- what it actually sees; until then, dropping the flag would hide a
           -- professor who is teaching right now.
           is_active = i.is_active
               or coalesce((select bool_or(d.is_active) from instructors d where d.id = any(ids)), false),
           pt_slug           = coalesce(i.pt_slug,           donor.pt_slug),
           pt_average_rating = coalesce(i.pt_average_rating, donor.pt_average_rating),
           pt_review_count   = coalesce(i.pt_review_count,   donor.pt_review_count),
           pt_snapshot_at    = coalesce(i.pt_snapshot_at,    donor.pt_snapshot_at),
           updated_at        = now()
     where i.id = p_keep;

    -- Every merged-away spelling becomes an alias of the survivor.
    --
    -- Without this the merge undoes itself: `reconcile_instructors` sees the
    -- old name in the next Testudo scrape, resolves nothing, and creates the
    -- duplicate again -- or queues it, putting the same decision back in front
    -- of the next moderator. Their existing aliases moved above; this covers
    -- the name on the record itself, which need never have had one.
    insert into instructor_aliases (alias_norm, alias_raw, instructor_id, source, confidence)
    select normalize_name(d.name), d.name, p_keep, 'manual', 1.0
      from instructors d
     where d.id = any(ids)
       and normalize_name(d.name) is not null
       and btrim(normalize_name(d.name)) <> ''
    on conflict (alias_norm)
    do update set instructor_id = excluded.instructor_id,
                  source        = 'manual',
                  confidence    = 1.0;

    -- Nothing points here any more, so the cascades have nothing to take.
    delete from instructors where id = any(ids);

    -- Reviews moved, so the survivor's review count and combined rating are
    -- now wrong on their public page. This is guarded by `is distinct from`
    -- internally and takes about a second over the whole table, which is worth
    -- it to keep a merge from leaving a visibly wrong number up until the
    -- nightly run.
    perform refresh_instructor_ratings();

    return jsonb_build_object(
        'status',          'merged',
        'kept',            p_keep,
        'kept_slug',       (select slug from instructors where id = p_keep),
        'merged',          to_jsonb(ids),
        'moved_reviews',   moved_reviews,
        'moved_grade_rows',moved_grades,
        'moved_aliases',   moved_aliases,
        'moved_sections',  moved_sections,
        'dropped_duplicate_section_links', dropped_links,
        -- Same convention as 0028: a batch of decisions should pay for one
        -- refresh, not one per click.
        'matviews_stale',  true);
end;
$$;

comment on function merge_instructors(bigint, bigint[], text, boolean) is
    'Merge duplicate instructor records into one, reassigning reviews, grades, '
    'aliases, section links and past queue decisions before deleting the '
    'duplicates. Returns needs_confirmation instead of merging when the records '
    'carry different PlanetTerp ratings; pass p_force to override. Grade '
    'matviews are NOT refreshed -- call refresh_grade_matviews() after a batch.';

revoke all on function merge_instructors(bigint, bigint[], text, boolean) from public, anon, authenticated;
grant execute on function merge_instructors(bigint, bigint[], text, boolean) to service_role;


/* ================= the queue decision, with merge added ================= */

-- Adding two defaulted parameters to `resolve_instructor_match` would leave the
-- 0028 four-argument version in place as a separate overload, and a call naming
-- only the original four arguments would then match both and fail as ambiguous.
-- So the old signature is dropped and replaced. Its grants (service_role only)
-- are restored explicitly at the bottom, because a drop takes them with it.
drop function if exists resolve_instructor_match(bigint, text, bigint, text);

create or replace function resolve_instructor_match(
    p_queue_id      bigint,
    p_action        text,
    p_instructor_id bigint  default null,
    p_actor         text    default null,
    p_merge_ids     bigint[] default null,
    p_force         boolean default false
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
    merge_result jsonb;
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

    elsif p_action = 'merge' then
        -- The moderator recognised several candidates as one professor. Fold
        -- them together first, then link the observed spelling to whatever
        -- survived, in this same transaction -- a merge that commits without
        -- the link leaves the queue entry open and pointing at ids that no
        -- longer exist, which is a worse queue than the one they started with.
        if p_instructor_id is null then
            raise exception 'merge requires p_instructor_id: the record to keep';
        end if;

        merge_result := merge_instructors(p_instructor_id, p_merge_ids, p_actor, p_force);

        -- Not merged, and deliberately so. Returned straight through with the
        -- queue entry untouched, so the moderator can confirm and retry.
        if merge_result->>'status' = 'needs_confirmation' then
            return merge_result;
        end if;

        target := p_instructor_id;

    else
        raise exception 'p_action must be link, merge, create, or dismiss (got %)', p_action;
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
        'status',           case p_action
                                when 'create' then 'created'
                                when 'merge'  then 'merged'
                                else 'linked'
                            end,
        'instructor_id',    target,
        'slug',             coalesce(created_slug, (select slug from instructors where id = target)),
        -- Grade rows this queue entry's own spelling moved. The merge moved its
        -- own, counted separately under `merge`.
        'moved_grade_rows', moved,
        'merge',            merge_result
    );
end;
$$;

comment on function resolve_instructor_match(bigint, text, bigint, text, bigint[], boolean) is
    'Resolve one instructor_match_queue entry: link to an existing instructor, '
    'merge several duplicate records and link to the survivor, create a new '
    'one, or dismiss. Moves the alias and the grade rows together. Matviews are '
    'NOT refreshed -- call refresh_grade_matviews() after a batch.';

revoke all on function resolve_instructor_match(bigint, text, bigint, text, bigint[], boolean)
    from public, anon, authenticated;
grant execute on function resolve_instructor_match(bigint, text, bigint, text, bigint[], boolean)
    to service_role;
