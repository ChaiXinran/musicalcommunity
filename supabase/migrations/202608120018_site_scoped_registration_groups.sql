-- Shared identities with site-scoped registration groups and review questions.

alter table public.profiles
  add column registration_site text references public.sites(id),
  add column user_group text;

alter table public.profiles
  add constraint profiles_registration_site_check check (registration_site in ('duo', 'ayg', 'zyl')),
  add constraint profiles_user_group_check check (user_group in ('yunv', 'cloud', 'star'));

update public.profiles set registration_site = 'duo', user_group = 'yunv'
where registration_site is null or user_group is null;

alter table public.profiles alter column registration_site set default 'duo';
alter table public.profiles alter column registration_site set not null;
alter table public.profiles alter column user_group set default 'yunv';
alter table public.profiles alter column user_group set not null;

create table public.user_site_access (
  user_id uuid not null references auth.users(id) on delete cascade,
  site_id text not null references public.sites(id) on delete cascade,
  granted_at timestamptz not null default now(),
  primary key (user_id, site_id)
);

insert into public.user_site_access (user_id, site_id)
select p.user_id, s.site_id
from public.profiles p
cross join (values ('duo'), ('ayg'), ('zyl')) s(site_id)
on conflict do nothing;

alter table public.account_review_questions
  add column site_id text references public.sites(id);
update public.account_review_questions set site_id = 'duo' where site_id is null;
alter table public.account_review_questions alter column site_id set default 'duo';
alter table public.account_review_questions alter column site_id set not null;

alter table public.account_applications
  add column site_id text references public.sites(id);
update public.account_applications set site_id = 'duo' where site_id is null;
alter table public.account_applications alter column site_id set default 'duo';
alter table public.account_applications alter column site_id set not null;

drop index if exists public.account_review_questions_pool_idx;
create index account_review_questions_pool_idx
  on public.account_review_questions (site_id, created_at)
  where status = 'approved' and is_active;

insert into public.account_review_questions (id, site_id, prompt, status, is_active, reviewed_at)
values
  ('00000000-0000-4000-8000-000000000018', 'ayg', '你为什么喜欢阿云嘎？请结合自己的经历认真说明申请加入云朵社区的理由。', 'approved', true, now()),
  ('00000000-0000-4000-8000-000000000019', 'zyl', '你为什么喜欢郑云龙？请结合自己的经历认真说明申请加入小星星社区的理由。', 'approved', true, now())
on conflict (id) do update set site_id = excluded.site_id, prompt = excluded.prompt, status = 'approved', is_active = true;

drop function if exists public.random_account_review_question();

create or replace function public.random_account_review_question(p_site_id text)
returns table (id uuid, prompt text)
language sql
volatile
security definer
set search_path = ''
as $$
  select q.id, q.prompt
  from public.account_review_questions q
  where q.site_id = p_site_id
    and q.status = 'approved'
    and q.is_active
    and q.id not in (
      '00000000-0000-4000-8000-000000000017'::uuid,
      '00000000-0000-4000-8000-000000000018'::uuid,
      '00000000-0000-4000-8000-000000000019'::uuid
    )
  order by random()
  limit 1;
$$;

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
begin
  if source_site not in ('duo', 'ayg', 'zyl') then source_site := 'duo'; end if;
  assigned_group := case source_site when 'ayg' then 'cloud' when 'zyl' then 'star' else 'yunv' end;

  insert into public.profiles (user_id, display_name, registration_site, user_group)
  values (
    new.id,
    left(coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(coalesce(new.email, '新用户'), '@', 1)), 80),
    source_site,
    assigned_group
  );
  insert into public.user_roles (user_id, role) values (new.id, 'user');

  if source_site = 'duo' then
    insert into public.user_site_access (user_id, site_id) values (new.id, 'duo'), (new.id, 'ayg'), (new.id, 'zyl');
  else
    insert into public.user_site_access (user_id, site_id) values (new.id, source_site);
  end if;

  begin
    supplied_question_id := nullif(new.raw_user_meta_data ->> 'review_question_id', '')::uuid;
  exception when invalid_text_representation then
    supplied_question_id := null;
  end;

  if supplied_question_id is not null and char_length(supplied_answer) between 200 and 5000 then
    select * into selected_question from public.account_review_questions
    where id = supplied_question_id and site_id = source_site and status = 'approved' and is_active;
    if found then
      insert into public.account_applications (user_id, question_id, question_snapshot, answer, site_id)
      values (new.id, selected_question.id, selected_question.prompt, supplied_answer, source_site);
    end if;
  end if;
  return new;
end;
$$;

alter table public.user_site_access enable row level security;
create policy user_site_access_owner_read on public.user_site_access for select to authenticated
using (user_id = (select auth.uid()));
grant select on public.user_site_access to authenticated;

revoke all on function public.random_account_review_question(text) from public;
grant execute on function public.random_account_review_question(text) to anon, authenticated;

create or replace function public.submit_account_review_question(p_prompt text, p_site_id text default 'duo')
returns public.account_review_questions
language plpgsql security definer set search_path = ''
as $$
declare actor uuid := (select auth.uid()); actor_level smallint := private.management_level(actor); clean_prompt text := btrim(coalesce(p_prompt, '')); result public.account_review_questions;
begin
  if actor_level is null or actor_level > 2 then raise exception 'Level 1 or level 2 administrator required' using errcode = '42501'; end if;
  if p_site_id not in ('duo', 'ayg', 'zyl') then raise exception 'Invalid site' using errcode = '22023'; end if;
  if char_length(clean_prompt) not between 10 and 500 then raise exception 'Question must contain 10 to 500 characters' using errcode = '22001'; end if;
  insert into public.account_review_questions (prompt, site_id, status, proposed_by, reviewed_by, reviewed_at)
  values (clean_prompt, p_site_id, case when actor_level = 1 then 'approved' else 'pending' end, actor, case when actor_level = 1 then actor else null end, case when actor_level = 1 then now() else null end)
  returning * into result;
  insert into public.admin_audit_log (actor_id, action, target_id, metadata) values (actor, 'submit_question', result.id, jsonb_build_object('site_id', p_site_id, 'status', result.status, 'level', actor_level));
  return result;
end;
$$;

revoke select on public.account_review_questions from anon, authenticated;
revoke all on function public.submit_account_review_question(text, text) from public;
grant execute on function public.submit_account_review_question(text, text) to authenticated;

create or replace function public.submit_account_application(p_question_id uuid, p_answer text)
returns public.account_application_status
language plpgsql security definer set search_path = ''
as $$
declare applicant uuid := (select auth.uid()); selected_question public.account_review_questions; clean_answer text := btrim(coalesce(p_answer, '')); applicant_site text;
begin
  if applicant is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if char_length(clean_answer) not between 200 and 5000 then raise exception 'Application answer must contain 200 to 5000 characters' using errcode = '22001'; end if;
  select registration_site into applicant_site from public.profiles where user_id = applicant and status in ('pending', 'rejected');
  if not found then raise exception 'Only pending or rejected accounts can submit an application' using errcode = '55000'; end if;
  select * into selected_question from public.account_review_questions where id = p_question_id and site_id = applicant_site and status = 'approved' and is_active;
  if not found then raise exception 'Review question is not available for this registration site' using errcode = 'P0002'; end if;
  insert into public.account_applications (user_id, question_id, question_snapshot, answer, status, site_id)
  values (applicant, selected_question.id, selected_question.prompt, clean_answer, 'pending', applicant_site)
  on conflict (user_id) do update set question_id = excluded.question_id, question_snapshot = excluded.question_snapshot, answer = excluded.answer, site_id = excluded.site_id, status = 'pending', reviewer_id = null, review_note = null, submitted_at = now(), reviewed_at = null;
  update public.profiles set status = 'pending' where user_id = applicant;
  return 'pending';
end;
$$;
