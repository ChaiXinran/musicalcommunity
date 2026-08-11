drop policy if exists discussion_posts_public_read on public.discussion_posts;

create policy discussion_posts_approved_read on public.discussion_posts
for select to authenticated
using (
  private.is_active_user((select auth.uid()))
  and status in ('published', 'deleted')
);

revoke select on public.discussion_posts from anon;
grant select on public.discussion_posts to authenticated;

drop policy if exists comments_public_read on public.comments;

create policy comments_approved_read on public.comments
for select to authenticated
using (
  private.is_active_user((select auth.uid()))
  and status in ('published', 'deleted')
);

revoke select on public.comments from anon;
grant select on public.comments to authenticated;
