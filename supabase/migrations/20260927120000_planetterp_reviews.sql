-- PlanetTerp's written reviews, imported once from the snapshot archive by
-- scripts/import_planetterp_reviews.py, and shown on professor pages beside
-- Jupiterp's own.
--
-- A separate table rather than rows in `reviews`, for three reasons:
--
--   * Ratings. PlanetTerp's reviews are already counted, as `pt_average_rating`
--     weighted by `pt_review_count`. `compute_instructor_ratings()` reads
--     `reviews`, so anything put there would be counted a second time. Kept
--     apart, the rating code needs no change and cannot be wrong about it.
--   * Identity. `reviews` requires an email hash and a manage key, and its
--     one-per-person index is keyed on the hash. None of that exists for an
--     imported review, and faking it would put invented identities in the
--     table that moderation and dedupe trust.
--   * Length. `reviews.body` is capped at 5000 characters; PlanetTerp's longest
--     is 8935, and truncating someone else's review is worse than not showing it.
--
-- Keyed on `pt_slug`, not `instructor_id`, and joined through
-- `instructors.pt_slug` in the view. A slug no instructor holds is kept, just
-- not shown. A merge has to carry them explicitly: `merge_instructors()` only
-- gives the survivor a donor's `pt_slug` when it has none of its own, and every
-- record that predates 20260912200959 does have one, so two PlanetTerp records
-- of one professor would leave the donor's reviews joined to nothing. It is
-- redefined at the end of this file to repoint them.

create table planetterp_reviews (
    id             uuid primary key default gen_random_uuid(),
    pt_slug        text not null,
    course_code    text,
    rating         numeric(2,1) not null
        check (rating >= 1 and rating <= 5 and rating * 2 = floor(rating * 2)),
    expected_grade text check (expected_grade in
        ('A+','A','A-','B+','B','B-','C+','C','C-','D+','D','D-','F','W','Other')),
    body           text,
    created_at     timestamptz not null,
    -- sha256 of pt_slug, created, and review text: re-running the import is a
    -- no-op instead of a second copy of every review.
    source_key     text not null unique
);

create index planetterp_reviews_slug_idx on planetterp_reviews (pt_slug, created_at desc);

comment on table planetterp_reviews is
    'Reviews imported once from PlanetTerp. Shown through public_reviews with '
    'source = ''planetterp''; never counted in ratings, which already include '
    'them as pt_average_rating.';

alter table planetterp_reviews enable row level security;


-- Same columns in the same order, with `source` appended: `create or replace`
-- only allows adding columns at the end.
create or replace view public_reviews as
select
    r.id,
    r.instructor_id,
    i.slug as instructor_slug,
    r.course_code,
    r.term,
    r.rating,
    r.expected_grade,
    r.title,
    r.body,
    r.submitted_at,
    r.edited_at,
    'jupiterp'::text as source
from reviews r
join instructors i on i.id = r.instructor_id
where r.status = 'approved'
union all
select
    p.id,
    i.id,
    i.slug,
    p.course_code,
    null::int,
    p.rating,
    p.expected_grade,
    null::text,
    p.body,
    p.created_at,
    null::timestamptz,
    'planetterp'::text
from planetterp_reviews p
join instructors i on i.pt_slug = p.pt_slug;

comment on view public_reviews is
    'The only public path to review content: approved Jupiterp reviews and '
    'imported PlanetTerp ones, told apart by `source`. The identity columns are '
    'not selectable through it at all.';


-- A fresh object starts with no grants; see the grants section of 20260912200959.
-- Only the view is public. The table is written by the import alone.
revoke all on planetterp_reviews from anon, authenticated, service_role;
grant select, insert, update, delete on planetterp_reviews to service_role;

revoke all on public_reviews from anon, authenticated, service_role;
grant select on public_reviews to anon, authenticated, service_role;


-- merge_instructors() as 20260912200959 defined it, plus one step: after the
-- survivor's `pt_slug` is settled, every merged-away record's PlanetTerp
-- reviews are repointed to it. `source_key` still hashes the original slug, so
-- a re-run of the import recognises them and leaves them where the merge put
-- them. `create or replace` keeps the function's owner and grants.
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
    moved_pt_reviews bigint := 0;
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

    -- The survivor has at most one `pt_slug`, so any other slug among the
    -- merged-away records would leave its PlanetTerp reviews joined to nothing
    -- once the record is deleted. Repoint them to the survivor's.
    update planetterp_reviews p
       set pt_slug = k.pt_slug
      from instructors k
     where k.id = p_keep
       and k.pt_slug is not null
       and p.pt_slug <> k.pt_slug
       and p.pt_slug in (select d.pt_slug from instructors d
                          where d.id = any(ids) and d.pt_slug is not null);
    get diagnostics moved_pt_reviews = row_count;

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
        'moved_planetterp_reviews', moved_pt_reviews,
        'dropped_duplicate_section_links', dropped_links,
        -- Same convention as 0028: a batch of decisions should pay for one
        -- refresh, not one per click.
        'matviews_stale',  true);
end;
$$;

comment on function merge_instructors(bigint, bigint[], text, boolean) is
    'Merge duplicate instructor records into one, reassigning reviews, grades, '
    'aliases, section links, PlanetTerp reviews and past queue decisions before '
    'deleting the '
    'duplicates. Returns needs_confirmation instead of merging when the records '
    'carry different PlanetTerp ratings; pass p_force to override. Grade '
    'matviews are NOT refreshed -- call refresh_grade_matviews() after a batch.';
