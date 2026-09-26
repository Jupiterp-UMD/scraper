-- Review-processing and grade-data fixes found reviewing the grade-migration
-- branch. Five independent changes, each explained where it is made:
--
--   1. `reviews_one_per_person` now covers `escalated` reviews.
--   2. Moderators can remove an approved review and resolve reports.
--   3. The rating prior includes the PlanetTerp baseline.
--   4. The grade matviews know when they are stale, and the sweep refreshes
--      them.
--   5. `course_grades` and `course_term_grades` are materialized.
--
-- `create or replace` is used wherever a function keeps its signature, so the
-- owner, grants and comments from 20260912200959 carry over unchanged.


/* ============ 1. one live review per person, escalated included ========= */

-- The index left out `escalated`. With automated triage off -- the day-one
-- configuration -- every verified review is escalated immediately, so the
-- dedupe covered almost nothing: the same address could hold several live
-- reviews of one professor and course. Approving the second one then violated
-- the index (it does cover `approved`), and the moderator got a 500 on a review
-- that could never leave the queue.
--
-- Refuses to run if duplicates already exist rather than choosing which review
-- a person keeps. Reject or withdraw the extras, then re-run.
do $$
declare
    dupes text;
begin
    select string_agg(format('instructor %s course %s: %s',
                             instructor_id, coalesce(course_code, '(none)'), ids), '; ')
      into dupes
      from (
          select instructor_id, max(course_code) as course_code,
                 string_agg(id::text, ', ' order by submitted_at) as ids
            from reviews
           where status in ('unverified', 'pending', 'escalated', 'approved')
           group by instructor_id, coalesce(course_code, ''), email_hash
          having count(*) > 1
      ) d;

    if dupes is not null then
        raise exception 'one person holds several live reviews of the same professor and '
            'course; decide which to keep, reject the others, then re-run: %', dupes;
    end if;
end $$;

drop index reviews_one_per_person;

-- Same name as before: HandleSubmit recognises the violation by it.
create unique index reviews_one_per_person
    on reviews (instructor_id, coalesce(course_code, ''), email_hash)
    where status in ('unverified', 'pending', 'escalated', 'approved');


/* ============= 2. removing published reviews, resolving reports ========== */

-- A report used to be a row nobody could act on: the decision route only moved
-- `pending` and `escalated` reviews, so an approved review could not be taken
-- down without SQL. `remove` is recorded as its own decision so the audit trail
-- tells a takedown apart from a rejection at the queue.
alter table moderation_decisions
    drop constraint moderation_decisions_decision_check;
alter table moderation_decisions
    add constraint moderation_decisions_decision_check
    check (decision in ('approve', 'reject', 'escalate', 'remove'));

alter table review_reports
    add column resolved_by text;

comment on column review_reports.resolution is
    '''removed'' when the review was taken down, ''dismissed'' when it was left up.';


/* ================== 3. a rating prior that is not a coin toss =========== */

-- The prior was the mean of approved Jupiterp reviews alone. Before launch that
-- is the 3.0 fallback; after the first approval it is that one review's rating,
-- applied to every professor on the site. With shrinkage at 5, a single 1.0
-- review moved a professor holding a 4.0 from three PlanetTerp reviews from
-- about 3.4 to about 2.1 overnight -- a professor nobody had reviewed.
--
-- The prior now pools both sources under the same weights the blend itself
-- uses, so it starts at the PlanetTerp mean and drifts toward Jupiterp's as
-- reviews accumulate and the snapshot decays.
create or replace function compute_instructor_ratings(
    p_review_half_life numeric default null,
    p_pt_half_life     numeric default null,
    p_pt_max_age       numeric default null,
    p_pt_weight_cap    numeric default null,
    p_shrinkage        numeric default null
)
returns table (
    instructor_id      bigint,
    jupiterp_rating    numeric,
    jupiterp_reviews   int,
    jupiterp_weight    numeric,
    pt_weight          numeric,
    combined_rating    numeric,
    total_weight       numeric
)
language plpgsql
stable
as $$
declare
    cfg          rating_config%rowtype;
    review_hl    numeric;
    pt_hl        numeric;
    pt_max_age   numeric;
    pt_cap       numeric;
    shrink       numeric;
    global_mean  numeric;
begin
    select * into cfg from rating_config where id;

    review_hl  := coalesce(p_review_half_life, cfg.review_half_life_years);
    pt_hl      := coalesce(p_pt_half_life,     cfg.pt_half_life_years);
    pt_max_age := coalesce(p_pt_max_age,       cfg.pt_max_age_years);
    pt_cap     := coalesce(p_pt_weight_cap,    cfg.pt_weight_cap);
    shrink     := coalesce(p_shrinkage,        cfg.shrinkage_reviews);

    return query
    with jupiterp as (
        select
            r.instructor_id as iid,
            sum(power(0.5, (extract(epoch from now() - r.submitted_at) / 31557600.0) / review_hl)) as w,
            sum(r.rating * power(0.5, (extract(epoch from now() - r.submitted_at) / 31557600.0) / review_hl)) as weighted_sum,
            count(*)::int as n
        from reviews r
        where r.status = 'approved'
        group by r.instructor_id
    ),
    planetterp as (
        select
            i.id as iid,
            i.pt_average_rating as pt_rating,
            case
                when i.pt_average_rating is null or i.pt_snapshot_at is null then 0
                when (extract(epoch from now() - i.pt_snapshot_at) / 31557600.0) > pt_max_age then 0
                else least(coalesce(i.pt_review_count, 0), pt_cap)
                     * power(0.5, (extract(epoch from now() - i.pt_snapshot_at) / 31557600.0) / pt_hl)
            end as w
        from instructors i
    ),
    -- The prior: every weighted rating the site holds, from both sources.
    -- Falls back to the scale midpoint only when there is nothing at all.
    prior as (
        select coalesce(
                   (coalesce((select sum(weighted_sum) from jupiterp), 0)
                    + coalesce((select sum(w * pt_rating) from planetterp where w > 0), 0))
                   / nullif(coalesce((select sum(w) from jupiterp), 0)
                            + coalesce((select sum(w) from planetterp where w > 0), 0), 0),
                   3.0) as mean
    )
    select
        i.id,
        -- Jupiterp's own decayed average, shown alongside the blend rather
        -- than folded invisibly into it.
        case when coalesce(j.w, 0) > 0 then round(j.weighted_sum / j.w, 2) end,
        coalesce(j.n, 0),
        round(coalesce(j.w, 0), 4),
        round(coalesce(p.w, 0), 4),
        -- The displayed number: both sources plus `shrink` notional reviews
        -- sitting at the prior.
        case
            when coalesce(j.w, 0) + coalesce(p.w, 0) <= 0 then null
            else round(
                (shrink * prior.mean
                 + coalesce(j.weighted_sum, 0)
                 + coalesce(p.w, 0) * coalesce(p.pt_rating, 0))
                / (shrink + coalesce(j.w, 0) + coalesce(p.w, 0)),
                2)
        end,
        round(coalesce(j.w, 0) + coalesce(p.w, 0), 4)
    from instructors i
    cross join prior
    left join jupiterp   j on j.iid = i.id
    left join planetterp p on p.iid = i.id;
end;
$$;

-- The stored ratings were computed under the old prior.
select refresh_instructor_ratings();


/* ============== 4. grade matviews that know they are stale ============== */

-- Nothing refreshed the grade matviews except a per-term ingest and the
-- one-off backfill. Every instructor link and merge from /admin/professors
-- moved grade rows the matviews did not see, so professor pages kept the old
-- split histories -- and course popovers kept rows under slugs that had been
-- merged away -- until the next term's ingest, months later. The bulk `ingest`
-- command had the same gap.
--
-- Rather than make each writer remember, anything that changes what the
-- matviews read bumps a generation counter, and the hourly sweep refreshes when
-- the counter has moved. A counter rather than a timestamp: a change committed
-- while a refresh is running is not in the refresh's snapshot, and has to stay
-- counted as outstanding. The refresh records the generation it read before it
-- started, so such a change leaves `generation` ahead of `refreshed_generation`.
create table grade_matview_state (
    id                   boolean primary key default true check (id),
    generation           bigint      not null default 0,
    refreshed_generation bigint      not null default 0,
    changed_at           timestamptz,
    refreshed_at         timestamptz
);

insert into grade_matview_state (id) values (true);

alter table grade_matview_state enable row level security;
revoke all on grade_matview_state from anon, authenticated, service_role;
grant select on grade_matview_state to service_role;

comment on table grade_matview_state is
    'Whether the grade matviews are behind the tables they read. Bumped by '
    'triggers on grades and instructors; cleared by refresh_grade_matviews().';


-- SECURITY DEFINER so the writers -- the loader, the backfill, the admin RPCs,
-- a person in psql -- need no grant on the state table.
create function mark_grade_matviews_stale()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    update grade_matview_state
       set generation = generation + 1,
           changed_at = now()
     where id;
    return null;
end;
$$;

-- Statement-level on grades: an ingest upserts thousands of rows per request
-- and one bump per statement is all that is needed.
create trigger grades_mark_matviews_stale
    after insert or update or delete on grades
    for each statement execute function mark_grade_matviews_stale();

-- Row-level on instructors, because the scrape and the nightly rating refresh
-- update this table constantly and almost never touch the two columns the
-- matviews carry. The WHEN makes those updates free.
create trigger instructors_mark_matviews_stale_on_update
    after update of name, slug on instructors
    for each row
    when (old.name is distinct from new.name or old.slug is distinct from new.slug)
    execute function mark_grade_matviews_stale();

create trigger instructors_mark_matviews_stale_on_delete
    after delete on instructors
    for each statement execute function mark_grade_matviews_stale();


-- Now also refreshes the two course rollups materialized below, and records
-- which generation it caught up to.
create or replace function refresh_grade_matviews()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    started timestamptz := clock_timestamp();
    elapsed int;
    caught_up bigint;
begin
    -- Read before refreshing, so a change that lands during the refresh is
    -- still outstanding afterwards.
    select generation into caught_up from grade_matview_state where id;

    refresh materialized view concurrently course_instructor_grades;
    refresh materialized view concurrently instructor_grades;
    refresh materialized view concurrently grade_terms;
    refresh materialized view concurrently course_grades;
    refresh materialized view concurrently course_term_grades;

    elapsed := (extract(epoch from (clock_timestamp() - started)) * 1000)::int;

    -- Every ingest not yet covered by a refresh is now covered by this one.
    update grade_ingests
       set matviews_refreshed_at = now(),
           matview_refresh_ms    = elapsed
     where matviews_refreshed_at is null;

    update grade_matview_state
       set refreshed_generation = greatest(refreshed_generation, coalesce(caught_up, 0)),
           refreshed_at         = now()
     where id;
end;
$$;

comment on function refresh_grade_matviews is
    'Refreshes the grade matviews (course_instructor_grades, instructor_grades, '
    'grade_terms, course_grades, course_term_grades), stamps '
    'grade_ingests.matviews_refreshed_at, and marks grade_matview_state caught up. '
    'SECURITY DEFINER because refresh is gated on ownership and the callers run '
    'as service_role. A function, not a procedure, so PostgREST can call it.';


-- What the sweep calls. Returns whether it refreshed, so the sweep can say so.
create function refresh_grade_matviews_if_stale()
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    state grade_matview_state%rowtype;
begin
    select * into state from grade_matview_state where id;
    if state.generation <= state.refreshed_generation then
        return false;
    end if;
    perform refresh_grade_matviews();
    return true;
end;
$$;

comment on function refresh_grade_matviews_if_stale() is
    'Refresh the grade matviews if anything they read has changed since the last '
    'refresh. Called by POST /v1/admin/sweep.';

revoke execute
    on function mark_grade_matviews_stale(),
                refresh_grade_matviews_if_stale()
    from public, anon, authenticated;
grant execute on function refresh_grade_matviews_if_stale() to service_role;


/* ============= 5. course rollups that fit inside a timeout ============== */

-- `course_grades` and `course_term_grades` were plain views: a full aggregate
-- over all ~200k grade rows whenever a caller did not narrow by course. That
-- is the exact shape that took `grade_terms` to ~2s against anon's 3s
-- statement_timeout, and the public API lets anyone ask for it -- "every
-- course, sorted by GPA" is the obvious query. Materialized, with the same
-- columns, so no caller can tell the difference.
drop view course_grades;
drop view course_term_grades;

create materialized view course_grades as
select
    course_code,
    count(*)::int             as section_count,
    count(distinct term)::int as term_count,
    min(term)                 as first_term,
    max(term)                 as last_term,
    sum(total)::int   as total,
    sum(graded)::int  as graded,
    sum(a_plus)::int  as a_plus,
    sum(a)::int       as a,
    sum(a_minus)::int as a_minus,
    sum(b_plus)::int  as b_plus,
    sum(b)::int       as b,
    sum(b_minus)::int as b_minus,
    sum(c_plus)::int  as c_plus,
    sum(c)::int       as c,
    sum(c_minus)::int as c_minus,
    sum(d_plus)::int  as d_plus,
    sum(d)::int       as d,
    sum(d_minus)::int as d_minus,
    sum(f)::int       as f,
    sum(w)::int       as w,
    sum(other)::int   as other,
    umd_gpa(sum(a_plus)::int, sum(a)::int, sum(a_minus)::int,
            sum(b_plus)::int, sum(b)::int, sum(b_minus)::int,
            sum(c_plus)::int, sum(c)::int, sum(c_minus)::int,
            sum(d_plus)::int, sum(d)::int, sum(d_minus)::int,
            sum(f)::int) as gpa
from grades
group by course_code;

-- Unique, so the refresh can run concurrently. Also the course lookup.
create unique index course_grades_key on course_grades (course_code);
create index course_grades_gpa_idx on course_grades (gpa desc nulls last);

create materialized view course_term_grades as
select
    course_code,
    term,
    count(*)::int as section_count,
    sum(total)::int   as total,
    sum(graded)::int  as graded,
    sum(a_plus)::int  as a_plus,
    sum(a)::int       as a,
    sum(a_minus)::int as a_minus,
    sum(b_plus)::int  as b_plus,
    sum(b)::int       as b,
    sum(b_minus)::int as b_minus,
    sum(c_plus)::int  as c_plus,
    sum(c)::int       as c,
    sum(c_minus)::int as c_minus,
    sum(d_plus)::int  as d_plus,
    sum(d)::int       as d,
    sum(d_minus)::int as d_minus,
    sum(f)::int       as f,
    sum(w)::int       as w,
    sum(other)::int   as other,
    umd_gpa(sum(a_plus)::int, sum(a)::int, sum(a_minus)::int,
            sum(b_plus)::int, sum(b)::int, sum(b_minus)::int,
            sum(c_plus)::int, sum(c)::int, sum(c_minus)::int,
            sum(d_plus)::int, sum(d)::int, sum(d_minus)::int,
            sum(f)::int) as gpa
from grades
group by course_code, term;

create unique index course_term_grades_key on course_term_grades (course_code, term);
-- "Every course in one term".
create index course_term_grades_term_idx on course_term_grades (term);

comment on materialized view course_grades is
    'Per-course grade totals across every term. Materialized: as a plain view an '
    'unfiltered read aggregated every grade row. Refreshed by refresh_grade_matviews().';
comment on materialized view course_term_grades is
    'Per-course, per-term grade totals. Materialized for the same reason as '
    'course_grades. Refreshed by refresh_grade_matviews().';

-- A fresh object starts with no grants; see the grants section of 20260912200959.
revoke all on course_grades, course_term_grades from anon, authenticated, service_role;
grant select on course_grades, course_term_grades to anon, authenticated, service_role;

-- Start stale. The two matviews above are current, but nothing says the three
-- older ones are -- the bulk ingest never refreshed them, and neither did any
-- link or merge made since -- so the first sweep refreshes everything.
update grade_matview_state
   set generation = generation + 1,
       changed_at = now()
 where id;
