-- MTF roster activity log
-- Run this once in Supabase: SQL Editor > New query > paste everything > Run.
-- Every add, edit and removal on the "roster" table is recorded automatically
-- by the database itself, so entries cannot be skipped or faked from the website.

create table if not exists public.roster_log (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  action        text not null check (action in ('added', 'edited', 'removed')),
  member_name   text,
  member_badge  text,
  changes       jsonb not null default '{}'::jsonb,   -- { field: { "from": old, "to": new } }
  actor_id      uuid,
  actor_discord text,
  actor_name    text
);

create index if not exists roster_log_created_at_idx on public.roster_log (created_at desc);

alter table public.roster_log enable row level security;

-- Only roster admins (and developers, if is_mtf_admin includes them) can read the log.
drop policy if exists "roster_log admins read" on public.roster_log;
create policy "roster_log admins read" on public.roster_log
  for select to authenticated
  using (public.is_mtf_admin() or coalesce(public.is_mtf_developer(), false));

-- No insert/update/delete policies: only the trigger below can write, and nobody can edit history.

create or replace function public.log_roster_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  meta  jsonb := coalesce(auth.jwt() -> 'user_metadata', '{}'::jsonb);
  diff  jsonb := '{}'::jsonb;
  k     text;
  o     jsonb;
  n     jsonb;
begin
  if tg_op = 'UPDATE' then
    o := to_jsonb(old); n := to_jsonb(new);
    for k in select jsonb_object_keys(n) loop
      if k not in ('id', 'sort', 'created_at', 'updated_at') and (o -> k) is distinct from (n -> k) then
        diff := diff || jsonb_build_object(k, jsonb_build_object('from', o -> k, 'to', n -> k));
      end if;
    end loop;
    if diff = '{}'::jsonb then return new; end if;  -- only the sort order changed
  end if;

  insert into public.roster_log (action, member_name, member_badge, changes, actor_id, actor_discord, actor_name)
  values (
    case tg_op when 'INSERT' then 'added' when 'UPDATE' then 'edited' else 'removed' end,
    case when tg_op = 'DELETE' then old.name else new.name end,
    case when tg_op = 'DELETE' then old.badge else new.badge end,
    diff,
    auth.uid(),
    coalesce(meta ->> 'provider_id', meta ->> 'sub'),
    coalesce(meta -> 'custom_claims' ->> 'global_name', meta ->> 'full_name', meta ->> 'name')
  );
  return coalesce(new, old);
end;
$$;

drop trigger if exists roster_activity_log on public.roster;
create trigger roster_activity_log
  after insert or update or delete on public.roster
  for each row execute function public.log_roster_change();

-- Let the website refresh the log live.
do $$ begin
  alter publication supabase_realtime add table public.roster_log;
exception when duplicate_object then null; when undefined_object then null; end $$;
