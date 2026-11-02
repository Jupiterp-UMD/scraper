-- Reviewer sessions: verify once, then review for a few hours without another
-- confirmation email.
--
-- A session needs two secrets to start, held in two different places:
--
--   * a session token, returned to the browser that submitted a review, and
--     kept there only if the reviewer opted in; and
--   * that review's emailed verification token.
--
-- The API activates a session only when one request presents both. Either alone
-- is worth nothing. Someone who submits with another person's address holds the
-- session token but never sees the email; a mail scanner that opens the link
-- holds the verification token but has no session token. Clicking the link in a
-- different browser confirms the review but starts no session.
--
-- Only the email round trip is skipped. Captcha, the per-IP and per-instructor
-- limits, validation, the one-per-person index and moderation all still run on
-- a session submit.
--
--   * Fixed lifetime from activation; using a session never extends it, and a
--     submit made through a session never mints another one.
--   * Capped uses, so a leaked token is worth a bounded number of reviews.
--   * Bound to the address hash; the API checks the submitted address against
--     it, so a stolen token cannot be used under any other identity.
--   * Revoked for the whole address the moment any of its reviews is rejected,
--     and never activated or honoured for an address with a rejected review.

create table reviewer_sessions (
    token_hash   text primary key,
    email_hash   text not null,
    -- The review whose verification activates this session. Cascades, so an
    -- abandoned submission purged by PurgeAbandoned takes its session with it.
    review_id    uuid not null references reviews (id) on delete cascade,
    activated_at timestamptz,
    expires_at   timestamptz,
    uses         int not null default 0 check (uses >= 0),
    created_at   timestamptz not null default now(),
    check ((activated_at is null) = (expires_at is null))
);

create index reviewer_sessions_review_idx on reviewer_sessions (review_id);
create index reviewer_sessions_email_idx on reviewer_sessions (email_hash);
create index reviewer_sessions_expiry_idx on reviewer_sessions (expires_at);

-- Serves the "has this address ever been rejected" check in the functions
-- below without scanning every review the address wrote.
create index reviews_rejected_email_idx on reviews (email_hash) where status = 'rejected';

comment on table reviewer_sessions is
    'Short-lived permission to submit reviews without a per-review confirmation '
    'email. Activated by presenting both the session token and the review''s '
    'verification token; bound to its address hash; revoked when any review '
    'from that address is rejected.';

alter table reviewer_sessions enable row level security;

revoke all on reviewer_sessions from anon, authenticated, service_role;
grant select, insert, update, delete on reviewer_sessions to service_role;


-- Starts the clock on whichever of `p_token_hashes` was issued with
-- `p_review_id`, and returns that session's hash and expiry; no row if none.
--
-- The caller has already checked the verification token for `p_review_id`.
-- `activated_at is null` makes this one-shot: replaying the link cannot restart
-- a session. An address with a rejected review gets no session, however the
-- link reached it.
create function activate_reviewer_session(
    p_review_id    uuid,
    p_token_hashes text[],
    p_lifetime     interval
)
returns table (token_hash text, expires_at timestamptz)
language sql
as $$
    update reviewer_sessions s
       set activated_at = now(),
           expires_at   = now() + p_lifetime
     where s.review_id = p_review_id
       and s.token_hash = any (p_token_hashes)
       and s.activated_at is null
       and not exists (
           select 1 from reviews r
            where r.email_hash = s.email_hash
              and r.status = 'rejected'
       )
    returning s.token_hash, s.expires_at;
$$;

comment on function activate_reviewer_session(uuid, text[], interval) is
    'Activate the session issued with a review, given the session tokens the '
    'browser holds. One-shot; refused for an address with a rejected review.';


-- Spends one use and reports whether the session was good for it.
--
-- A function rather than a read then a PATCH, because PostgREST cannot express
-- `uses = uses + 1`: two concurrent submits would both read the last use as
-- free. The row lock taken by the update serialises them.
create function consume_reviewer_session(
    p_token_hash text,
    p_email_hash text,
    p_max_uses   int
)
returns boolean
language sql
as $$
    with spent as (
        update reviewer_sessions s
           set uses = uses + 1
         where s.token_hash = p_token_hash
           and s.email_hash = p_email_hash
           and s.activated_at is not null
           and s.expires_at > now()
           and s.uses < p_max_uses
           -- Belt and braces with the trigger below, which deletes these
           -- rows on rejection; this holds if a row escapes it.
           and not exists (
               select 1 from reviews r
                where r.email_hash = s.email_hash
                  and r.status = 'rejected'
           )
        returning 1
    )
    select exists (select 1 from spent);
$$;

comment on function consume_reviewer_session(text, text, int) is
    'Spend one use of an active, unexpired reviewer session bound to the given '
    'address hash. True when a use was spent.';


-- Gives back a use spent on a submission that then failed -- a validation
-- error, a duplicate, an insert error -- so only reviews that land count
-- against the cap.
create function refund_reviewer_session(p_token_hash text)
returns void
language sql
as $$
    update reviewer_sessions
       set uses = uses - 1
     where token_hash = p_token_hash
       and uses > 0;
$$;

revoke all on function activate_reviewer_session(uuid, text[], interval),
                       consume_reviewer_session(text, text, int),
                       refund_reviewer_session(text)
    from public, anon, authenticated;
grant execute on function activate_reviewer_session(uuid, text[], interval),
                          consume_reviewer_session(text, text, int),
                          refund_reviewer_session(text)
    to service_role;


-- A rejection ends every session for that address, whichever path rejected it:
-- the prefilter, the classifier, a moderator, or a removal after publication.
-- A trigger rather than a call in each of those, because there are four of them
-- and the next one added would be the one that forgot.
--
-- Withdrawal does not revoke: it is the reviewer's own choice, not a finding
-- against them.
--
-- SECURITY DEFINER so a writer to `reviews` needs no grant on the session table.
create function revoke_reviewer_sessions_on_reject()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    delete from reviewer_sessions where email_hash = new.email_hash;
    return null;
end;
$$;

revoke all on function revoke_reviewer_sessions_on_reject() from public, anon, authenticated;

create trigger reviews_revoke_sessions_on_reject
    after update of status on reviews
    for each row
    when (new.status = 'rejected' and old.status is distinct from 'rejected')
    execute function revoke_reviewer_sessions_on_reject();
