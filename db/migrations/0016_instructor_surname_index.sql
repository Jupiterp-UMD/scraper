-- Index the surname expression the resolver actually filters on.
--
-- Every stage of resolve_instructor() narrows candidates with
-- `name_surname(i.name_norm) = surname` before doing anything else. Nothing
-- indexed that expression, so each call sequentially scanned all 14,018
-- instructor rows and evaluated name_surname() on every one of them --
-- measured at ~21ms per resolution.
--
-- That cost is paid once per distinct name, so the grade backfill pays it
-- 13,958 times (~5 minutes of pure database work) and the nightly Testudo
-- scrape pays it for every name in the scrape, forever. This index is worth
-- more to the recurring job than to the one-off backfill.
--
-- The existing GIN trigram indexes do not help here. `instructors_name_trgm_idx`
-- is only usable by the `%` operator; stage 4 filters with
-- `similarity(a, b) >= 0.85`, a plain function call, which the planner cannot
-- answer from a trigram index. Surname equality is far more selective anyway
-- -- it reduces 14,018 rows to the handful sharing a surname -- so this index
-- is what makes every stage cheap, and the trigram scan then runs over a few
-- rows rather than the whole table.
--
-- name_surname() is IMMUTABLE, so the expression is indexable as written.
create index if not exists instructors_surname_idx
    on instructors (name_surname(name_norm));

comment on index instructors_surname_idx is
    'Candidate narrowing for resolve_instructor(). Every resolution stage '
    'filters on name_surname(name_norm) before scoring.';
