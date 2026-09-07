-- Retire `refresh_active_instructors()`, and close the gap that hid it.
--
-- Found by applying 0030 to the clone and then reading the live catalog rather
-- than the migration files. 0030 enumerated the functions to lock by grepping
-- `db/migrations/` and `grades/schema.sql`, which is every function this
-- repository creates -- and not every function the database has. This one was
-- created through the Supabase dashboard, so it appears in no file here. It is
-- the same gap `db/README.md` documents for the baseline tables: "their
-- definitions exist only in the database."
--
-- It is also dead. The body is:
--
--     refresh materialized view active_instructors;
--
-- and `active_instructors` has been a plain view since 0003 reworked it, so
-- every call raises `"active_instructors" is not a materialized view`. Nothing
-- in any of the four repositories calls it -- API, scraper, site, and npm
-- client were all searched -- and PostgREST exposes it as
-- `POST /rest/v1/rpc/refresh_active_instructors` to `anon`, where it is an
-- error message on the public RPC surface and nothing else.
--
-- Revoke first, then drop. The revoke is not redundant: if the drop is ever
-- rolled back or the function is recreated from a dashboard snapshot, the
-- default PUBLIC grant comes back with it, and 0030's `alter default
-- privileges` only covers functions created by the migration role.

revoke execute on function refresh_active_instructors() from public, anon, authenticated;

drop function if exists refresh_active_instructors();

-- Guard against the next one.
--
-- 0030 locked what this repository knows about. This asserts there is nothing
-- left in `public` that anon can execute except the three deliberate helpers
-- and the extension-owned functions -- so a routine added through the
-- dashboard, which is how the one above arrived, fails this migration instead
-- of sitting unnoticed on the public RPC surface.
--
-- Extension functions are excluded because they must stay callable: anon calls
-- normalize_name(), whose body calls unaccent(), and revoking the extension's
-- functions breaks trigram search along with it. That is also why 0030 revokes
-- per function rather than using `revoke execute on all functions in schema
-- public`, which would have taken those with it.
do $$
declare
    stragglers text;
begin
    select string_agg(p.proname, ', ' order by p.proname)
      into stragglers
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and has_function_privilege('anon', p.oid, 'EXECUTE')
       -- Deliberately public: pure, side-effect free, and load-bearing for
       -- reads. See the note in 0030.
       and p.proname not in ('normalize_name', 'slugify', 'umd_gpa')
       -- Trigger functions cannot be invoked directly and are not exposed by
       -- PostgREST; their EXECUTE is checked at CREATE TRIGGER time.
       and p.prorettype <> 'pg_catalog.trigger'::regtype
       -- Owned by an extension, not by us.
       and not exists (
           select 1 from pg_depend d
            where d.objid = p.oid
              and d.classid = 'pg_proc'::regclass
              and d.deptype = 'e'
       );

    if stragglers is not null then
        raise exception
            'these public functions are still executable by anon: %. '
            'Add them to the revoke list (or to the deliberate-public list) '
            'before this migration can pass.', stragglers;
    end if;
end;
$$;
