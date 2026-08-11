-- Musical Community Backend v1
-- One account system, one event catalogue, site-scoped discussions, shared favourites.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create type public.profile_status as enum ('active', 'suspended', 'deleted');
create type public.app_role as enum ('user', 'editor', 'moderator', 'admin');
create type public.site_status as enum ('active', 'hidden');
create type public.event_status as enum ('draft', 'published', 'archived');
create type public.comment_status as enum ('published', 'hidden', 'deleted');
create type public.submission_status as enum ('draft', 'pending', 'approved', 'rejected', 'merged');
create type public.media_status as enum ('pending_upload', 'available', 'quarantined', 'deleted');
create type public.media_purpose as enum ('avatar', 'submission', 'event_photo', 'comment_image');
create type public.report_status as enum ('open', 'reviewing', 'resolved', 'dismissed');
create type public.moderation_action_type as enum ('hide_comment', 'restore_comment', 'suspend_user', 'unsuspend_user', 'resolve_report');

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username extensions.citext unique,
  display_name text not null default '新用户' check (char_length(display_name) between 1 and 80),
  avatar_key text check (avatar_key is null or avatar_key ~ '^avatars/[0-9a-f-]+/[A-Za-z0-9._-]+$'),
  bio text not null default '' check (char_length(bio) <= 500),
  status public.profile_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint username_format check (username is null or username::text ~ '^[a-zA-Z0-9_]{3,30}$')
);

create table public.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null,
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table public.sites (
  id text primary key check (id ~ '^[a-z][a-z0-9_-]{1,31}$'),
  name text not null check (char_length(name) between 1 and 100),
  base_url text not null unique check (base_url ~ '^https://'),
  status public.site_status not null default 'active',
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.persons (
  id text primary key check (id ~ '^[a-z][a-z0-9_-]{1,63}$'),
  display_name text not null check (char_length(display_name) between 1 and 100),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.venues (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 200),
  city text,
  country text,
  latitude numeric(9,6) check (latitude between -90 and 90),
  longitude numeric(9,6) check (longitude between -180 and 180),
  address text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.events (
  id uuid primary key default extensions.gen_random_uuid(),
  slug text unique check (slug is null or slug ~ '^[a-z0-9][a-z0-9-]{2,127}$'),
  title text not null check (char_length(title) between 1 and 200),
  category text not null check (char_length(category) between 1 and 80),
  start_time timestamptz not null,
  end_time timestamptz,
  venue_id uuid references public.venues(id) on delete set null,
  city text,
  country text,
  latitude numeric(9,6) check (latitude between -90 and 90),
  longitude numeric(9,6) check (longitude between -180 and 180),
  description text not null default '' check (char_length(description) <= 10000),
  source_url text check (source_url is null or source_url ~ '^https?://'),
  status public.event_status not null default 'draft',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint valid_event_time check (end_time is null or end_time >= start_time),
  constraint complete_event_coordinates check ((latitude is null) = (longitude is null))
);

create table public.event_sites (
  event_id uuid not null references public.events(id) on delete cascade,
  site_id text not null references public.sites(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (event_id, site_id)
);

create table public.event_people (
  event_id uuid not null references public.events(id) on delete cascade,
  person_id text not null references public.persons(id) on delete restrict,
  role text not null default 'performer' check (char_length(role) between 1 and 80),
  created_at timestamptz not null default now(),
  primary key (event_id, person_id, role)
);

create table public.comments (
  id uuid primary key default extensions.gen_random_uuid(),
  site_id text not null,
  event_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  parent_id uuid references public.comments(id) on delete restrict,
  content text not null check (char_length(btrim(content)) between 1 and 2000),
  status public.comment_status not null default 'published',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (event_id, site_id) references public.event_sites(event_id, site_id) on delete cascade
);

create table public.comment_likes (
  user_id uuid not null references auth.users(id) on delete cascade,
  comment_id uuid not null references public.comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, comment_id)
);

create table public.event_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);

create table public.event_submissions (
  id uuid primary key default extensions.gen_random_uuid(),
  submitter_id uuid not null references auth.users(id) on delete cascade,
  proposed_sites text[] not null check (cardinality(proposed_sites) between 1 and 16),
  title text not null check (char_length(title) between 1 and 200),
  category text not null check (char_length(category) between 1 and 80),
  start_time timestamptz not null,
  end_time timestamptz,
  venue text,
  city text,
  country text,
  latitude numeric(9,6) check (latitude between -90 and 90),
  longitude numeric(9,6) check (longitude between -180 and 180),
  description text not null default '' check (char_length(description) <= 10000),
  source_url text check (source_url is null or source_url ~ '^https?://'),
  payload_json jsonb not null default '{}'::jsonb check (jsonb_typeof(payload_json) = 'object'),
  status public.submission_status not null default 'draft',
  reviewer_id uuid references auth.users(id) on delete set null,
  review_note text check (review_note is null or char_length(review_note) <= 2000),
  merged_into_event_id uuid references public.events(id) on delete set null,
  approved_event_id uuid references public.events(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  reviewed_at timestamptz,
  constraint valid_submission_time check (end_time is null or end_time >= start_time),
  constraint complete_submission_coordinates check ((latitude is null) = (longitude is null)),
  constraint submission_resolution_consistency check (
    (status = 'merged' and merged_into_event_id is not null and approved_event_id is null)
    or (status = 'approved' and approved_event_id is not null and merged_into_event_id is null)
    or (status not in ('approved', 'merged') and approved_event_id is null and merged_into_event_id is null)
  )
);

create table public.media (
  id uuid primary key default extensions.gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  bucket text not null default 'musical-community',
  object_key text not null unique check (object_key !~ '(^|/)\.\.(/|$)'),
  purpose public.media_purpose not null,
  content_type text not null,
  byte_size bigint not null check (byte_size > 0 and byte_size <= 104857600),
  sha256 text check (sha256 is null or sha256 ~ '^[a-f0-9]{64}$'),
  status public.media_status not null default 'pending_upload',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.submission_media (
  submission_id uuid not null references public.event_submissions(id) on delete cascade,
  media_id uuid not null references public.media(id) on delete cascade,
  sort_order smallint not null default 0 check (sort_order >= 0),
  created_at timestamptz not null default now(),
  primary key (submission_id, media_id)
);

create table public.reports (
  id uuid primary key default extensions.gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  comment_id uuid references public.comments(id) on delete cascade,
  reported_user_id uuid references auth.users(id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 100),
  details text not null default '' check (char_length(details) <= 2000),
  status public.report_status not null default 'open',
  resolved_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  constraint one_report_subject check (num_nonnulls(comment_id, reported_user_id) = 1)
);

create table public.moderation_actions (
  id uuid primary key default extensions.gen_random_uuid(),
  actor_id uuid not null references auth.users(id) on delete restrict,
  action public.moderation_action_type not null,
  target_user_id uuid references auth.users(id) on delete set null,
  target_comment_id uuid references public.comments(id) on delete set null,
  report_id uuid references public.reports(id) on delete set null,
  reason text not null check (char_length(reason) between 1 and 2000),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now()
);

create table public.user_bans (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  issued_by uuid not null references auth.users(id) on delete restrict,
  reason text not null check (char_length(reason) between 1 and 2000),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint valid_ban_time check (ends_at is null or ends_at > starts_at)
);

create index events_status_start_time_idx on public.events (status, start_time desc);
create index event_sites_site_event_idx on public.event_sites (site_id, event_id);
create index event_people_person_event_idx on public.event_people (person_id, event_id);
create index comments_context_created_idx on public.comments (site_id, event_id, created_at);
create index comments_parent_idx on public.comments (parent_id) where parent_id is not null;
create index comments_user_created_idx on public.comments (user_id, created_at desc);
create index event_favorites_user_created_idx on public.event_favorites (user_id, created_at desc);
create index submissions_submitter_created_idx on public.event_submissions (submitter_id, created_at desc);
create index submissions_status_created_idx on public.event_submissions (status, created_at) where status = 'pending';
create index media_owner_created_idx on public.media (owner_id, created_at desc);
create index reports_status_created_idx on public.reports (status, created_at) where status in ('open', 'reviewing');
create index user_bans_active_idx on public.user_bans (user_id, starts_at, ends_at) where revoked_at is null;

create function private.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at before update on public.profiles for each row execute function private.set_updated_at();
create trigger sites_set_updated_at before update on public.sites for each row execute function private.set_updated_at();
create trigger persons_set_updated_at before update on public.persons for each row execute function private.set_updated_at();
create trigger venues_set_updated_at before update on public.venues for each row execute function private.set_updated_at();
create trigger events_set_updated_at before update on public.events for each row execute function private.set_updated_at();
create trigger comments_set_updated_at before update on public.comments for each row execute function private.set_updated_at();
create trigger submissions_set_updated_at before update on public.event_submissions for each row execute function private.set_updated_at();
create trigger media_set_updated_at before update on public.media for each row execute function private.set_updated_at();

create function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id, display_name)
  values (new.id, left(coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(coalesce(new.email, '新用户'), '@', 1)), 80));
  insert into public.user_roles (user_id, role) values (new.id, 'user');
  return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users for each row execute function private.handle_new_user();

create function private.has_role(p_user_id uuid, p_roles public.app_role[])
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.user_roles where user_id = p_user_id and role = any (p_roles));
$$;

create function private.is_active_user(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p where p.user_id = p_user_id and p.status = 'active'
  ) and not exists (
    select 1 from public.user_bans b
    where b.user_id = p_user_id and b.revoked_at is null and b.starts_at <= now()
      and (b.ends_at is null or b.ends_at > now())
  );
$$;

create function private.validate_comment_parent()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  parent_row public.comments;
begin
  if new.parent_id is null then return new; end if;
  select * into parent_row from public.comments where id = new.parent_id;
  if not found then raise exception 'Parent comment does not exist' using errcode = '23503'; end if;
  if parent_row.parent_id is not null then raise exception 'Only two comment levels are supported' using errcode = '23514'; end if;
  if parent_row.event_id <> new.event_id or parent_row.site_id <> new.site_id then
    raise exception 'Reply must use the same site and event as its parent' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger comments_validate_parent before insert or update of parent_id, event_id, site_id on public.comments
for each row execute function private.validate_comment_parent();

create function private.validate_proposed_sites()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.proposed_sites := array(select distinct x from unnest(new.proposed_sites) as requested(x) order by x);
  if exists (
    select 1 from unnest(new.proposed_sites) requested(id)
    left join public.sites s on s.id = requested.id and s.status = 'active'
    where s.id is null
  ) then
    raise exception 'proposed_sites contains an unknown or inactive site' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger submissions_validate_sites before insert or update of proposed_sites on public.event_submissions
for each row execute function private.validate_proposed_sites();

create function public.delete_own_comment(p_comment_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.comments set status = 'deleted', content = '[已删除]'
  where id = p_comment_id and user_id = (select auth.uid()) and status <> 'deleted';
  if not found then raise exception 'Comment not found or not owned by current user' using errcode = 'P0002'; end if;
end;
$$;

create function public.review_event_submission(
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
  if reviewer is null or not private.has_role(reviewer, array['moderator', 'admin']::public.app_role[]) then
    raise exception 'Moderator role required' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected', 'merged') then
    raise exception 'Decision must be approved, rejected, or merged' using errcode = '22023';
  end if;
  select * into submission from public.event_submissions where id = p_submission_id for update;
  if not found then raise exception 'Submission not found' using errcode = 'P0002'; end if;
  if submission.status <> 'pending' then raise exception 'Only pending submissions can be reviewed' using errcode = '55000'; end if;

  if p_decision = 'merged' then
    if p_target_event_id is null or not exists (select 1 from public.events where id = p_target_event_id and status <> 'archived') then
      raise exception 'A valid target event is required for merge' using errcode = '23503';
    end if;
    update public.event_submissions
    set status = 'merged', reviewer_id = reviewer, review_note = p_review_note,
        merged_into_event_id = p_target_event_id, reviewed_at = now()
    where id = p_submission_id;
    return p_target_event_id;
  end if;

  if p_decision = 'rejected' then
    update public.event_submissions
    set status = 'rejected', reviewer_id = reviewer, review_note = p_review_note, reviewed_at = now()
    where id = p_submission_id;
    return null;
  end if;

  if submission.venue is not null and btrim(submission.venue) <> '' then
    insert into public.venues (name, city, country, latitude, longitude)
    values (submission.venue, submission.city, submission.country, submission.latitude, submission.longitude)
    returning id into new_venue_id;
  end if;
  insert into public.events (
    title, category, start_time, end_time, venue_id, city, country,
    latitude, longitude, description, source_url, status, created_by
  ) values (
    submission.title, submission.category, submission.start_time, submission.end_time,
    new_venue_id, submission.city, submission.country, submission.latitude, submission.longitude,
    submission.description, submission.source_url, 'published', submission.submitter_id
  ) returning id into new_event_id;
  insert into public.event_sites (event_id, site_id)
  select new_event_id, site_id from unnest(submission.proposed_sites) as proposed(site_id);
  update public.event_submissions
  set status = 'approved', reviewer_id = reviewer, review_note = p_review_note,
      approved_event_id = new_event_id, reviewed_at = now()
  where id = p_submission_id;
  return new_event_id;
end;
$$;

revoke all on schema private from public;
grant usage on schema private to anon, authenticated;
revoke all on all functions in schema private from public;
grant execute on function private.has_role(uuid, public.app_role[]) to anon, authenticated;
grant execute on function private.is_active_user(uuid) to authenticated;
revoke all on function public.delete_own_comment(uuid) from public;
grant execute on function public.delete_own_comment(uuid) to authenticated;
revoke all on function public.review_event_submission(uuid, text, text, uuid) from public;
grant execute on function public.review_event_submission(uuid, text, text, uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.sites enable row level security;
alter table public.persons enable row level security;
alter table public.venues enable row level security;
alter table public.events enable row level security;
alter table public.event_sites enable row level security;
alter table public.event_people enable row level security;
alter table public.comments enable row level security;
alter table public.comment_likes enable row level security;
alter table public.event_favorites enable row level security;
alter table public.event_submissions enable row level security;
alter table public.media enable row level security;
alter table public.submission_media enable row level security;
alter table public.reports enable row level security;
alter table public.moderation_actions enable row level security;
alter table public.user_bans enable row level security;

create policy profiles_public_read on public.profiles for select to anon, authenticated
using (status = 'active' or user_id = (select auth.uid()) or private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));
create policy profiles_owner_update on public.profiles for update to authenticated
using (user_id = (select auth.uid()) and private.is_active_user((select auth.uid())))
with check (user_id = (select auth.uid()) and status = 'active');
create policy user_roles_owner_read on public.user_roles for select to authenticated
using (user_id = (select auth.uid()) or private.has_role((select auth.uid()), array['admin']::public.app_role[]));
create policy sites_public_read on public.sites for select to anon, authenticated using (status = 'active');
create policy persons_public_read on public.persons for select to anon, authenticated using (true);
create policy venues_public_read on public.venues for select to anon, authenticated
using (exists (select 1 from public.events e where e.venue_id = venues.id and e.status = 'published'));
create policy events_public_read on public.events for select to anon, authenticated using (status = 'published');
create policy event_sites_public_read on public.event_sites for select to anon, authenticated
using (exists (select 1 from public.events e where e.id = event_sites.event_id and e.status = 'published'));
create policy event_people_public_read on public.event_people for select to anon, authenticated
using (exists (select 1 from public.events e where e.id = event_people.event_id and e.status = 'published'));

create policy comments_public_read on public.comments for select to anon, authenticated using (status in ('published', 'deleted'));
create policy comments_owner_insert on public.comments for insert to authenticated
with check (user_id = (select auth.uid()) and status = 'published' and private.is_active_user((select auth.uid())));
create policy comments_owner_update on public.comments for update to authenticated
using (user_id = (select auth.uid()) and status = 'published' and private.is_active_user((select auth.uid())))
with check (user_id = (select auth.uid()) and status = 'published');
create policy comments_moderator_update on public.comments for update to authenticated
using (private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]))
with check (private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));

create policy likes_public_read on public.comment_likes for select to anon, authenticated using (true);
create policy likes_owner_insert on public.comment_likes for insert to authenticated
with check (
  user_id = (select auth.uid()) and private.is_active_user((select auth.uid()))
  and exists (select 1 from public.comments c where c.id = comment_id and c.status = 'published')
);
create policy likes_owner_delete on public.comment_likes for delete to authenticated using (user_id = (select auth.uid()));

create policy favorites_owner_read on public.event_favorites for select to authenticated using (user_id = (select auth.uid()));
create policy favorites_owner_insert on public.event_favorites for insert to authenticated
with check (
  user_id = (select auth.uid()) and private.is_active_user((select auth.uid()))
  and exists (select 1 from public.events e where e.id = event_id and e.status = 'published')
);
create policy favorites_owner_delete on public.event_favorites for delete to authenticated using (user_id = (select auth.uid()));

create policy submissions_owner_read on public.event_submissions for select to authenticated
using (submitter_id = (select auth.uid()) or private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));
create policy submissions_owner_draft_insert on public.event_submissions for insert to authenticated
with check (submitter_id = (select auth.uid()) and status = 'draft' and private.is_active_user((select auth.uid())));
create policy submissions_owner_draft_update on public.event_submissions for update to authenticated
using (submitter_id = (select auth.uid()) and status = 'draft' and private.is_active_user((select auth.uid())))
with check (submitter_id = (select auth.uid()) and status = 'draft');

create policy media_owner_read on public.media for select to authenticated
using (owner_id = (select auth.uid()) or private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));
create policy media_public_available_read on public.media for select to anon, authenticated
using (status = 'available' and purpose in ('avatar','event_photo'));
create policy submission_media_owner_read on public.submission_media for select to authenticated
using (exists (
  select 1 from public.event_submissions s where s.id = submission_media.submission_id
  and (s.submitter_id = (select auth.uid()) or private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]))
));

create policy reports_owner_insert on public.reports for insert to authenticated
with check (reporter_id = (select auth.uid()) and status = 'open' and private.is_active_user((select auth.uid())));
create policy reports_owner_or_moderator_read on public.reports for select to authenticated
using (reporter_id = (select auth.uid()) or private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));
create policy reports_moderator_update on public.reports for update to authenticated
using (private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]))
with check (private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));
create policy moderation_actions_moderator_read on public.moderation_actions for select to authenticated
using (private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));
create policy moderation_actions_moderator_insert on public.moderation_actions for insert to authenticated
with check (actor_id = (select auth.uid()) and private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));
create policy user_bans_owner_or_moderator_read on public.user_bans for select to authenticated
using (user_id = (select auth.uid()) or private.has_role((select auth.uid()), array['moderator','admin']::public.app_role[]));

revoke all on all tables in schema public from anon, authenticated;
grant select on public.profiles, public.sites, public.persons, public.venues, public.events,
  public.event_sites, public.event_people, public.comments, public.comment_likes to anon, authenticated;
grant select on public.user_roles, public.event_favorites, public.event_submissions, public.media,
  public.submission_media, public.reports, public.moderation_actions, public.user_bans to authenticated;
grant update (username, display_name, avatar_key, bio) on public.profiles to authenticated;
grant insert (site_id, event_id, user_id, parent_id, content, status) on public.comments to authenticated;
grant update (content, status) on public.comments to authenticated;
grant insert, delete on public.comment_likes, public.event_favorites to authenticated;
grant insert (
  submitter_id, proposed_sites, title, category, start_time, end_time, venue, city, country,
  latitude, longitude, description, source_url, payload_json, status
) on public.event_submissions to authenticated;
grant update (
  proposed_sites, title, category, start_time, end_time, venue, city, country,
  latitude, longitude, description, source_url, payload_json
) on public.event_submissions to authenticated;
grant insert (reporter_id, comment_id, reported_user_id, reason, details, status) on public.reports to authenticated;
grant update (status, resolved_by, resolved_at) on public.reports to authenticated;
grant insert on public.moderation_actions to authenticated;
