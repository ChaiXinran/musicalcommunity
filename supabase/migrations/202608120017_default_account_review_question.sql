-- Stable system fallback used when the client cannot load a random question.
insert into public.account_review_questions (
  id, prompt, status, is_active, proposed_by, reviewed_by, review_note, reviewed_at
)
values (
  '00000000-0000-4000-8000-000000000017'::uuid,
  '你为什么喜欢龙龙和嘎嘎呢？',
  'approved',
  true,
  null,
  null,
  '系统内置网络异常兜底题目，请勿停用。',
  now()
)
on conflict (id) do update set
  prompt = excluded.prompt,
  status = 'approved',
  is_active = true,
  review_note = excluded.review_note,
  reviewed_at = coalesce(public.account_review_questions.reviewed_at, now()),
  updated_at = now();

-- Keep the fallback out of normal random rotation. It is returned only when
-- the regular pool/API is unavailable.
create or replace function public.random_account_review_question()
returns table (id uuid, prompt text)
language sql
volatile
security definer
set search_path = ''
as $$
  select q.id, q.prompt
  from public.account_review_questions q
  where q.status = 'approved'
    and q.is_active
    and q.id <> '00000000-0000-4000-8000-000000000017'::uuid
  order by random()
  limit 1;
$$;
