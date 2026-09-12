-- Reviews: submission, verification, moderation, and abuse forensics.
--
-- Hosting student reviews of named, identifiable individuals is a materially
-- different liability posture than hosting a course catalogue, and the schema
-- carries most of the weight of that. Three invariants are structural rather
-- than enforced in application code, because application code is where this
-- eventually goes wrong:
--
--   1. No review is readable before it is approved. Public reads go through
--      `public_reviews`, a view over `status = 'approved'` that does not
--      select the identity columns at all. The anon role has no grant on
--      `reviews` itself.
--   2. Raw email addresses are never stored. Only a peppered SHA-256.
--   3. Every moderation decision, automated or human, is recorded. That is
--      both the audit trail and the only way to tell whether the automated
--      triage is any good.

/* =============================== status ================================= */

-- 'unverified' submitted, email not yet confirmed
-- 'pending'    verified, awaiting a triage decision
-- 'escalated'  automated triage declined to decide; a human must act
-- 'approved'   publicly visible
-- 'rejected'   refused; the reviewer may appeal or resubmit
-- 'withdrawn'  retracted by the reviewer
do $$
begin
    if not exists (select 1 from pg_type where typname = 'review_status') then
        create type review_status as enum
            ('unverified', 'pending', 'escalated', 'approved', 'rejected', 'withdrawn');
    end if;
end
$$;


/* =============================== reviews ================================ */

create table if not exists reviews (
    id            uuid primary key default gen_random_uuid(),
    instructor_id bigint not null references instructors (id) on delete cascade,

    -- Nullable: a review of the professor generally, not of one course.
    course_code   text,
    term          int,

    -- 1-5 in half steps. numeric(2,1), NOT smallint: the scale matches
    -- PlanetTerp's so the imported baseline blends without rescaling, and the
    -- half step is Jupiterp's own addition. The constraint enforces half steps
    -- rather than any decimal, so 4.3 is refused by the database instead of
    -- being silently averaged in.
    rating numeric(2,1) not null
        check (rating >= 1 and rating <= 5 and rating * 2 = floor(rating * 2)),

    expected_grade text check (expected_grade in
        ('A+','A','A-','B+','B','B-','C+','C','C-','D+','D','D-','F','W','Other')),
    title text check (char_length(title) <= 120),
    body  text check (char_length(body)  <= 5000),

    status review_status not null default 'unverified',

    -- Identity. The raw address is NEVER stored.
    --
    -- The pepper lives in Secret Manager, not in the database, so a database
    -- disclosure alone does not permit dictionary attacks against a small
    -- address space (a university's addresses are highly guessable). Treat it
    -- as permanent: rotating it invalidates every dedupe check ever made.
    email_hash   text not null,
    email_domain text not null,

    -- sha256 of the manage key, which is shown to the reviewer once.
    edit_key_hash text not null,

    -- Abuse forensics. Hashed, and purged on the schedule in the privacy
    -- policy rather than kept indefinitely.
    submit_ip_hash  text,
    user_agent_hash text,

    submitted_at timestamptz not null default now(),
    verified_at  timestamptz,
    moderated_at timestamptz,
    moderator    text,
    reject_reason text,
    edited_at    timestamptz,

    -- Automated triage scheduling. `next_triage_at` is set when a
    -- classification is deferred because the daily model quota is exhausted;
    -- null when no retry is pending. `triage_attempts` caps the retry loop so
    -- a permanently broken API key escalates to a human instead of parking
    -- reviews forever.
    triage_attempts int not null default 0,
    next_triage_at  timestamptz,

    -- Reserved for a future accounts system. Always null in v1. Present now
    -- so that adding accounts later is not a data migration.
    user_id uuid
);

-- One live review per person per professor per course.
--
-- Partial: a rejected or withdrawn review does not block a resubmission, which
-- is what makes the appeal path work.
create unique index if not exists reviews_one_per_person
    on reviews (instructor_id, coalesce(course_code, ''), email_hash)
    where status in ('unverified', 'pending', 'approved');

create index if not exists reviews_instructor_approved_idx
    on reviews (instructor_id, submitted_at desc) where status = 'approved';

create index if not exists reviews_moderation_idx
    on reviews (status, submitted_at) where status in ('pending', 'escalated');

-- Drives the deferred-triage retry sweep.
create index if not exists reviews_triage_retry_idx
    on reviews (next_triage_at) where next_triage_at is not null;

-- Drives the abandoned-submission purge.
create index if not exists reviews_unverified_idx
    on reviews (submitted_at) where status = 'unverified';


/* ========================= moderation decisions ========================= */

-- Every triage decision ever made, automated or human. Append-only.
--
-- This is the audit trail for the first time someone disputes a decision, and
-- the dataset for measuring whether the automated classifier actually agrees
-- with human judgement before it is allowed to act on its own.
create table if not exists moderation_decisions (
    id         bigserial primary key,
    review_id  uuid not null references reviews (id) on delete cascade,
    decision   text not null check (decision in ('approve', 'reject', 'escalate')),
    decided_by text not null check (decided_by in ('ai', 'human', 'rule')),

    -- A moderator identifier, or the pinned model id. Pinning matters: a
    -- provider silently swapping the model under a moderation pipeline is a
    -- change to the publishing policy that nobody decided to make.
    actor      text not null,
    -- Prompt/ruleset version, so a decision can be reproduced later.
    policy_version text,

    confidence real,      -- null for human decisions
    categories text[],    -- policy categories the classifier flagged
    reason     text,
    -- Whether this decision was applied to `reviews.status` or only recorded.
    -- False for every row during the shadow period, which is what makes
    -- enabling automation a config change rather than a code change.
    applied    boolean not null default false,
    raw_response jsonb,
    created_at timestamptz not null default now()
);

create index if not exists moderation_decisions_review_idx
    on moderation_decisions (review_id, created_at desc);

-- Supports the shadow-mode agreement query: how often did the classifier and
-- the human reach the same verdict on the same review?
create index if not exists moderation_decisions_agreement_idx
    on moderation_decisions (decided_by, decision, created_at desc);


/* ================================ tokens ================================ */

create table if not exists review_tokens (
    token_hash text primary key,
    review_id  uuid not null references reviews (id) on delete cascade,
    -- 'verify'   emailed to the reviewer to confirm their address
    -- 'manage'   returned once; lets the reviewer edit or withdraw
    -- 'moderate' reserved for a future emailed moderation path. Unused: a
    --            decision link that can be forwarded is a decision anyone can
    --            take, so escalations link to the authenticated queue instead.
    purpose    text not null check (purpose in ('verify', 'manage', 'moderate')),
    expires_at timestamptz not null,
    used_at    timestamptz,
    created_at timestamptz not null default now()
);

create index if not exists review_tokens_review_idx on review_tokens (review_id, purpose);
create index if not exists review_tokens_expiry_idx on review_tokens (expires_at) where used_at is null;


/* ================================ reports =============================== */

-- A professor's entire recourse path in v1. There is no right of reply, which
-- makes the response time on these load-bearing rather than a nicety.
create table if not exists review_reports (
    id         bigserial primary key,
    review_id  uuid not null references reviews (id) on delete cascade,
    reason     text not null,
    detail     text,
    reporter_email_hash text,
    created_at timestamptz not null default now(),
    resolved_at timestamptz,
    resolution text
);

create index if not exists review_reports_open_idx
    on review_reports (created_at) where resolved_at is null;


/* ============================= email outbox ============================= */

-- Queued transactional email.
--
-- The provider has a daily send cap. The obvious response to hitting it --
-- letting submissions through without verification -- would make exhausting
-- the cap a way to bypass email verification entirely, and verification is
-- what backs the "this is a real UMD student" claim, the per-email dedupe,
-- and most of the abuse defences. So sends are queued instead: the review
-- stays 'unverified', the message is retried after the cap resets, and
-- nothing is lost or let through.
create table if not exists email_outbox (
    id          bigserial primary key,
    review_id   uuid references reviews (id) on delete cascade,
    -- The recipient is stored encrypted-at-rest by the provider, not here.
    -- We hold it only long enough to send, then null it.
    recipient   text,
    template    text not null check (template in
        ('verify', 'manage_key', 'rejected', 'resend_verify')),
    payload     jsonb not null default '{}'::jsonb,

    status      text not null default 'queued'
        check (status in ('queued', 'sent', 'failed', 'abandoned')),
    attempts    int not null default 0,
    next_attempt_at timestamptz not null default now(),
    last_error  text,
    created_at  timestamptz not null default now(),
    sent_at     timestamptz
);

create index if not exists email_outbox_due_idx
    on email_outbox (next_attempt_at) where status = 'queued';

comment on table email_outbox is
    'Queued transactional mail. Exists so that hitting the provider daily cap '
    'defers a send rather than bypassing email verification.';


/* ============================= rate limiting ============================ */

-- Rate-limit state in Postgres rather than in process memory.
--
-- Cloud Run autoscales, so an in-memory limiter is per-instance and is
-- bypassed by retrying until you land on a cold one. Capping instances kills
-- availability; a managed Redis adds a VPC connector, a standing cost, and a
-- new failure mode. A counter table is slower per request and entirely
-- adequate at this volume, and it sits in the same database as the triage
-- retry queue, so there is one place to reason about counters.
create table if not exists rate_limit_counters (
    bucket       text        not null,   -- 'ip:<hash>' | 'email:<hash>' | 'instructor:<id>'
    action       text        not null,
    window_start timestamptz not null,
    count        int         not null default 0,
    primary key (bucket, action, window_start)
);

create index if not exists rate_limit_counters_window_idx
    on rate_limit_counters (window_start);

-- Increment and report the new count, atomically.
--
-- Called inside the same transaction as the write it guards, so two concurrent
-- submissions cannot both read a count below the limit and both proceed.
create or replace function bump_rate_limit(
    p_bucket text,
    p_action text,
    p_window interval
)
returns int
language plpgsql
as $$
declare
    w timestamptz := date_trunc('second', now()) - (
        extract(epoch from (now() - date_trunc('day', now())))::bigint
        % greatest(extract(epoch from p_window)::bigint, 1)
    ) * interval '1 second';
    n int;
begin
    insert into rate_limit_counters (bucket, action, window_start, count)
    values (p_bucket, p_action, w, 1)
    on conflict (bucket, action, window_start)
    do update set count = rate_limit_counters.count + 1
    returning count into n;

    return n;
end;
$$;


/* ============================ public read view ========================== */

-- The only path by which a review reaches the public.
--
-- A view rather than a policy on the base table, so the identity columns
-- cannot be selected at all -- not merely filtered. `security_invoker = off`
-- (the default) means it runs as its owner, so revoking anon's access to
-- `reviews` does not break it.
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
    r.edited_at
from reviews r
join instructors i on i.id = r.instructor_id
where r.status = 'approved';

comment on view public_reviews is
    'The only public path to review content. Approved rows only, and the '
    'identity columns are not selectable through it at all.';


/* ================================= RLS ================================== */

alter table reviews              enable row level security;
alter table review_tokens        enable row level security;
alter table review_reports       enable row level security;
alter table moderation_decisions enable row level security;
alter table email_outbox         enable row level security;
alter table rate_limit_counters  enable row level security;

-- No policies at all: RLS with no policy denies everything to non-superusers,
-- and the service role bypasses RLS. That is the whole access model for these
-- tables -- the API's write path holds the service key, and nothing else
-- touches them.
--
-- The revokes are belt and braces. Row-level security is the backstop here,
-- not the perimeter: the /v1 handlers are the perimeter, and this has to be
-- correct on the assumption that one of them is one day wrong.
revoke all on reviews              from anon, authenticated;
revoke all on review_tokens        from anon, authenticated;
revoke all on review_reports       from anon, authenticated;
revoke all on moderation_decisions from anon, authenticated;
revoke all on email_outbox         from anon, authenticated;
revoke all on rate_limit_counters  from anon, authenticated;

grant select on public_reviews to anon, authenticated;
