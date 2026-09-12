-- Fix the type error that made every rating recompute fail.
--
-- 0009 wrote the displayed rating back to `instructors.average_rating` with
-- `c.combined_rating::text`, on the stated reasoning that average_rating is
-- "the v0 string field". It is not: it is `real`, and always has been -- the
-- v0 API has been serving it as a JSON number the whole time.
--
-- So every call failed on the assignment:
--
--     42804: column "average_rating" is of type real but expression is of
--            type text
--
-- The sweep calls this on every run and only logs the failure, so nothing
-- surfaced it. Ratings have never been recomputed: `jupiterp_rating`,
-- `combined_rating`, and `average_rating` keep whatever the PlanetTerp
-- snapshot left, and a professor's rating would never move no matter how many
-- reviews were approved.
--
-- Only the cast changes; the model is untouched.
CREATE OR REPLACE FUNCTION public.refresh_instructor_ratings()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
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
               when c.total_weight >= cfg.min_weight_to_display then c.combined_rating::real
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
$function$

;
