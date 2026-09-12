-- Show a rating as soon as there is at least one review.
--
-- `min_weight_to_display` was 3.0, so a professor needed roughly three reviews
-- before any rating appeared: PlanetTerp weight is
-- `min(review_count, cap) * 0.5^(age / half_life)`, which for a fresh snapshot
-- is close to the review count. Two reviews scored 2 and showed "Not enough
-- reviews yet."
--
-- Zero is safe rather than a special case, because the model already refuses to
-- invent a number: `refresh_instructor_ratings` returns null when the combined
-- weight is zero, before the threshold is consulted at all. So a professor with
-- no reviews still displays nothing, and the threshold only decides how much
-- evidence is needed beyond the first review -- which is now none.
--
-- What this does NOT change is how much a single review moves the displayed
-- number. `shrinkage_reviews` is 5.0, meaning every professor is treated as
-- carrying five notional reviews sitting at the global mean, so one 5-star
-- review lands well below 5. That is deliberate and separate: the threshold
-- decides whether to show a rating, shrinkage decides what it is. Lower
-- `shrinkage_reviews` if single reviews should read closer to face value,
-- knowing that makes early ratings much noisier.

update rating_config set min_weight_to_display = 0;

select refresh_instructor_ratings();
