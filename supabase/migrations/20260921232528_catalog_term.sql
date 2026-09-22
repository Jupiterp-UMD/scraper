-- catalog_term: which Testudo term `courses` and `sections` currently hold.
--
-- The catalog tables are one term only, and nothing recorded which. The term
-- lived in the scraper's workflow files (`main.py --term 202608`), so the site
-- hardcoded the same code in its header label and Testudo links, and moving to
-- a new semester meant editing both repos in step. Now the scraper writes the
-- term it uploaded here, the API serves it at `/v1/term`, and the site
-- reads it from there.
--
-- One row, keyed like `rating_config`. The scraper upserts it on every run, so
-- the row appears on the first scrape after this migration; until then the
-- endpoint returns `[]` and the site shows no term rather than a wrong one.

create table catalog_term (
    id boolean primary key default true check (id),

    -- Six-digit Testudo term code: the year, then the month the term starts.
    -- 202608 is Fall 2026, 202701 Spring 2027. The month check rejects a
    -- mistyped `--term` before the site renders it as a label.
    term int not null check (term between 190001 and 299912 and term % 100 in (1, 5, 8, 12)),

    updated_at timestamptz not null default now()
);

create trigger catalog_term_touch_updated_at
    before update on catalog_term
    for each row execute function touch_updated_at();

comment on table catalog_term is
    'The Testudo term the catalog tables (courses, sections) were scraped from. '
    'One row, upserted by the scraper on every run.';

-- Public, like the catalog it describes.
alter table catalog_term enable row level security;

create policy catalog_term_public_read on catalog_term
    for select using (true);

-- Starts from no grants, for the reason given in 20260912200959: production's
-- default privileges would otherwise hand anon write access.
revoke all on table catalog_term from anon, authenticated, service_role;

grant select on catalog_term to anon, authenticated;

-- The scraper.
grant select, insert, update on catalog_term to service_role;
