-- Immediate report containment, permanent application-level bans and appeals.

alter table public.reports
  add column subject_user_id uuid references auth.users(id) on delete cascade,
  add column previous_profile_status public.profile_status,
  add column previous_comment_status public.comment_status,
  add column automatic_action boolean not null default false,
  add column review_note text check (review_note is null or char_length(review_note) <= 2000);

update public.reports r
set subject_user_id = coalesce(r.reported_user_id, c.user_id)
from public.comments c
where r.comment_id = c.id and r.subject_user_id is null;

update public.reports
set subject_user_id = reported_user_id
where subject_user_id is null and reported_user_id is not null;

alter table public.reports alter column subject_user_id set not null;
-- Keep a malformed historical self-report from blocking deployment; all new rows
-- are still checked immediately, while the new RPC also rejects self-reporting.
alter table public.reports add constraint reports_not_self_target check (reporter_id <> subject_user_id) not valid;

alter table public.user_bans add column report_id uuid references public.reports(id) on delete set null;
create unique index user_bans_report_idx on public.user_bans (report_id) where report_id is not null;

create type public.ban_appeal_status as enum ('pending', 'accepted', 'rejected');

create table public.ban_appeals (
  id uuid primary key default extensions.gen_random_uuid(),
  ban_id uuid not null unique references public.user_bans(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  message text not null check (char_length(btrim(message)) between 20 and 5000),
  status public.ban_appeal_status not null default 'pending',
  reviewer_id uuid references auth.users(id) on delete set null,
  review_note text check (review_note is null or char_length(review_note) <= 2000),
  fandom text check (fandom is null or fandom in ('ayanga', 'zhengyunlong')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint appeal_rejection_fandom check ((status = 'rejected' and fandom is not null) or (status <> 'rejected' and fandom is null))
);

create index reports_subject_status_idx on public.reports (subject_user_id, status, created_at desc);
create index ban_appeals_status_created_idx on public.ban_appeals (status, created_at) where status = 'pending';
create index ban_appeals_user_created_idx on public.ban_appeals (user_id, created_at desc);

create trigger ban_appeals_set_updated_at before update on public.ban_appeals
for each row execute function private.set_updated_at();

alter table public.ban_appeals enable row level security;
create policy ban_appeals_owner_read on public.ban_appeals for select to authenticated
using (user_id = (select auth.uid()));
create policy ban_appeals_manager_read on public.ban_appeals for select to authenticated
using (private.management_level((select auth.uid())) between 1 and 3);

create or replace function public.submit_report(
  p_comment_id uuid default null,
  p_reported_user_id uuid default null,
  p_reason text default '快捷举报',
  p_details text default ''
)
returns public.reports
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  subject uuid;
  actor_level smallint;
  subject_level smallint;
  previous_profile public.profile_status;
  previous_comment public.comment_status;
  new_report public.reports;
  new_ban_id uuid;
begin
  if actor is null or not private.is_active_user(actor) then
    raise exception 'Only approved active users can submit reports' using errcode = '42501';
  end if;
  if num_nonnulls(p_comment_id, p_reported_user_id) <> 1 then
    raise exception 'Exactly one report subject is required' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 1 and 100 then
    raise exception 'Report reason must contain 1 to 100 characters' using errcode = '22023';
  end if;
  if char_length(coalesce(p_details, '')) > 2000 then
    raise exception 'Report details are too long' using errcode = '22001';
  end if;

  if p_comment_id is not null then
    select c.user_id, c.status into subject, previous_comment
    from public.comments c where c.id = p_comment_id for update;
    if not found or previous_comment <> 'published' then
      raise exception 'Comment is unavailable for reporting' using errcode = 'P0002';
    end if;
  else
    subject := p_reported_user_id;
  end if;

  if subject is null or subject = actor then
    raise exception 'You cannot report this account' using errcode = '22023';
  end if;
  select status into previous_profile from public.profiles where user_id = subject for update;
  if not found or previous_profile <> 'active' then
    raise exception 'The reported account is not currently active' using errcode = '55000';
  end if;
  subject_level := private.management_level(subject);
  if subject_level is not null then
    raise exception 'Administrator accounts cannot be reported through the public shortcut' using errcode = '42501';
  end if;
  if exists (select 1 from public.reports where subject_user_id = subject and status in ('open', 'reviewing')) then
    raise exception 'This account already has a report under review' using errcode = '55000';
  end if;

  actor_level := private.management_level(actor);
  insert into public.reports (
    reporter_id, comment_id, reported_user_id, subject_user_id, reason, details, status,
    previous_profile_status, previous_comment_status, automatic_action, resolved_by, resolved_at
  ) values (
    actor, p_comment_id, case when p_comment_id is null then subject else null end, subject,
    btrim(p_reason), coalesce(p_details, ''), case when actor_level is null then 'open' else 'resolved' end,
    previous_profile, previous_comment, actor_level is not null,
    case when actor_level is null then null else actor end,
    case when actor_level is null then null else now() end
  ) returning * into new_report;

  if actor_level is null then
    if p_comment_id is not null then update public.comments set status = 'hidden' where id = p_comment_id; end if;
    update public.profiles set status = 'pending' where user_id = subject;
    perform private.create_notification(
      subject, 'report', '账号因举报暂时冻结',
      '你的账号正在等待管理员核查，所有互动权限已暂时关闭。举报若被驳回，权限会自动恢复。',
      jsonb_build_object('report_id', new_report.id, 'moderation_state', 'frozen')
    );
  else
    if p_comment_id is not null then update public.comments set status = 'deleted', content = '[已永久删除]' where id = p_comment_id; end if;
    update public.profiles set status = 'suspended' where user_id = subject;
    insert into public.user_bans (user_id, issued_by, reason, report_id)
    values (subject, actor, '管理员快捷举报：账号永久封禁', new_report.id)
    returning id into new_ban_id;
    perform private.create_notification(
      subject, 'report', '账号已被永久封禁',
      '管理员举报已直接生效。你的账号所有权限已永久关闭；如认为处理有误，可以在个人页面提交一次申诉。',
      jsonb_build_object('report_id', new_report.id, 'ban_id', new_ban_id, 'moderation_state', 'banned')
    );
  end if;

  insert into public.moderation_actions (actor_id, action, target_user_id, target_comment_id, report_id, reason, metadata)
  values (
    actor,
    case when actor_level is null and p_comment_id is not null then 'hide_comment'::public.moderation_action_type else 'suspend_user'::public.moderation_action_type end,
    subject, p_comment_id, new_report.id, btrim(p_reason),
    jsonb_build_object('automatic_action', actor_level is not null, 'previous_profile_status', previous_profile, 'previous_comment_status', previous_comment)
  );
  return new_report;
end;
$$;

create or replace function public.review_report(
  p_report_id uuid,
  p_decision text,
  p_review_note text default null
)
returns public.report_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  report_row public.reports;
  new_ban_id uuid;
begin
  if private.management_level(actor) is null or private.management_level(actor) > 3 then
    raise exception 'Administrator role required' using errcode = '42501';
  end if;
  if p_decision not in ('upheld', 'dismissed') then
    raise exception 'Decision must be upheld or dismissed' using errcode = '22023';
  end if;
  if p_review_note is not null and char_length(p_review_note) > 2000 then
    raise exception 'Review note is too long' using errcode = '22001';
  end if;
  select * into report_row from public.reports where id = p_report_id for update;
  if not found or report_row.status not in ('open', 'reviewing') then
    raise exception 'Open report not found' using errcode = 'P0002';
  end if;

  if p_decision = 'dismissed' then
    if report_row.comment_id is not null then
      update public.comments set status = coalesce(report_row.previous_comment_status, 'published')
      where id = report_row.comment_id and status = 'hidden';
    end if;
    if not exists (
      select 1 from public.reports r where r.subject_user_id = report_row.subject_user_id
      and r.id <> report_row.id and r.status in ('open', 'reviewing')
    ) and not exists (
      select 1 from public.user_bans b where b.user_id = report_row.subject_user_id and b.revoked_at is null
      and b.starts_at <= now() and (b.ends_at is null or b.ends_at > now())
    ) then
      update public.profiles set status = coalesce(report_row.previous_profile_status, 'active')
      where user_id = report_row.subject_user_id;
    end if;
    update public.reports set status = 'dismissed', resolved_by = actor, resolved_at = now(), review_note = p_review_note
    where id = p_report_id;
    perform private.create_notification(
      report_row.subject_user_id, 'report', '举报已驳回，账号恢复正常',
      '管理员核查后驳回了举报，隐藏的评论和账号权限已经恢复。',
      jsonb_build_object('report_id', report_row.id, 'status', 'dismissed', 'review_note', p_review_note)
    );
    return 'dismissed';
  end if;

  if report_row.comment_id is not null then
    update public.comments set status = 'deleted', content = '[已永久删除]' where id = report_row.comment_id;
  end if;
  update public.profiles set status = 'suspended' where user_id = report_row.subject_user_id;
  insert into public.user_bans (user_id, issued_by, reason, report_id)
  values (report_row.subject_user_id, actor, coalesce(nullif(btrim(p_review_note), ''), '举报成立：账号永久封禁'), report_row.id)
  returning id into new_ban_id;
  update public.reports set status = 'resolved', resolved_by = actor, resolved_at = now(), review_note = p_review_note
  where id = p_report_id;
  insert into public.moderation_actions (actor_id, action, target_user_id, target_comment_id, report_id, reason, metadata)
  values (actor, 'resolve_report', report_row.subject_user_id, report_row.comment_id, report_row.id,
    coalesce(nullif(btrim(p_review_note), ''), '举报成立'), jsonb_build_object('decision', 'upheld', 'ban_id', new_ban_id));
  perform private.create_notification(
    report_row.subject_user_id, 'report', '举报成立，账号已永久封禁',
    '被举报评论已永久删除，账号所有权限已永久关闭。如认为处理有误，可以在个人页面提交一次申诉。',
    jsonb_build_object('report_id', report_row.id, 'ban_id', new_ban_id, 'status', 'resolved', 'moderation_state', 'banned')
  );
  return 'resolved';
end;
$$;

create function public.submit_ban_appeal(p_message text)
returns public.ban_appeals
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  ban_row public.user_bans;
  appeal_row public.ban_appeals;
begin
  if actor is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if char_length(btrim(coalesce(p_message, ''))) not between 20 and 5000 then
    raise exception 'Appeal must contain 20 to 5000 characters' using errcode = '22023';
  end if;
  select * into ban_row from public.user_bans
  where user_id = actor and revoked_at is null and ends_at is null
  order by created_at desc limit 1 for update;
  if not found then raise exception 'No permanent ban is available for appeal' using errcode = 'P0002'; end if;
  if exists (select 1 from public.ban_appeals where ban_id = ban_row.id) then
    raise exception 'This ban has already been appealed' using errcode = '55000';
  end if;
  insert into public.ban_appeals (ban_id, user_id, message)
  values (ban_row.id, actor, btrim(p_message)) returning * into appeal_row;
  perform private.notify_management(
    3::smallint, 'review', '新的封禁申诉', '有一名被封禁用户提交了申诉，请重新审核。',
    jsonb_build_object('appeal_id', appeal_row.id, 'queue', 'appeals'), actor
  );
  perform private.create_notification(actor, 'system', '申诉已提交', '你的封禁申诉已经提交，管理员会重新审核。',
    jsonb_build_object('appeal_id', appeal_row.id, 'status', 'pending'));
  return appeal_row;
end;
$$;

create function public.review_ban_appeal(
  p_appeal_id uuid,
  p_decision text,
  p_review_note text default null,
  p_fandom text default null
)
returns public.ban_appeals
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  appeal_row public.ban_appeals;
  result_image text;
begin
  if private.management_level(actor) is null or private.management_level(actor) > 3 then
    raise exception 'Administrator role required' using errcode = '42501';
  end if;
  if p_decision not in ('accepted', 'rejected') then
    raise exception 'Decision must be accepted or rejected' using errcode = '22023';
  end if;
  if p_decision = 'rejected' and (p_fandom is null or p_fandom not in ('ayanga', 'zhengyunlong')) then
    raise exception 'Rejected appeals must identify the fandom' using errcode = '22023';
  end if;
  if p_decision = 'accepted' and p_fandom is not null then
    raise exception 'Accepted appeals cannot include a fandom label' using errcode = '22023';
  end if;
  select * into appeal_row from public.ban_appeals where id = p_appeal_id and status = 'pending' for update;
  if not found then raise exception 'Pending appeal not found' using errcode = 'P0002'; end if;

  if p_decision = 'accepted' then
    update public.user_bans set revoked_at = now(), revoked_by = actor where id = appeal_row.ban_id and revoked_at is null;
    update public.profiles set status = 'active' where user_id = appeal_row.user_id;
  else
    update public.profiles set status = 'suspended' where user_id = appeal_row.user_id;
    result_image := case when p_fandom = 'ayanga' then '/assets/moderation/appeal-ayanga.jpg' else '/assets/moderation/appeal-zhengyunlong.png' end;
  end if;

  update public.ban_appeals set
    status = p_decision::public.ban_appeal_status,
    reviewer_id = actor,
    review_note = p_review_note,
    fandom = case when p_decision = 'rejected' then p_fandom else null end,
    reviewed_at = now()
  where id = p_appeal_id returning * into appeal_row;
  insert into public.admin_audit_log (actor_id, action, target_user_id, target_id, metadata)
  values (actor, 'review_ban_appeal', appeal_row.user_id, appeal_row.id,
    jsonb_build_object('decision', p_decision, 'fandom', p_fandom, 'review_note', p_review_note));
  perform private.create_notification(
    appeal_row.user_id, 'system',
    case when p_decision = 'accepted' then '申诉成功，账号已恢复' else '申诉被拒绝' end,
    case when p_decision = 'accepted'
      then '管理员接受了你的申诉，账号状态和社区功能已经恢复。'
      else '管理员重新审核后拒绝了申诉，账号将继续保持永久封禁。'
    end,
    jsonb_strip_nulls(jsonb_build_object('appeal_id', appeal_row.id, 'status', p_decision, 'fandom', p_fandom, 'result_image', result_image, 'review_note', p_review_note))
  );
  return appeal_row;
end;
$$;

drop policy if exists reports_owner_insert on public.reports;
revoke insert on public.reports from authenticated;
revoke insert (reporter_id, comment_id, reported_user_id, reason, details, status) on public.reports from authenticated;
grant select on public.ban_appeals to authenticated;

revoke all on function public.submit_report(uuid, uuid, text, text) from public;
grant execute on function public.submit_report(uuid, uuid, text, text) to authenticated;
revoke all on function public.review_report(uuid, text, text) from public;
grant execute on function public.review_report(uuid, text, text) to authenticated;
revoke all on function public.submit_ban_appeal(text) from public;
grant execute on function public.submit_ban_appeal(text) to authenticated;
revoke all on function public.review_ban_appeal(uuid, text, text, text) from public;
grant execute on function public.review_ban_appeal(uuid, text, text, text) to authenticated;
