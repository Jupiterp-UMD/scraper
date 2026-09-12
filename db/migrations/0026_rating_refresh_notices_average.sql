-- Let the rating refresh notice a stale `average_rating`.
--
-- `refresh_instructor_ratings` writes four columns but decided whether to write
-- them by comparing only three. A row whose jupiterp_rating,
-- jupiterp_review_count, and combined_rating all already matched was skipped --
-- even when its `average_rating` did not match, because that column was never
-- part of the test.
--
-- Every instructor imported from PlanetTerp arrived with a legacy
-- `average_rating`, and for 3,195 of them the model then decided there was not
-- enough evidence to publish a rating at all: `combined_rating` null. Those
-- rows were skipped forever, so the legacy value stayed.
--
-- The two columns feed different screens, so the disagreement was visible:
--
--     Andrew Baldwin, 1 PlanetTerp review
--       planner (average_rating):   5 stars
--       professor page (combined):  "Not enough reviews yet."
--
-- `average_rating` is the v0 API field the course planner reads for its star
-- ratings; `combined_rating` is the model's own answer. They are meant to be
-- the same number, with `average_rating` kept only so existing clients keep
-- working. Adding it to the comparison is the whole fix -- the assignment was
-- already correct.

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
            end
         or i.average_rating        is distinct from case
                when c.total_weight >= cfg.min_weight_to_display then c.combined_rating::real
                else null
            end);

    get diagnostics affected = row_count;
    return affected;
end;
$function$;
