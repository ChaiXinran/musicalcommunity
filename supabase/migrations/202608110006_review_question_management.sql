-- Level 1 administrators may maintain approved questions. "Delete" is a
-- soft delete so historical account applications keep their question record
-- and immutable question_snapshot.

create or replace function public.update_account_review_question(
  p_question_id uuid,
  p_prompt text
)
returns public.account_review_questions
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
  clean_prompt text := btrim(coalesce(p_prompt, ''));
  result public.account_review_questions;
begin
  if private.management_level(actor) is distinct from 1 then
    raise exception 'Level 1 administrator required' using errcode = '42501';
  end if;
  if char_length(clean_prompt) not between 10 and 500 then
    raise exception 'Question must contain 10 to 500 characters' using errcode = '22001';
  end if;

  update public.account_review_questions
  set prompt = clean_prompt
  where id = p_question_id and status = 'approved' and is_active
  returning * into result;
  if not found then raise exception 'Active approved question not found' using errcode = 'P0002'; end if;

  insert into public.admin_audit_log (actor_id, action, target_id, metadata)
  values (actor, 'update_question', p_question_id, jsonb_build_object('prompt', clean_prompt));
  return result;
end;
$$;

create or replace function public.delete_account_review_question(p_question_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := (select auth.uid());
begin
  if private.management_level(actor) is distinct from 1 then
    raise exception 'Level 1 administrator required' using errcode = '42501';
  end if;

  update public.account_review_questions
  set is_active = false
  where id = p_question_id and status = 'approved' and is_active;
  if not found then raise exception 'Active approved question not found' using errcode = 'P0002'; end if;

  insert into public.admin_audit_log (actor_id, action, target_id, metadata)
  values (actor, 'delete_question', p_question_id, jsonb_build_object('soft_deleted', true));
  return true;
end;
$$;

revoke all on function public.update_account_review_question(uuid, text) from public;
grant execute on function public.update_account_review_question(uuid, text) to authenticated;
revoke all on function public.delete_account_review_question(uuid) from public;
grant execute on function public.delete_account_review_question(uuid) to authenticated;
