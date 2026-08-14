-- The rating model: recency-decayed Jupiterp reviews, blended with the frozen
-- PlanetTerp baseline, shrunk toward the global mean.
--
-- Ratings are recomputed on a schedule rather than by a trigger. The decay
-- makes them time-dependent: a professor's rating changes as their reviews
-- age, on days when nobody reviews anything. A trigger cannot express that.

/* =============================== config ================================= */

-- One row. These constants are guesses, and this table exists so that saying
-- so has consequences: the sensitivity sweep below re-runs the whole model
-- with different values without a deploy, and the answer to "does this
-- parameter matter?" is a query rather than a project.
create table if not exists rating_config (
    id boolean primary key default true check (id),

    -- Half-life of a Jupiterp review's weight, in years.
    --
    -- Four years has a defensible anchor rather than a published one: it is
    -- roughly one undergraduate cohort, so a review falls to half weight about
    -- when the last student who could have taken that section has graduated.
    -- Published half-lives (7 days for ad attribution, ~150 days for movie
    -- ratings) come from domains with nothing in common with course reviews.
    review_half_life_years numeric not null default 4.0,

    -- Half-life of the PlanetTerp baseline, from its snapshot date. Shorter,
    -- because it is a frozen number that ages badly rather than a stream.
    pt_half_life_years numeric not null default 2.0,

    -- After this many years the PlanetTerp contribution is dropped entirely
    -- rather than left as a vanishing tail.
    pt_max_age_years numeric not null default 6.0,

    -- Cap on PlanetTerp's weight, in equivalent reviews. Without it a
    -- professor with 400 PlanetTerp reviews stays pinned to their 2026 rating
    -- long after Jupiterp has better data.
    pt_weight_cap numeric not null default 50,

    -- Bayesian shrinkage strength, in equivalent reviews at the global mean.
    --
    -- Once the PlanetTerp weight decays to zero, nothing otherwise pulls a
    -- three-review professor toward the middle, and a 3-review 4.9 outranks a
    -- 60-review 4.6 in every sort. This makes the sort order sane rather than
    -- merely hiding the worst cases.
    shrinkage_reviews numeric not null default 5.0,

    -- Below this much total weight, no rating is displayed at all. A blunt
    -- version of the same idea as shrinkage, kept because "4.2" and "not
    -- enough reviews yet" are different claims and the second is honest.
    min_weight_to_display numeric not null default 3.0,

    updated_at timestamptz not null default now()
);

insert into rating_config (id) values (true) on conflict (id) do nothing;


/* ============================ the computation =========================== */

-- Compute every instructor's rating under a given set of constants.
--
-- Parameterised rather than hardcoded so that the sensitivity sweep is this
-- same function with different arguments. If rankings barely move between a
-- two-year and an eight-year half-life, the parameter does not matter and can
-- stop being discussed; if they move a lot, the uncertainty is real.
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

    -- The prior. Weighted by the same decay as everything else, so it is the
    -- mean of what the site currently believes rather than of all history.
    -- Falls back to the scale midpoint before any reviews exist, which is the
    -- only defensible value when there is nothing to average.
    select coalesce(
               sum(r.rating * power(0.5, (extract(epoch from now() - r.submitted_at) / 31557600.0) / review_hl))
               / nullif(sum(power(0.5, (extract(epoch from now() - r.submitted_at) / 31557600.0) / review_hl)), 0),
               3.0)
      into global_mean
      from reviews r
     where r.status = 'approved';

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
        -- sitting at the global mean.
        case
            when coalesce(j.w, 0) + coalesce(p.w, 0) <= 0 then null
            else round(
                (shrink * global_mean
                 + coalesce(j.weighted_sum, 0)
                 + coalesce(p.w, 0) * coalesce(p.pt_rating, 0))
                / (shrink + coalesce(j.w, 0) + coalesce(p.w, 0)),
                2)
        end,
        round(coalesce(j.w, 0) + coalesce(p.w, 0), 4)
    from instructors i
    left join jupiterp   j on j.iid = i.id
    left join planetterp p on p.iid = i.id;
end;
$$;


-- Write the computed ratings back onto `instructors`. Run nightly.
--
-- `combined_rating` is left null below the display floor rather than written
-- and hidden by the UI, so that anything sorting or filtering on the column --
-- the professor directory, a future API consumer -- gets the same answer the
-- page shows.
create or replace function refresh_instructor_ratings()
returns int
language plpgsql
as $$
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
           combined_rating       = case
               when c.total_weight >= cfg.min_weight_to_display then c.combined_rating
               else null
           end,
           -- The v0 string field stays aliased to the displayed rating so
           -- existing clients keep working through the semantic change.
           average_rating = case
               when c.total_weight >= cfg.min_weight_to_display then c.combined_rating::text
               else null
           end
      from computed c
     where c.instructor_id = i.id
       and (i.jupiterp_rating       is distinct from c.jupiterp_rating
         or i.jupiterp_review_count is distinct from c.jupiterp_reviews
         or i.combined_rating       is distinct from case
                when c.total_weight >= cfg.min_weight_to_display then c.combined_rating
                else null
            end);

    get diagnostics affected = row_count;
    return affected;
end;
$$;

comment on function refresh_instructor_ratings() is
    'Recompute and store every instructor rating. Nightly. Ratings decay with '
    'time, so they change on days when no review does.';


/* =========================== sensitivity sweep ========================== */

-- How much does the half-life actually matter?
--
-- Returns the top instructors under each of several half-lives, so the
-- rankings can be compared directly. Run it after a semester of real reviews:
-- if the ordering barely moves, the constant is not worth arguing about.
create or replace view rating_sensitivity_sweep as
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

revoke all on rating_sensitivity_sweep from anon, authenticated;
