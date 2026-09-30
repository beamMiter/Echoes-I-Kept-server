-- Nothing ever deleted rows from the short-lived tables, so they grow forever:
-- refresh_tokens gets a new row on every token rotation, email_otps and
-- password_reset_tokens keep rows long after their 10/30 minute lifetime, and
-- ai_usage adds one row per user per day. A nightly pg_cron job trims them.
-- It runs inside Postgres on purpose: the API is on Vercel serverless, so
-- there is no long-lived process to host node-cron, and a pure DELETE needs
-- no HTTP endpoint (and no secret) to trigger it.
--
-- pg_cron must be enabled on the hosted project (Dashboard -> Database ->
-- Extensions) before `npm run db:push`; locally `supabase start` ships it.
create extension if not exists pg_cron with schema pg_catalog;

-- Retention keeps a grace window past expiry rather than deleting the moment a
-- row stops being usable, so a support question like "did this user's reset
-- link expire or get used?" can still be answered from the table for a day.
-- Every lookup in the API already filters on expires_at / revoked_at /
-- used_at, so removing rows that fail those filters cannot change behaviour.
-- The refresh flow has no token-reuse detection that would need revoked rows
-- kept around.
create or replace function public.cleanup_expired_rows()
returns void
language sql
set search_path = ''
as $$
  delete from public.email_otps
    where expires_at < now() - interval '1 day';

  delete from public.password_reset_tokens
    where expires_at < now() - interval '1 day'
       or used_at < now() - interval '1 day';

  delete from public.refresh_tokens
    where expires_at < now() - interval '7 days'
       or revoked_at < now() - interval '7 days';

  delete from public.ai_usage
    where usage_date < current_date - 90;

  delete from public.ai_global_usage
    where usage_date < current_date - 90;
$$;

-- Same posture as every other function in this schema (see 202608090004):
-- callable by service_role only, never over PostgREST with the anon key.
revoke execute on function public.cleanup_expired_rows() from public, anon, authenticated;
grant execute on function public.cleanup_expired_rows() to service_role;

-- pg_cron evaluates schedules in UTC: 20:00 UTC is 03:00 in Thailand, the
-- quietest hour. Scheduling by name makes this idempotent — re-running the
-- migration updates the job instead of creating a duplicate.
select cron.schedule(
  'cleanup-expired-rows',
  '0 20 * * *',
  $$select public.cleanup_expired_rows()$$
);
