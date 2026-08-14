alter table public.comments add column reply_to_id uuid references public.comments(id) on delete restrict;
update public.comments set reply_to_id = parent_id where parent_id is not null;

create or replace function private.validate_comment_parent()
returns trigger language plpgsql security definer set search_path = '' as $$
declare parent_row public.comments; target_row public.comments;
begin
  if new.parent_id is null then new.reply_to_id := null; return new; end if;
  select * into parent_row from public.comments where id = new.parent_id;
  if not found then raise exception 'Parent comment does not exist' using errcode = '23503'; end if;
  if parent_row.parent_id is not null then raise exception 'Only two comment levels are supported' using errcode = '23514'; end if;
  if parent_row.event_id <> new.event_id or parent_row.site_id <> new.site_id then raise exception 'Reply must use the same site and event as its parent' using errcode = '23514'; end if;
  new.reply_to_id := coalesce(new.reply_to_id, new.parent_id);
  select * into target_row from public.comments where id = new.reply_to_id;
  if not found or target_row.event_id <> new.event_id or target_row.site_id <> new.site_id
    or (target_row.id <> parent_row.id and target_row.parent_id <> parent_row.id) then
    raise exception 'Reply target must belong to the same two-level thread' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger comments_validate_parent on public.comments;
create trigger comments_validate_parent before insert or update of parent_id, reply_to_id, event_id, site_id on public.comments
for each row execute function private.validate_comment_parent();
grant insert (site_id, event_id, user_id, parent_id, reply_to_id, content, status) on public.comments to authenticated;

create table public.discussion_post_comments (
  id uuid primary key default extensions.gen_random_uuid(),
  post_id uuid not null references public.discussion_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  parent_id uuid references public.discussion_post_comments(id) on delete restrict,
  reply_to_id uuid references public.discussion_post_comments(id) on delete restrict,
  content text not null check (char_length(btrim(content)) between 1 and 2000),
  status public.comment_status not null default 'published',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index discussion_post_comments_post_created_idx on public.discussion_post_comments (post_id, created_at);
create index discussion_post_comments_parent_idx on public.discussion_post_comments (parent_id) where parent_id is not null;

create function private.validate_discussion_post_comment_parent()
returns trigger language plpgsql security definer set search_path = '' as $$
declare parent_row public.discussion_post_comments; target_row public.discussion_post_comments;
begin
  if new.parent_id is null then new.reply_to_id := null; return new; end if;
  select * into parent_row from public.discussion_post_comments where id = new.parent_id;
  if not found then raise exception 'Parent comment does not exist' using errcode = '23503'; end if;
  if parent_row.parent_id is not null then raise exception 'Only two comment levels are supported' using errcode = '23514'; end if;
  if parent_row.post_id <> new.post_id then raise exception 'Reply must use the same post as its parent' using errcode = '23514'; end if;
  new.reply_to_id := coalesce(new.reply_to_id, new.parent_id);
  select * into target_row from public.discussion_post_comments where id = new.reply_to_id;
  if not found or target_row.post_id <> new.post_id
    or (target_row.id <> parent_row.id and target_row.parent_id <> parent_row.id) then
    raise exception 'Reply target must belong to the same two-level thread' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger discussion_post_comments_validate_parent
before insert or update of parent_id, reply_to_id, post_id on public.discussion_post_comments
for each row execute function private.validate_discussion_post_comment_parent();
create trigger discussion_post_comments_set_updated_at
before update on public.discussion_post_comments for each row execute function private.set_updated_at();

alter table public.discussion_post_comments enable row level security;
create policy discussion_post_comments_member_read on public.discussion_post_comments for select to authenticated
using (private.is_active_user((select auth.uid())) and exists (
  select 1 from public.user_site_access usa where usa.user_id = (select auth.uid()) and usa.site_id = 'duo'
));
create policy discussion_post_comments_member_insert on public.discussion_post_comments for insert to authenticated
with check (user_id = (select auth.uid()) and status = 'published' and private.is_active_user((select auth.uid()))
  and exists (select 1 from public.user_site_access usa where usa.user_id = (select auth.uid()) and usa.site_id = 'duo')
  and exists (select 1 from public.discussion_posts dp where dp.id = discussion_post_comments.post_id and dp.status = 'published'));
create policy discussion_post_comments_owner_update on public.discussion_post_comments for update to authenticated
using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())))
with check (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())));
create policy discussion_post_comments_moderator_update on public.discussion_post_comments for update to authenticated
using (private.management_level((select auth.uid())) between 1 and 3)
with check (private.management_level((select auth.uid())) between 1 and 3);

grant select on public.discussion_post_comments to authenticated;
grant insert (post_id, user_id, parent_id, reply_to_id, content, status) on public.discussion_post_comments to authenticated;
grant update (content, status) on public.discussion_post_comments to authenticated;
