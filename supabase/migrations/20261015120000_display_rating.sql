-- A displayed rating that is the reviews' own average, separate from the
-- shrunk score used to rank.
--
-- `combined_rating` adds `shrinkage_reviews` notional reviews at the site-wide
-- prior to every professor. That is the right thing to sort on -- it stops a
-- three-review 4.9 outranking a sixty-review 4.6 -- and the wrong thing to
-- print. A professor with a single 5-star PlanetTerp review was shown as 3.9
-- beside "1 review", and anyone who clicked through to that one review could
-- see the number was not its average. With five notional reviews against one
-- real one, the prior was 84% of what the page called their rating.
--
-- `display_rating` is the same blend without the prior: Jupiterp reviews and
-- the PlanetTerp baseline, each under the same recency weights the model
-- already uses, averaged on their own. It is what professor pages, the
-- directory and the planner's stars show. `combined_rating`, and its legacy
-- alias `average_rating`, keep their meaning and remain what anything that
-- ranks professors should read.
--
-- `display_rating` is deliberately not gated on `min_weight_to_display`: an
-- honest average of one review is worth showing, with its count beside it, in
-- a way that a mostly-prior number is not. It is null only when there is no
-- weight behind it at all.
--
-- `compute_instructor_ratings()` gains a column, which `create or replace`
-- cannot do, so it is dropped and recreated -- and with it the sweep view that
-- selects from it. Both get their grants restored below, because a new object
-- starts from PUBLIC execute and, on production, Supabase's default
-- privileges.


/* ============================== the column ============================== */

alter table instructors
    add column if not exists display_rating numeric(3,2);

comment on column instructors.display_rating is
    'The rating to show: recency-weighted average of Jupiterp reviews and the '
    'PlanetTerp baseline, with no shrinkage. Sort on combined_rating instead.';

comment on column instructors.combined_rating is
    'The rating to rank by: display_rating shrunk toward the site-wide prior by '
    'rating_config.shrinkage_reviews. Not the number to show a reader.';

-- `select i.*` was expanded when the view was created, so the new column is
-- not in it until the view is redefined. It is appended last, which is the one
-- change `create or replace view` allows, and keeps the view's grants.
create or replace view active_instructors as
select i.*
from instructors i
where i.is_active;


/* ============================= the model ================================ */

drop view rating_sensitivity_sweep;
drop function compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric);

-- As in 20260926120000, with `display_rating` added.
create function compute_instructor_ratings(
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
    display_rating     numeric,
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
        -- The displayed number: both sources, and nothing else.
        case
            when coalesce(j.w, 0) + coalesce(p.w, 0) <= 0 then null
            else round(
                (coalesce(j.weighted_sum, 0)
                 + coalesce(p.w, 0) * coalesce(p.pt_rating, 0))
                / (coalesce(j.w, 0) + coalesce(p.w, 0)),
                2)
        end,
        -- The ranking number: both sources plus `shrink` notional reviews
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

comment on function compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric) is
    'Every instructor''s rating under the given constants (null = rating_config). '
    'display_rating is the unshrunk average to show; combined_rating is shrunk '
    'toward the prior and is what to rank by.';


-- As in 20260912200959, writing `display_rating` too. It is part of the change
-- test: a row whose other columns already matched would otherwise keep a null
-- display rating until one of them moved.
create or replace function refresh_instructor_ratings()
returns integer
language plpgsql
as $function$
declare
    cfg      rating_config%rowtype;
    affected int;
begin
    select * into cfg from rating_config where id;

    with computed as (
        select * from compute_instructor_ratings()
    )
    update instructors i
       set jupiterp_rating       = c.jupiterp_rating,
           jupiterp_review_count = c.jupiterp_reviews,
           display_rating        = c.display_rating,
           combined_rating       = case
               when c.total_weight >= cfg.min_weight_to_display then c.combined_rating
               else null
           end,
           -- The v0 string field stays aliased to the ranking rating so
           -- existing clients keep working through the semantic change.
           average_rating = case
               when c.total_weight >= cfg.min_weight_to_display then c.combined_rating::real
               else null
           end
      from computed c
     where c.instructor_id = i.id
       and (i.jupiterp_rating       is distinct from c.jupiterp_rating
         or i.jupiterp_review_count is distinct from c.jupiterp_reviews
         or i.display_rating        is distinct from c.display_rating
         or i.combined_rating       is distinct from case
                when c.total_weight >= cfg.min_weight_to_display then c.combined_rating
                else null
            end
         or i.average_rating        is distinct from case
                when c.total_weight >= cfg.min_weight_to_display then c.combined_rating::real
                else null
            end);

    get diagnostics affected = row_count;
    return affected;
end;
$function$;


-- Unchanged from 20260912200959. Ranks on `combined_rating`, which is what it
-- is for.
create view rating_sensitivity_sweep as
with sweeps as (
    select 2.0 as half_life, * from compute_instructor_ratings(2.0)
    union all
    select 4.0 as half_life, * from compute_instructor_ratings(4.0)
    union all
    select 8.0 as half_life, * from compute_instructor_ratings(8.0)
)
select
    s.half_life,
    s.instructor_id,
    i.name,
    s.combined_rating,
    s.total_weight,
    rank() over (partition by s.half_life order by s.combined_rating desc nulls last) as rank
from sweeps s
join instructors i on i.id = s.instructor_id
where s.total_weight >= 3;

comment on view rating_sensitivity_sweep is
    'Same model at 2/4/8-year half-lives, for comparing rankings. Expensive; '
    'run it deliberately, not on a page load.';


/* ============================== grants ================================== */

-- The same access as 20260912200959 gave them: the sweep is internal, and the
-- model is callable by the service role only.
revoke all on rating_sensitivity_sweep from anon, authenticated, service_role;

revoke all
    on function compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric)
    from public, anon, authenticated, service_role;
grant execute
    on function compute_instructor_ratings(numeric, numeric, numeric, numeric, numeric)
    to service_role;


/* ============================== backfill ================================ */

select refresh_instructor_ratings();
