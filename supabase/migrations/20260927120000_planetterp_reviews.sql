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
-- `instructors.pt_slug` in the view. That is what makes a merge carry them:
-- `merge_instructors()` already moves the donor's `pt_slug` onto the survivor,
-- so no change there either. A slug no instructor holds is kept, just not shown.

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
