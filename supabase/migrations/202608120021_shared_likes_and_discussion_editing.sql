-- Persistent likes shared by discussion cards and every representation of an event.

begin;

create table if not exists public.event_likes (
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);

create index if not exists event_likes_event_created_idx
  on public.event_likes (event_id, created_at desc);

alter table public.event_likes enable row level security;

drop policy if exists event_likes_public_read on public.event_likes;
create policy event_likes_public_read on public.event_likes
for select to anon, authenticated using (true);

drop policy if exists event_likes_member_insert on public.event_likes;
create policy event_likes_member_insert on public.event_likes
for insert to authenticated with check (
  user_id = (select auth.uid())
  and private.is_active_user((select auth.uid()))
  and exists (
    select 1
    from public.event_sites es
    join public.user_site_access usa on usa.site_id = es.site_id
    where es.event_id = event_likes.event_id
      and usa.user_id = (select auth.uid())
  )
);

drop policy if exists event_likes_owner_delete on public.event_likes;
create policy event_likes_owner_delete on public.event_likes
for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.event_likes from anon, authenticated;
grant select on public.event_likes to anon, authenticated;
grant insert, delete on public.event_likes to authenticated;

create table if not exists public.discussion_post_likes (
  user_id uuid not null references auth.users(id) on delete cascade,
  post_id uuid not null references public.discussion_posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

create index if not exists discussion_post_likes_post_created_idx
  on public.discussion_post_likes (post_id, created_at desc);

alter table public.discussion_post_likes enable row level security;

drop policy if exists discussion_post_likes_approved_read on public.discussion_post_likes;
create policy discussion_post_likes_approved_read on public.discussion_post_likes
for select to authenticated using (
  private.is_active_user((select auth.uid()))
  and exists (
    select 1 from public.user_site_access usa
    where usa.user_id = (select auth.uid()) and usa.site_id = 'duo'
  )
);

drop policy if exists discussion_post_likes_member_insert on public.discussion_post_likes;
create policy discussion_post_likes_member_insert on public.discussion_post_likes
for insert to authenticated with check (
  user_id = (select auth.uid())
  and private.is_active_user((select auth.uid()))
  and exists (
    select 1 from public.user_site_access usa
    where usa.user_id = (select auth.uid()) and usa.site_id = 'duo'
  )
  and exists (
    select 1 from public.discussion_posts dp
    where dp.id = discussion_post_likes.post_id and dp.status = 'published'
  )
);

drop policy if exists discussion_post_likes_owner_delete on public.discussion_post_likes;
create policy discussion_post_likes_owner_delete on public.discussion_post_likes
for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.discussion_post_likes from anon, authenticated;
grant select, insert, delete on public.discussion_post_likes to authenticated;

create or replace view public.event_like_counts
with (security_invoker = true)
as select event_id, count(*)::bigint as like_count
from public.event_likes group by event_id;

create or replace view public.discussion_post_like_counts
with (security_invoker = true)
as select post_id, count(*)::bigint as like_count
from public.discussion_post_likes group by post_id;

create or replace view public.comment_like_counts
with (security_invoker = true)
as select comment_id, count(*)::bigint as like_count
from public.comment_likes group by comment_id;

grant select on public.event_like_counts to anon, authenticated;
grant select on public.discussion_post_like_counts, public.comment_like_counts to authenticated;

commit;
