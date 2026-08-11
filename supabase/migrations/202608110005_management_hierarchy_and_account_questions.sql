-- Three management levels and reason-based account applications.
-- Existing roles map to the user-facing levels as follows:
--   admin = level 1, editor = level 2, moderator = level 3.

create type public.account_application_status as enum ('pending', 'approved', 'rejected');
create type public.review_question_status as enum ('pending', 'approved', 'rejected');

create table public.account_review_questions (
  id uuid primary key default extensions.gen_random_uuid(),
  prompt text not null check (char_length(btrim(prompt)) between 10 and 500),
  status public.review_question_status not null default 'pending',
  is_active boolean not null default true,
  proposed_by uuid references auth.users(id) on delete set null,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_note text check (review_note is null or char_length(review_note) <= 2000),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.account_applications (
  user_id uuid primary key references auth.users(id) on delete cascade,
  question_id uuid references public.account_review_questions(id) on delete set null,
  question_snapshot text not null check (char_length(btrim(question_snapshot)) between 10 and 500),
  answer text not null check (char_length(btrim(answer)) between 200 and 5000),
  status public.account_application_status not null default 'pending',
  reviewer_id uuid references auth.users(id) on delete set null,
  review_note text check (review_note is null or char_length(review_note) <= 2000),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.admin_audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (char_length(action) between 1 and 100),
  target_user_id uuid references auth.users(id) on delete set null,
  target_id uuid,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now()
);

create trigger account_review_questions_set_updated_at
before update on public.account_review_questions
for each row execute function private.set_updated_at();

create trigger account_applications_set_updated_at
before update on public.account_applications
for each row execute function private.set_updated_at();

create index account_review_questions_pool_idx
  on public.account_review_questions (created_at)
  where status = 'approved' and is_active;
create index account_review_questions_pending_idx
  on public.account_review_questions (created_at)
  where status = 'pending';
create index account_applications_pending_idx
  on public.account_applications (submitted_at)
  where status = 'pending';
create index admin_audit_log_created_idx on public.admin_audit_log (created_at desc);

create or replace function private.management_level(p_user_id uuid)
returns smallint
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when private.has_role(p_user_id, array['admin']::public.app_role[]) then 1::smallint
    when private.has_role(p_user_id, array['editor']::public.app_role[]) then 2::smallint
    when private.has_role(p_user_id, array['moderator']::public.app_role[]) then 3::smallint
    else null::smallint
  end;
$$;

create or replace function public.random_account_review_question()
returns table (id uuid, prompt text)
language sql
volatile
security definer
set search_path = ''
as $$
  select q.id, q.prompt
  from public.account_review_questions q
  where q.status = 'approved' and q.is_active
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
begin
  insert into public.profiles (user_id, display_name)
  values (
    new.id,
    left(coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(coalesce(new.email, '新用户'), '@', 1)), 80)
  );
  insert into public.user_roles (user_id, role) values (new.id, 'user');

  begin
    supplied_question_id := nullif(new.raw_user_meta_data ->> 'review_question_id', '')::uuid;
  exception when invalid_text_representation then
    supplied_question_id := null;
  end;

  if supplied_question_id is not null and char_length(supplied_answer) between 200 and 5000 then
    select * into selected_question
    from public.account_review_questions
    where id = supplied_question_id and status = 'approved' and is_active;

    if found then
      insert into public.account_applications (user_id, question_id, question_snapshot, answer)
      values (new.id, selected_question.id, selected_question.prompt, supplied_answer);
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.submit_account_application(
  p_question_id uuid,
  p_answer text
)
returns public.account_application_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  applicant uuid := (select auth.uid());
  selected_question public.account_review_questions;
  clean_answer text := btrim(coalesce(p_answer, ''));
begin
  if applicant is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if char_length(clean_answer) not between 200 and 5000 then
    raise exception 'Application answer must contain 200 to 5000 characters' using errcode = '22001';
  end if;
  if not exists (select 1 from public.profiles where user_id = applicant and status in ('pending', 'rejected')) then
    raise exception 'Only pending or rejected accounts can submit an application' using errcode = '55000';
  end if;
  select * into selected_question from public.account_review_questions
  where id = p_question_id and status = 'approved' and is_active;
  if not found then raise exception 'Review question is no longer available' using errcode = 'P0002'; end if;

  insert into public.account_applications (user_id, question_id, question_snapshot, answer, status)
  values (applicant, selected_question.id, selected_question.prompt, clean_answer, 'pending')
  on conflict (user_id) do update set
    question_id = excluded.question_id,
    question_snapshot = excluded.question_snapshot,
    answer = excluded.answer,
    status = 'pending',
    reviewer_id = null,
    review_note = null,
    submitted_at = now(),
    reviewed_at = null;
  update public.profiles set status = 'pending' where user_id = applicant;
  return 'pending';
end;
$$;

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
  reviewer_level smallint := private.management_level(reviewer);
  next_profile_status public.profile_status;
  next_application_status public.account_application_status;
begin
  if reviewer is null or reviewer_level is null or reviewer_level > 2 then
    raise exception 'Level 1 or level 2 administrator required' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected' using errcode = '22023';
  end if;
  if p_review_note is not null and char_length(p_review_note) > 2000 then
    raise exception 'Review note is too long' using errcode = '22001';
  end if;
  if not exists (
    select 1 from public.account_applications
    where user_id = p_user_id and status = 'pending'
    for update
  ) then
    raise exception 'Pending account application not found' using errcode = 'P0002';
  end if;

  next_profile_status := case when p_decision = 'approved' then 'active' else 'rejected' end;
  next_application_status := case when p_decision = 'approved' then 'approved' else 'rejected' end;
  update public.account_applications set
    status = next_application_status,
    reviewer_id = reviewer,
    review_note = nullif(btrim(p_review_note), ''),
    reviewed_at = now()
  where user_id = p_user_id;
  update public.profiles set status = next_profile_status where user_id = p_user_id;

  insert into public.admin_audit_log (actor_id, action, target_user_id, metadata)
  values (reviewer, 'review_account', p_user_id, jsonb_build_object('decision', p_decision, 'level', reviewer_level));
  return next_profile_status;
end;
$$;

create or replace function public.submit_account_review_question(p_prompt text)
returns public.account_review_questions
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  actor_level smallint := private.management_level(actor);
  clean_prompt text := btrim(coalesce(p_prompt, ''));
  result public.account_review_questions;
begin
  if actor_level is null or actor_level > 2 then
    raise exception 'Level 1 or level 2 administrator required' using errcode = '42501';
  end if;
  if char_length(clean_prompt) not between 10 and 500 then
    raise exception 'Question must contain 10 to 500 characters' using errcode = '22001';
  end if;
  insert into public.account_review_questions (
    prompt, status, proposed_by, reviewed_by, reviewed_at
  ) values (
    clean_prompt,
    case when actor_level = 1 then 'approved'::public.review_question_status else 'pending'::public.review_question_status end,
    actor,
    case when actor_level = 1 then actor else null end,
    case when actor_level = 1 then now() else null end
  ) returning * into result;
  insert into public.admin_audit_log (actor_id, action, target_id, metadata)
  values (actor, case when actor_level = 1 then 'create_question' else 'propose_question' end, result.id, '{}'::jsonb);
  return result;
end;
$$;

create or replace function public.review_account_review_question(
  p_question_id uuid,
  p_decision text,
  p_review_note text default null
)
returns public.review_question_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  next_status public.review_question_status;
begin
  if private.management_level(actor) is distinct from 1 then
    raise exception 'Level 1 administrator required' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected' using errcode = '22023';
  end if;
  next_status := p_decision::public.review_question_status;
  update public.account_review_questions set
    status = next_status,
    reviewed_by = actor,
    review_note = nullif(btrim(p_review_note), ''),
    reviewed_at = now()
  where id = p_question_id and status = 'pending';
  if not found then raise exception 'Pending question not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit_log (actor_id, action, target_id, metadata)
  values (actor, 'review_question', p_question_id, jsonb_build_object('decision', p_decision));
  return next_status;
end;
$$;

create or replace function public.assign_management_level(
  p_user_id uuid,
  p_level smallint
)
returns smallint
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  existing_level smallint := private.management_level(p_user_id);
begin
  if private.management_level(actor) is distinct from 1 then
    raise exception 'Level 1 administrator required' using errcode = '42501';
  end if;
  if p_user_id = actor then raise exception 'A level 1 administrator cannot change their own level' using errcode = '55000'; end if;
  if existing_level = 1 then raise exception 'Another level 1 administrator cannot be changed here' using errcode = '42501'; end if;
  if p_level is not null and p_level not in (2, 3) then
    raise exception 'Management level must be 2, 3, or null' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where user_id = p_user_id and status = 'active') then
    raise exception 'Only active accounts can become administrators' using errcode = '55000';
  end if;
  delete from public.user_roles where user_id = p_user_id and role in ('editor', 'moderator');
  if p_level = 2 then
    insert into public.user_roles (user_id, role, granted_by) values (p_user_id, 'editor', actor)
    on conflict (user_id, role) do update set granted_by = excluded.granted_by, created_at = now();
  elsif p_level = 3 then
    insert into public.user_roles (user_id, role, granted_by) values (p_user_id, 'moderator', actor)
    on conflict (user_id, role) do update set granted_by = excluded.granted_by, created_at = now();
  end if;
  insert into public.admin_audit_log (actor_id, action, target_user_id, metadata)
  values (actor, 'assign_management_level', p_user_id, jsonb_build_object('previous_level', existing_level, 'new_level', p_level));
  return p_level;
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
  next_status public.report_status;
begin
  if private.management_level(actor) is null or private.management_level(actor) > 3 then
    raise exception 'Administrator role required' using errcode = '42501';
  end if;
  if p_decision not in ('resolved', 'dismissed') then
    raise exception 'Decision must be resolved or dismissed' using errcode = '22023';
  end if;
  next_status := p_decision::public.report_status;
  update public.reports set status = next_status, resolved_by = actor, resolved_at = now()
  where id = p_report_id and status in ('open', 'reviewing');
  if not found then raise exception 'Open report not found' using errcode = 'P0002'; end if;
  insert into public.moderation_actions (actor_id, action, report_id, reason, metadata)
  values (actor, 'resolve_report', p_report_id, coalesce(nullif(btrim(p_review_note), ''), '举报已处理'), jsonb_build_object('decision', p_decision));
  return next_status;
end;
$$;

-- Level 2 must be able to review accounts and submissions; all three levels
-- can read and handle reports and moderation records.
create or replace function public.review_event_submission(
  p_submission_id uuid,
  p_decision text,
  p_review_note text default null,
  p_target_event_id uuid default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  reviewer uuid := (select auth.uid());
  submission public.event_submissions;
  new_event_id uuid;
  new_venue_id uuid;
begin
  if reviewer is null or private.management_level(reviewer) is null or private.management_level(reviewer) > 3 then
    raise exception 'Administrator role required' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected', 'merged') then raise exception 'Decision must be approved, rejected, or merged' using errcode = '22023'; end if;
  select * into submission from public.event_submissions where id = p_submission_id for update;
  if not found then raise exception 'Submission not found' using errcode = 'P0002'; end if;
  if submission.status <> 'pending' then raise exception 'Only pending submissions can be reviewed' using errcode = '55000'; end if;
  if p_decision = 'merged' then
    if p_target_event_id is null or not exists (select 1 from public.events where id = p_target_event_id and status <> 'archived') then
      raise exception 'A valid target event is required for merge' using errcode = '23503';
    end if;
    update public.event_submissions set status = 'merged', reviewer_id = reviewer, review_note = p_review_note,
      merged_into_event_id = p_target_event_id, reviewed_at = now() where id = p_submission_id;
    return p_target_event_id;
  end if;
  if p_decision = 'rejected' then
    update public.event_submissions set status = 'rejected', reviewer_id = reviewer, review_note = p_review_note,
      reviewed_at = now() where id = p_submission_id;
    return null;
  end if;
  if submission.venue is not null and btrim(submission.venue) <> '' then
    insert into public.venues (name, city, country, latitude, longitude)
    values (submission.venue, submission.city, submission.country, submission.latitude, submission.longitude)
    returning id into new_venue_id;
  end if;
  insert into public.events (title, category, start_time, end_time, venue_id, city, country,
    latitude, longitude, description, source_url, status, created_by)
  values (submission.title, submission.category, submission.start_time, submission.end_time, new_venue_id,
    submission.city, submission.country, submission.latitude, submission.longitude, submission.description,
    submission.source_url, 'published', submission.submitter_id) returning id into new_event_id;
  insert into public.event_sites (event_id, site_id)
  select new_event_id, site_id from unnest(submission.proposed_sites) as proposed(site_id);
  update public.event_submissions set status = 'approved', reviewer_id = reviewer, review_note = p_review_note,
    approved_event_id = new_event_id, reviewed_at = now() where id = p_submission_id;
  return new_event_id;
end;
$$;

alter table public.account_review_questions enable row level security;
alter table public.account_applications enable row level security;
alter table public.admin_audit_log enable row level security;

create policy review_questions_approved_read on public.account_review_questions for select to anon, authenticated
using (status = 'approved' and is_active);
create policy review_questions_manager_read on public.account_review_questions for select to authenticated
using (private.management_level((select auth.uid())) between 1 and 2);
create policy account_applications_owner_read on public.account_applications for select to authenticated
using (user_id = (select auth.uid()));
create policy account_applications_reviewer_read on public.account_applications for select to authenticated
using (private.management_level((select auth.uid())) between 1 and 2);
create policy admin_audit_level1_read on public.admin_audit_log for select to authenticated
using (private.management_level((select auth.uid())) = 1);

drop policy if exists reports_owner_or_moderator_read on public.reports;
create policy reports_owner_or_moderator_read on public.reports for select to authenticated
using (reporter_id = (select auth.uid()) or private.management_level((select auth.uid())) between 1 and 3);
drop policy if exists reports_moderator_update on public.reports;
create policy reports_moderator_update on public.reports for update to authenticated
using (private.management_level((select auth.uid())) between 1 and 3)
with check (private.management_level((select auth.uid())) between 1 and 3);
drop policy if exists moderation_actions_moderator_read on public.moderation_actions;
create policy moderation_actions_moderator_read on public.moderation_actions for select to authenticated
using (private.management_level((select auth.uid())) between 1 and 3);
drop policy if exists moderation_actions_moderator_insert on public.moderation_actions;
create policy moderation_actions_moderator_insert on public.moderation_actions for insert to authenticated
with check (actor_id = (select auth.uid()) and private.management_level((select auth.uid())) between 1 and 3);

grant select on public.account_review_questions to anon, authenticated;
grant select on public.account_applications, public.admin_audit_log to authenticated;
revoke all on function private.management_level(uuid) from public;
grant execute on function private.management_level(uuid) to authenticated;
revoke all on function public.random_account_review_question() from public;
grant execute on function public.random_account_review_question() to anon, authenticated;
revoke all on function public.submit_account_application(uuid, text) from public;
grant execute on function public.submit_account_application(uuid, text) to authenticated;
revoke all on function public.review_account_application(uuid, text, text) from public;
grant execute on function public.review_account_application(uuid, text, text) to authenticated;
revoke all on function public.submit_account_review_question(text) from public;
grant execute on function public.submit_account_review_question(text) to authenticated;
revoke all on function public.review_account_review_question(uuid, text, text) from public;
grant execute on function public.review_account_review_question(uuid, text, text) to authenticated;
revoke all on function public.assign_management_level(uuid, smallint) from public;
grant execute on function public.assign_management_level(uuid, smallint) to authenticated;
revoke all on function public.review_report(uuid, text, text) from public;
grant execute on function public.review_report(uuid, text, text) to authenticated;

