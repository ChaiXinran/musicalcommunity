-- In-app notifications for account applications, submissions, reports and
-- review workflows. Notifications are private to their recipient.

create table public.notifications (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('account', 'submission', 'report', 'review', 'system')),
  title text not null check (char_length(title) between 1 and 120),
  message text not null check (char_length(message) between 1 and 1000),
  target_url text not null default '/profile/?tab=notifications' check (char_length(target_url) between 1 and 500),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_user_created_idx on public.notifications (user_id, created_at desc);
create index notifications_user_unread_idx on public.notifications (user_id, created_at desc) where read_at is null;

create or replace function private.create_notification(
  p_user_id uuid,
  p_category text,
  p_title text,
  p_message text,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user_id is null then return; end if;
  insert into public.notifications (user_id, category, title, message, metadata)
  values (p_user_id, p_category, p_title, p_message, coalesce(p_metadata, '{}'::jsonb));
end;
$$;

create or replace function private.notify_management(
  p_maximum_level smallint,
  p_category text,
  p_title text,
  p_message text,
  p_metadata jsonb default '{}'::jsonb,
  p_exclude_user_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  recipient uuid;
begin
  for recipient in
    select distinct ur.user_id
    from public.user_roles ur
    join public.profiles p on p.user_id = ur.user_id and p.status = 'active'
    where (
      ur.role = 'admin'::public.app_role
      or (p_maximum_level >= 2 and ur.role = 'editor'::public.app_role)
      or (p_maximum_level >= 3 and ur.role = 'moderator'::public.app_role)
    )
    and (p_exclude_user_id is null or ur.user_id <> p_exclude_user_id)
  loop
    perform private.create_notification(recipient, p_category, p_title, p_message, p_metadata);
  end loop;
end;
$$;

create or replace function private.notify_account_application_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform private.create_notification(
      new.user_id, 'account', '账号申请已提交', '你的账号申请已经提交，请等待一级或二级管理员审核。',
      jsonb_build_object('user_id', new.user_id, 'status', new.status)
    );
    perform private.notify_management(
      2::smallint, 'review', '新的账号申请', '有一份新的账号申请等待审核。',
      jsonb_build_object('user_id', new.user_id, 'queue', 'applications'), new.user_id
    );
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status in ('approved', 'rejected') then
    perform private.create_notification(
      new.user_id, 'account',
      case when new.status = 'approved' then '账号审核已通过' else '账号审核未通过' end,
      case when new.status = 'approved'
        then '你的账号已解锁评论和投稿功能。'
        else '你的账号申请未通过，请在个人页面查看审核说明。'
      end,
      jsonb_build_object('user_id', new.user_id, 'status', new.status, 'review_note', new.review_note)
    );
  end if;
  return new;
end;
$$;

create or replace function private.notify_submission_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform private.create_notification(
      new.submitter_id, 'submission', '投稿已提交', format('你的投稿“%s”已进入审核队列。', new.title),
      jsonb_build_object('submission_id', new.id, 'status', new.status)
    );
    perform private.notify_management(
      3::smallint, 'review', '新的活动投稿', format('活动投稿“%s”等待审核。', new.title),
      jsonb_build_object('submission_id', new.id, 'queue', 'submissions'), new.submitter_id
    );
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status in ('approved', 'rejected', 'merged') then
    perform private.create_notification(
      new.submitter_id, 'submission',
      case new.status when 'approved' then '投稿审核已通过' when 'merged' then '投稿已合并' else '投稿审核未通过' end,
      case new.status
        when 'approved' then format('你的投稿“%s”已经发布到网站。', new.title)
        when 'merged' then format('你的投稿“%s”已合并到现有活动。', new.title)
        else format('你的投稿“%s”未通过审核，请查看审核说明。', new.title)
      end,
      jsonb_build_object('submission_id', new.id, 'status', new.status, 'review_note', new.review_note)
    );
  end if;
  return new;
end;
$$;

create or replace function private.notify_report_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'open' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform private.create_notification(
      new.reporter_id, 'report', '举报已提交', '你的举报已经提交，管理员会尽快处理。',
      jsonb_build_object('report_id', new.id, 'status', new.status)
    );
    perform private.notify_management(
      3::smallint, 'review', '新的举报', '有一条新的举报等待处理。',
      jsonb_build_object('report_id', new.id, 'queue', 'reports'), new.reporter_id
    );
  elsif tg_op = 'UPDATE' and old.status in ('open', 'reviewing') and new.status in ('resolved', 'dismissed') then
    perform private.create_notification(
      new.reporter_id, 'report',
      case when new.status = 'resolved' then '举报已处理' else '举报已关闭' end,
      case when new.status = 'resolved'
        then '你提交的举报已经处理完成。'
        else '你提交的举报经核查后已关闭。'
      end,
      jsonb_build_object('report_id', new.id, 'status', new.status)
    );
  end if;
  return new;
end;
$$;

create or replace function private.notify_review_question_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform private.create_notification(
      new.proposed_by, 'review', '审核问题已提交', '你提交的账号审核问题正在等待一级管理员审核。',
      jsonb_build_object('question_id', new.id, 'status', new.status)
    );
    perform private.notify_management(
      1::smallint, 'review', '新的审核问题', '二级管理员提交了一个新的账号审核问题。',
      jsonb_build_object('question_id', new.id, 'queue', 'questions'), new.proposed_by
    );
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status in ('approved', 'rejected') then
    perform private.create_notification(
      new.proposed_by, 'review',
      case when new.status = 'approved' then '审核问题已通过' else '审核问题未通过' end,
      case when new.status = 'approved'
        then '你提交的审核问题已进入账号申请备选题库。'
        else '你提交的审核问题未通过，请查看审核说明。'
      end,
      jsonb_build_object('question_id', new.id, 'status', new.status, 'review_note', new.review_note)
    );
  end if;
  return new;
end;
$$;

create trigger account_applications_notify
after insert or update of status on public.account_applications
for each row execute function private.notify_account_application_change();

create trigger event_submissions_notify
after insert or update of status on public.event_submissions
for each row execute function private.notify_submission_change();

create trigger reports_notify
after insert or update of status on public.reports
for each row execute function private.notify_report_change();

create trigger account_review_questions_notify
after insert or update of status on public.account_review_questions
for each row execute function private.notify_review_question_change();

alter table public.notifications enable row level security;

create policy notifications_owner_read on public.notifications for select to authenticated
using (user_id = (select auth.uid()));

create policy notifications_owner_update on public.notifications for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

revoke all on function private.create_notification(uuid, text, text, text, jsonb) from public;
revoke all on function private.notify_management(smallint, text, text, text, jsonb, uuid) from public;
