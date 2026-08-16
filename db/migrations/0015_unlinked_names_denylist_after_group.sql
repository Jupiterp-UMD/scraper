-- Apply the denylist after grouping, not before.
--
-- 0014 assumed the aggregation in 0013 was slow because normalize_name() ran
-- per row. It was not. Measured against the two halves separately:
--
--   group by normalize_name(...)                              1.8s
--   ... and not is_instructor_denylisted(instructor_name)     13.4s
--
-- The denylist check was the whole cost. It was in the WHERE clause, so it ran
-- once per grade row -- 200,926 calls -- to reject a handful of names.
--
-- It only ever depends on the name, and 0007 defines it to normalize its input
-- before matching, so every raw spelling that shares a normalized form shares
-- a denylist verdict. Filtering the grouped output is therefore identical in
-- result and runs 13,958 times instead of 200,926. Measured at 2.6s, same
-- 13,958 rows out.
--
-- The index from 0014 is kept: it is genuinely used, supplying pre-sorted
-- normalized values straight to a GroupAggregate.
--
-- The statement_timeout override from 0014 is dropped. It never applied to the
-- outer call that was actually timing out -- a function-local SET governs
-- statements inside the body -- and attaching any SET clause to a SQL function
-- makes it non-inlinable, so it cost something and bought nothing.

alter function unlinked_instructor_names(int, int) reset statement_timeout;

create or replace function unlinked_instructor_names(
    page_limit  int default 1000,
    page_offset int default 0
)
returns table (
    name_norm         text,
    observed          text,
    variants          text[],
    row_count         bigint,
    course_code       text,
    term              int,
    sec_code          text,
    instructor_source text
)
language sql
stable
set search_path = public, extensions, pg_catalog
as $$
    with kept as (
        select g.instructor_name,
               normalize_name(g.instructor_name) as nn,
               g.course_code, g.term, g.sec_code, g.instructor_source
        from grades g
        where g.instructor_name is not null
          and g.instructor_id is null
          and normalize_name(g.instructor_name) is not null
    ),
    grouped as (
        select nn,
               (array_agg(instructor_name   order by term desc, instructor_name))[1] as observed,
               array_agg(distinct instructor_name)                                   as variants,
               count(*)                                                              as row_count,
               (array_agg(course_code       order by term desc, instructor_name))[1] as course_code,
               (array_agg(term              order by term desc, instructor_name))[1] as term,
               (array_agg(sec_code          order by term desc, instructor_name))[1] as sec_code,
               (array_agg(instructor_source order by term desc, instructor_name))[1] as instructor_source
        from kept
        group by nn
    )
    select name_norm, observed, variants, row_count,
           course_code, term, sec_code, instructor_source
    from (
        select nn as name_norm, observed, variants, row_count,
               course_code, term, sec_code, instructor_source
        from grouped
        where not is_instructor_denylisted(observed)
    ) filtered
    order by name_norm
    limit page_limit offset page_offset
$$;
