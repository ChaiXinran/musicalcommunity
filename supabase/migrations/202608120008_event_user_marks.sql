-- Per-user activity marks shared by the globe, map drawers and category cards.

begin;

create table if not exists public.event_user_marks (
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  mark_type text not null check (mark_type in ('watched', 'recommended')),
  created_at timestamptz not null default now(),
  primary key (user_id, event_id, mark_type)
);

create index if not exists event_user_marks_user_created_idx
  on public.event_user_marks (user_id, created_at desc);
create index if not exists event_user_marks_event_type_idx
  on public.event_user_marks (event_id, mark_type);

alter table public.event_user_marks enable row level security;

drop policy if exists event_user_marks_owner_read on public.event_user_marks;
create policy event_user_marks_owner_read on public.event_user_marks
for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists event_user_marks_owner_insert on public.event_user_marks;
create policy event_user_marks_owner_insert on public.event_user_marks
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and private.is_active_user((select auth.uid()))
  and exists (select 1 from public.events e where e.id = event_id and e.status = 'published')
);

drop policy if exists event_user_marks_owner_delete on public.event_user_marks;
create policy event_user_marks_owner_delete on public.event_user_marks
for delete to authenticated
using (user_id = (select auth.uid()));

revoke all on public.event_user_marks from anon, authenticated;
grant select, insert, delete on public.event_user_marks to authenticated;

commit;
