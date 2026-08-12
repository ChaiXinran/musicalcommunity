-- Enforce site membership for comments and likes even when clients access Supabase directly.

drop policy if exists comments_approved_read on public.comments;
create policy comments_approved_read on public.comments for select to authenticated using (
  private.is_active_user((select auth.uid()))
  and status in ('published', 'deleted')
  and exists (select 1 from public.user_site_access a where a.user_id = (select auth.uid()) and a.site_id = comments.site_id)
);

drop policy if exists comments_owner_insert on public.comments;
create policy comments_owner_insert on public.comments for insert to authenticated with check (
  user_id = (select auth.uid()) and status = 'published' and private.is_active_user((select auth.uid()))
  and exists (select 1 from public.user_site_access a where a.user_id = (select auth.uid()) and a.site_id = comments.site_id)
);

drop policy if exists comments_owner_update on public.comments;
create policy comments_owner_update on public.comments for update to authenticated
using (
  user_id = (select auth.uid()) and status = 'published' and private.is_active_user((select auth.uid()))
  and exists (select 1 from public.user_site_access a where a.user_id = (select auth.uid()) and a.site_id = comments.site_id)
)
with check (user_id = (select auth.uid()) and status = 'published');

drop policy if exists likes_owner_insert on public.comment_likes;
create policy likes_owner_insert on public.comment_likes for insert to authenticated with check (
  user_id = (select auth.uid()) and private.is_active_user((select auth.uid()))
  and exists (
    select 1 from public.comments c
    join public.user_site_access a on a.user_id = (select auth.uid()) and a.site_id = c.site_id
    where c.id = comment_id and c.status = 'published'
  )
);

