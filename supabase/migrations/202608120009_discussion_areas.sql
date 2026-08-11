-- Dedicated discussion areas for the dual-person site.
-- Event discussions continue to use public.comments so every map/card shares one thread.

create table public.discussion_posts (
  id uuid primary key default extensions.gen_random_uuid(),
  author_id uuid not null references auth.users(id) on delete cascade,
  section text not null check (section in ('vent', 'encounter')),
  zone text check (zone is null or zone in ('yunduo', 'xingxing')),
  content text not null check (char_length(btrim(content)) between 1 and 5000),
  event_name text check (event_name is null or char_length(event_name) between 1 and 200),
  occurred_at timestamptz,
  location text check (location is null or char_length(location) between 1 and 300),
  links jsonb not null default '[]'::jsonb check (jsonb_typeof(links) = 'array' and jsonb_array_length(links) <= 12),
  media_keys text[] not null default '{}',
  status public.comment_status not null default 'published',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint discussion_post_shape check (
    (section = 'vent' and zone in ('yunduo', 'xingxing') and event_name is null and occurred_at is null and location is null)
    or
    (section = 'encounter' and zone is null and event_name is not null and occurred_at is not null and location is not null)
  ),
  constraint discussion_media_limit check (cardinality(media_keys) <= 6),
  constraint discussion_media_keys check (
    cardinality(media_keys) = 0
    or array_to_string(media_keys, ',') ~ '^comment-images/[0-9a-f-]+/[A-Za-z0-9._-]+(,comment-images/[0-9a-f-]+/[A-Za-z0-9._-]+)*$'
  )
);

create index discussion_posts_section_created_idx on public.discussion_posts (section, created_at desc)
where status = 'published';
create index discussion_posts_zone_created_idx on public.discussion_posts (zone, created_at desc)
where section = 'vent' and status = 'published';
create index discussion_posts_encounter_time_idx on public.discussion_posts (occurred_at desc)
where section = 'encounter' and status = 'published';
create index discussion_posts_author_created_idx on public.discussion_posts (author_id, created_at desc);

create function private.validate_discussion_post_media()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  media_key text;
begin
  foreach media_key in array new.media_keys loop
    if not exists (
      select 1 from public.media m
      where m.object_key = media_key
        and m.owner_id = new.author_id
        and m.purpose = 'comment_image'
        and m.status = 'available'
    ) then
      raise exception 'Discussion media is unavailable or does not belong to the author' using errcode = '23514';
    end if;
  end loop;
  return new;
end;
$$;

create trigger discussion_posts_validate_media
before insert or update of media_keys, author_id on public.discussion_posts
for each row execute function private.validate_discussion_post_media();

create trigger discussion_posts_set_updated_at
before update on public.discussion_posts
for each row execute function private.set_updated_at();

alter table public.discussion_posts enable row level security;

create policy discussion_posts_public_read on public.discussion_posts for select to anon, authenticated
using (status in ('published', 'deleted'));

create policy discussion_posts_owner_insert on public.discussion_posts for insert to authenticated
with check (
  author_id = (select auth.uid())
  and status = 'published'
  and private.is_active_user((select auth.uid()))
);

create policy discussion_posts_owner_update on public.discussion_posts for update to authenticated
using (author_id = (select auth.uid()) and private.is_active_user((select auth.uid())))
with check (author_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

create policy discussion_posts_owner_delete on public.discussion_posts for delete to authenticated
using (author_id = (select auth.uid()) and private.is_active_user((select auth.uid())));

create policy discussion_posts_moderator_update on public.discussion_posts for update to authenticated
using (private.management_level((select auth.uid())) between 1 and 3)
with check (private.management_level((select auth.uid())) between 1 and 3);

drop policy if exists media_public_available_read on public.media;
create policy media_public_available_read on public.media for select to anon, authenticated
using (status = 'available' and purpose in ('avatar', 'event_photo', 'comment_image'));

grant select on public.discussion_posts to anon, authenticated;
grant insert (author_id, section, zone, content, event_name, occurred_at, location, links, media_keys, status)
on public.discussion_posts to authenticated;
grant update (content, event_name, occurred_at, location, links, media_keys, status)
on public.discussion_posts to authenticated;
grant delete on public.discussion_posts to authenticated;
