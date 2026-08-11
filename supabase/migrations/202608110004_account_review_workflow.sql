-- New confirmed accounts can sign in immediately, but participation remains
-- locked until an administrator approves the profile application.

alter table public.profiles alter column status set default 'pending';

create index if not exists profiles_pending_created_idx
  on public.profiles (created_at)
  where status = 'pending';

create or replace function public.review_account_application(
  p_user_id uuid,
  p_decision text,
  p_review_note text default null
)
returns public.profile_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  reviewer uuid := (select auth.uid());
  current_status public.profile_status;
  next_status public.profile_status;
begin
  if reviewer is null or not private.has_role(reviewer, array['admin']::public.app_role[]) then
    raise exception 'Admin role required' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected' using errcode = '22023';
  end if;
  if p_review_note is not null and char_length(p_review_note) > 2000 then
    raise exception 'Review note is too long' using errcode = '22001';
  end if;

  select status into current_status
  from public.profiles
  where user_id = p_user_id
  for update;

  if not found then
    raise exception 'Account application not found' using errcode = 'P0002';
  end if;
  if current_status not in ('pending', 'rejected') then
    raise exception 'Only pending or rejected applications can be reviewed' using errcode = '55000';
  end if;

  next_status := case when p_decision = 'approved' then 'active' else 'rejected' end;
  update public.profiles set status = next_status where user_id = p_user_id;

  insert into public.moderation_actions (
    actor_id,
    action,
    target_user_id,
    reason,
    metadata
  ) values (
    reviewer,
    case when p_decision = 'approved'
      then 'approve_user'::public.moderation_action_type
      else 'reject_user'::public.moderation_action_type
    end,
    p_user_id,
    coalesce(nullif(btrim(p_review_note), ''), case when p_decision = 'approved' then '账号申请通过' else '账号申请未通过' end),
    jsonb_build_object('previous_status', current_status, 'new_status', next_status)
  );

  return next_status;
end;
$$;

revoke all on function public.review_account_application(uuid, text, text) from public;
grant execute on function public.review_account_application(uuid, text, text) to authenticated;

-- Email-confirmed users may keep a private collection while waiting for
-- approval. Public participation (comments, likes and submissions) remains
-- protected by the active-profile checks.
drop policy if exists favorites_owner_insert on public.event_favorites;
create policy favorites_owner_insert on public.event_favorites for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.profiles p
    where p.user_id = (select auth.uid()) and p.status in ('pending', 'active')
  )
  and not exists (
    select 1 from public.user_bans b
    where b.user_id = (select auth.uid()) and b.revoked_at is null and b.starts_at <= now()
      and (b.ends_at is null or b.ends_at > now())
  )
  and exists (select 1 from public.events e where e.id = event_id and e.status = 'published')
);
