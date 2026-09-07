-- One writer for "who is teaching", instead of two that agree by convention.
--
-- After 0032 and 0034 there were two independent answers to that question,
-- computed from different inputs by two RPCs that are individually atomic and
-- not atomic with each other:
--
--   * `instructors.is_active`, set by `set_active_instructors(p_ids)` from the
--     ids `reconcile_instructors()` resolved this scrape.
--   * `active_instructors`, a view defined (0003) as "instructors with a row in
--     `section_instructors`", which `swap_section_instructors()` replaces.
--
-- `instructor_registry.reconcile_instructors` calls them in sequence, so a
-- failure between the two leaves the halves disagreeing. That disagreement is
-- invisible, because the two halves are read by different consumers:
-- `/v1/instructors/active` and `/v1/instructors?activeOnly=true` are documented
-- as the same predicate, and today the first reads the view while the second
-- filters on the column (`supabase.go`). The site reads the column again for
-- the "currently teaching" badge on a professor page and for sitemap priority.
-- A drift shows up as a professor whose page says they teach, who is missing
-- from the planner's ratings lookup -- and it is cached for up to 24 hours by
-- the same TTL chain 0032 and 0034 exist to protect.
--
-- Picking the column as the definition, rather than the table:
--
--   * It is the one the API already filters on for `activeOnly`, so the two
--     endpoints stop being two implementations of one sentence.
--   * `set_active_instructors` refuses an empty id list, which makes "no
--     instructor is active" unreachable through the supported path. The view
--     had no such guard of its own; it inherited one from
--     `swap_section_instructors`.
--   * It is dramatically cheaper. See the index below.
--
-- `section_instructors` is NOT going away: it holds the foreign key to
-- `instructors` and is what `instructor_match_queue_detail` reads. It simply
-- stops being the definition of this view.
--
-- Verified equivalent before the swap: at 8,586 links / 2,976 instructors the
-- two definitions selected the same 2,976 rows, with an empty difference in
-- both directions.


-- The reason this is not just a lateral move.
--
-- The old view's `exists()` cost a semi-join into `section_instructors` for
-- every candidate row, and the planner cannot use the ordering the API asks
-- for (`slug.asc`, the default since paging without a total order was dropping
-- rows) to stop early. `where is_active` alone is worse for `count=true` --
-- 20% of the table is active, so it is a sequential scan over 15,000 wide
-- instructor rows.
--
-- A partial index on the ordering column, restricted to the rows the view
-- keeps, answers both shapes from the index:
--
--   select slug, average_rating ... order by slug limit 500
--       exists():        171 ms
--       is_active only:    1.2 ms
--       with this index:   1.1 ms
--   select count(*)
--       exists():        162 ms
--       is_active only:  316 ms   <- the regression this index exists to avoid
--       with this index:   2.4 ms
--
-- `count=true` is not hypothetical: the professor directory requests it on
-- every search. The index also serves `/v1/instructors?activeOnly=true`, which
-- has been filtering on this column without one since 0002.
--
-- Not `concurrently`: the runner wraps each migration in a transaction, which
-- forbids it. The table is 15,000 rows and the build takes well under a second.
create index if not exists instructors_active_slug_idx
    on instructors (slug)
    where is_active;


-- `create or replace`, deliberately, not drop-and-create: the column list is
-- unchanged (all seventeen of `instructors`, same order), so replace is legal,
-- and it preserves the `select` grants 0006 gave anon and authenticated and
-- 0010 gave service_role. A drop would silently take those with it and the
-- endpoint would start 401ing for everyone who is not the service role.
create or replace view active_instructors as
select i.*
from instructors i
where i.is_active;

comment on view active_instructors is
    'Instructors currently teaching, per `instructors.is_active`. That column '
    'is the single definition of active; `set_active_instructors()` is its only '
    'writer and refuses an empty scrape. Was defined over `section_instructors` '
    'until 0035.';

comment on column instructors.is_active is
    'Whether this instructor teaches a section in the current Testudo scrape. '
    'The definition of "active" for both `/v1/instructors/active` (via the '
    'active_instructors view) and `/v1/instructors?activeOnly=true`. Written '
    'only by set_active_instructors(); do not set it by hand.';
