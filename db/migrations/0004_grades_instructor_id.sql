-- Link grade rows to instructor identities, and admit Testudo as a source of
-- instructor attribution.

/* ========================= instructor_id link =========================== */

-- Nullable, and stays nullable. Roughly 3% of grade rows name no instructor in
-- any section of the course, and a handful more will sit in
-- `instructor_match_queue` waiting on a human at any given time. Both are
-- normal states, not errors.
--
-- `on delete set null` rather than cascade: losing an instructor record must
-- never delete grade rows, which are a public record obtained by MPIA request
-- and not reproducible from anywhere.
alter table grades
    add column if not exists instructor_id bigint
        references instructors (id) on delete set null;

create index if not exists grades_instructor_id_idx
    on grades (instructor_id);
create index if not exists grades_instructor_id_course_idx
    on grades (instructor_id, course_code);

-- `instructor_name` stays. It is the audit trail: what the registrar actually
-- wrote, before any resolution happened. When a match turns out to be wrong,
-- this is the only way to tell what it was matched *from*.
comment on column grades.instructor_id is
    'Resolved instructor. Null where the export named nobody, or where the '
    'name is still in instructor_match_queue. Backfilled by '
    'scripts/backfill_instructor_ids.py, maintained by the loader thereafter.';


/* ========================== the testudo tier ============================ */

-- A fourth provenance tier for instructor attribution.
--
-- When the registrar leaves a section's instructor blank, the loader currently
-- carries the lead section's instructor forward. From the per-term ingest job
-- onward there is a better option: ask Testudo who was scheduled to teach that
-- exact section. That is a real attribution for that section rather than an
-- inference from a neighbouring one.
--
-- Precedence: reported > testudo > lead > course.
--
-- It is its own tier because it is not as good as `reported`. Testudo lists
-- the *scheduled* instructor, who is not always the person who taught the
-- course or assigned the grades, and this distinction has to survive into the
-- UI rather than being quietly folded into the registrar's own attributions.
--
-- This only improves data going forward. Testudo keeps a few years of past
-- terms online; it cannot retroactively fix 2011.
alter table grades drop constraint if exists grades_instructor_source_check;
alter table grades add constraint grades_instructor_source_check
    check (instructor_source in ('reported', 'lead', 'course', 'testudo'));


/* ====================== matview refresh bookkeeping ===================== */

-- A stale materialized view has no symptom. The site serves last term's
-- numbers and looks entirely healthy, which is why the refresh result is
-- recorded per ingest and `ci.py` fails when the newest ingest has no
-- successful refresh against it.
alter table grade_ingests
    add column if not exists matviews_refreshed_at timestamptz,
    add column if not exists matview_refresh_ms    int;
