-- Dump the definitions of every object this project created through the
-- Supabase dashboard, so they exist in version control before anything here
-- starts rewriting them.
--
--   psql "$DATABASE_DIRECT_URL" -Atf db/baseline/capture.sql \
--        > db/baseline/current_schema.sql
--
-- Run this BEFORE migration 0003, which replaces `active_instructors`. Its
-- current definition exists nowhere else: it was written in the dashboard and
-- never committed, so this is the only chance to record what it used to say.

\pset format unaligned
\pset tuples_only on
\pset footer off

select '-- Captured ' || now()::text || E'\n';

-- Views, in dependency order as far as pg_class ordering gives it.
select E'\n/* ---------- views ---------- */\n';

select format(
           E'create or replace view %I as\n%s\n',
           c.relname,
           pg_get_viewdef(c.oid, true)
       )
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'v'
order by c.relname;

-- Table shapes. Not a faithful DDL dump — enough to diff against, and enough
-- to notice a column that no migration here accounts for.
select E'\n/* ---------- tables ---------- */\n';

select format(
           E'-- %I.%I  %s%s%s',
           table_name,
           column_name,
           data_type,
           case when is_nullable = 'NO' then ' not null' else '' end,
           case when column_default is not null
                then ' default ' || column_default else '' end
       )
from information_schema.columns
where table_schema = 'public'
order by table_name, ordinal_position;

-- Constraints and indexes, which is where the surprises usually are.
select E'\n/* ---------- indexes ---------- */\n';

select indexdef || ';'
from pg_indexes
where schemaname = 'public'
order by tablename, indexname;

select E'\n/* ---------- row level security ---------- */\n';

select format(
           '-- %I: rls %s',
           c.relname,
           case when c.relrowsecurity then 'enabled' else 'DISABLED' end
       )
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
order by c.relname;

select format(
           E'-- policy %I on %I: %s for %s',
           policyname, tablename, cmd, coalesce(array_to_string(roles, ','), 'public')
       )
from pg_policies
where schemaname = 'public'
order by tablename, policyname;
