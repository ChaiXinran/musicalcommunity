create table public.site_announcement_reads (
  announcement_id uuid not null references public.site_announcements(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (announcement_id, user_id)
);

create index site_announcement_reads_user_idx
  on public.site_announcement_reads (user_id, read_at desc);

alter table public.site_announcement_reads enable row level security;
create policy site_announcement_reads_owner_read on public.site_announcement_reads
  for select to authenticated using (user_id = (select auth.uid()));
create policy site_announcement_reads_owner_insert on public.site_announcement_reads
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy site_announcement_reads_owner_update on public.site_announcement_reads
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
grant select, insert on public.site_announcement_reads to authenticated;
grant update (read_at) on public.site_announcement_reads to authenticated;

-- Recover application rows whose answers still exist in Supabase Auth metadata.
insert into public.account_applications (
  user_id, question_id, question_snapshot, answer, status, site_id, submitted_at, reviewed_at
)
select
  u.id,
  q.id,
  coalesce(
    q.prompt,
    case when char_length(btrim(coalesce(u.raw_user_meta_data ->> 'review_question', ''))) between 10 and 500
      then btrim(u.raw_user_meta_data ->> 'review_question') end,
    case p.registration_site
      when 'ayg' then '你为什么喜欢阿云嘎？请认真说明申请加入云朵社区的理由。'
      when 'zyl' then '你为什么喜欢郑云龙？请认真说明申请加入小星星社区的理由。'
      else '你为什么喜欢龙龙和嘎嘎呢？请认真说明申请加入社区的理由。'
    end
  ),
  btrim(u.raw_user_meta_data ->> 'review_answer'),
  case p.status when 'active' then 'approved'::public.account_application_status when 'rejected' then 'rejected'::public.account_application_status else 'pending'::public.account_application_status end,
  p.registration_site,
  u.created_at,
  case when p.status in ('active', 'rejected') then coalesce(u.updated_at, now()) else null end
from auth.users u
join public.profiles p on p.user_id = u.id
left join public.account_applications a on a.user_id = u.id
left join public.account_review_questions q on q.id = case
  when (u.raw_user_meta_data ->> 'review_question_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then (u.raw_user_meta_data ->> 'review_question_id')::uuid
  else null
end and q.site_id = p.registration_site
where a.user_id is null
  and char_length(btrim(coalesce(u.raw_user_meta_data ->> 'review_answer', ''))) between 200 and 5000;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_question public.account_review_questions;
  supplied_question_id uuid;
  supplied_answer text := btrim(coalesce(new.raw_user_meta_data ->> 'review_answer', ''));
  source_site text := coalesce(nullif(new.raw_user_meta_data ->> 'registration_site', ''), 'duo');
  assigned_group text;
  fallback_prompt text;
begin
  if source_site not in ('duo', 'ayg', 'zyl') then source_site := 'duo'; end if;
  assigned_group := case source_site when 'ayg' then 'cloud' when 'zyl' then 'star' else 'yunv' end;
  fallback_prompt := case source_site
    when 'ayg' then '你为什么喜欢阿云嘎？请认真说明申请加入云朵社区的理由。'
    when 'zyl' then '你为什么喜欢郑云龙？请认真说明申请加入小星星社区的理由。'
    else '你为什么喜欢龙龙和嘎嘎呢？请认真说明申请加入社区的理由。'
  end;

  insert into public.profiles (user_id, display_name, registration_site, user_group)
  values (new.id, left(coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(coalesce(new.email, '新用户'), '@', 1)), 80), source_site, assigned_group);
  insert into public.user_roles (user_id, role) values (new.id, 'user');
  if source_site = 'duo' then
    insert into public.user_site_access (user_id, site_id) values (new.id, 'duo'), (new.id, 'ayg'), (new.id, 'zyl');
  else
    insert into public.user_site_access (user_id, site_id) values (new.id, source_site);
  end if;

  begin supplied_question_id := nullif(new.raw_user_meta_data ->> 'review_question_id', '')::uuid;
  exception when invalid_text_representation then supplied_question_id := null;
  end;

  if char_length(supplied_answer) between 200 and 5000 then
    selected_question := null;
    if supplied_question_id is not null then
      select * into selected_question from public.account_review_questions
      where id = supplied_question_id and site_id = source_site and status = 'approved' and is_active;
    end if;
    if selected_question.id is null then
      select * into selected_question from public.account_review_questions
      where site_id = source_site and status = 'approved' and is_active
      order by case id
        when '00000000-0000-4000-8000-000000000017'::uuid then 0
        when '00000000-0000-4000-8000-000000000018'::uuid then 0
        when '00000000-0000-4000-8000-000000000019'::uuid then 0
        else 1 end, created_at
      limit 1;
    end if;
    insert into public.account_applications (user_id, question_id, question_snapshot, answer, site_id)
    values (
      new.id,
      selected_question.id,
      coalesce(
        selected_question.prompt,
        case when char_length(btrim(coalesce(new.raw_user_meta_data ->> 'review_question', ''))) between 10 and 500
          then btrim(new.raw_user_meta_data ->> 'review_question') end,
        fallback_prompt
      ),
      supplied_answer,
      source_site
    );
  end if;
  return new;
end;
$$;

create or replace function private.notify_account_application_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare result_message text;
begin
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform private.create_notification(new.user_id, 'account', '账号申请已提交', '你的账号申请已经提交，请等待一级或二级管理员审核。', jsonb_build_object('user_id', new.user_id, 'status', new.status));
    perform private.notify_management(2::smallint, 'review', '新的账号申请', '有一份新的账号申请等待审核。', jsonb_build_object('user_id', new.user_id, 'queue', 'applications'), new.user_id);
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status in ('approved', 'rejected') then
    update public.notifications set read_at = coalesce(read_at, now())
    where read_at is null and (
      (category = 'account' and user_id = new.user_id and metadata ->> 'status' = 'pending')
      or (category = 'review' and metadata ->> 'queue' = 'applications' and metadata ->> 'user_id' = new.user_id::text)
    );
    result_message := case when new.status = 'approved' then '你的账号已解锁评论和投稿功能。' else '你的账号申请未通过。' end;
    if nullif(btrim(new.review_note), '') is not null then result_message := result_message || E'\n\n管理员回复：' || btrim(new.review_note); end if;
    perform private.create_notification(new.user_id, 'account', case when new.status = 'approved' then '账号审核已通过' else '账号审核未通过' end, result_message, jsonb_build_object('user_id', new.user_id, 'status', new.status, 'review_note', new.review_note));
  end if;
  return new;
end;
$$;
