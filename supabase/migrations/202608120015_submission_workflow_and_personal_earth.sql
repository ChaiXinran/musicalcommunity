-- Public/private submissions, edit proposals, contribution attribution and personal Earth.

alter table public.event_submissions
  add column if not exists submission_scope text not null default 'public'
    check (submission_scope in ('public', 'private')),
  add column if not exists submission_kind text not null default 'create'
    check (submission_kind in ('create', 'edit')),
  add column if not exists target_event_id uuid references public.events(id) on delete set null,
  add column if not exists person_ids text[] not null default '{}'::text[],
  add column if not exists media_links text[] not null default '{}'::text[],
  add column if not exists before_snapshot jsonb;

alter table public.event_submissions
  drop constraint if exists event_submissions_scope_kind_check;
alter table public.event_submissions
  add constraint event_submissions_scope_kind_check check (
    (submission_scope = 'private' and submission_kind = 'create' and target_event_id is null)
    or (submission_scope = 'public' and submission_kind = 'create' and target_event_id is null)
    or (submission_scope = 'public' and submission_kind = 'edit' and target_event_id is not null)
  );

create table if not exists public.private_events (
  id uuid primary key default extensions.gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  submission_id uuid not null unique references public.event_submissions(id) on delete cascade,
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
  media_links text[] not null default '{}'::text[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint private_event_time_check check (end_time is null or end_time >= start_time),
  constraint private_event_coordinates_check check ((latitude is null) = (longitude is null))
);

create index if not exists private_events_owner_time_idx
  on public.private_events (owner_id, start_time desc);

create table if not exists public.event_media (
  event_id uuid not null references public.events(id) on delete cascade,
  media_id uuid not null references public.media(id) on delete cascade,
  sort_order smallint not null default 0 check (sort_order >= 0),
  created_at timestamptz not null default now(),
  primary key (event_id, media_id)
);

create table if not exists public.event_contributors (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  submission_id uuid references public.event_submissions(id) on delete set null,
  contribution_type text not null default 'create' check (contribution_type in ('create', 'edit')),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id, contribution_type)
);

alter table public.private_events enable row level security;
alter table public.event_media enable row level security;
alter table public.event_contributors enable row level security;

drop policy if exists private_events_owner_all on public.private_events;
create policy private_events_owner_all on public.private_events
  for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

drop policy if exists event_media_public_read on public.event_media;
create policy event_media_public_read on public.event_media
  for select to anon, authenticated using (true);

drop policy if exists event_contributors_public_read on public.event_contributors;
create policy event_contributors_public_read on public.event_contributors
  for select to anon, authenticated using (true);

grant select, insert, update, delete on public.private_events to authenticated;
grant select on public.event_media, public.event_contributors to anon, authenticated;

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
  resolved_event_id uuid;
  new_venue_id uuid;
  selected_target uuid;
begin
  if reviewer is null or private.management_level(reviewer) is null or private.management_level(reviewer) > 3 then
    raise exception 'Administrator role required' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected', 'merged') then
    raise exception 'Decision must be approved, rejected, or merged' using errcode = '22023';
  end if;
  select * into submission from public.event_submissions where id = p_submission_id for update;
  if not found then raise exception 'Submission not found' using errcode = 'P0002'; end if;
  if submission.submission_scope <> 'public' then raise exception 'Private submissions do not require review' using errcode = '55000'; end if;
  if submission.status <> 'pending' then raise exception 'Only pending submissions can be reviewed' using errcode = '55000'; end if;

  if p_decision = 'rejected' then
    update public.event_submissions set status = 'rejected', reviewer_id = reviewer,
      review_note = p_review_note, reviewed_at = now(), updated_at = now()
    where id = p_submission_id;
    return null;
  end if;

  selected_target := coalesce(p_target_event_id, submission.target_event_id);
  if p_decision = 'merged' then
    if selected_target is null or not exists (select 1 from public.events where id = selected_target and status <> 'archived') then
      raise exception 'A valid target event is required for merge' using errcode = '23503';
    end if;
    update public.event_submissions set status = 'merged', reviewer_id = reviewer,
      review_note = p_review_note, merged_into_event_id = selected_target,
      reviewed_at = now(), updated_at = now() where id = p_submission_id;
    insert into public.event_contributors (event_id, user_id, submission_id, contribution_type)
      values (selected_target, submission.submitter_id, submission.id, 'edit') on conflict do nothing;
    return selected_target;
  end if;

  if submission.venue is not null and btrim(submission.venue) <> '' then
    insert into public.venues (name, city, country, latitude, longitude)
    values (submission.venue, submission.city, submission.country, submission.latitude, submission.longitude)
    returning id into new_venue_id;
  end if;

  if submission.submission_kind = 'edit' then
    resolved_event_id := submission.target_event_id;
    if resolved_event_id is null or not exists (select 1 from public.events where id = resolved_event_id and status <> 'archived') then
      raise exception 'Target event not found' using errcode = '23503';
    end if;
    update public.events set
      title = submission.title,
      category = submission.category,
      start_time = submission.start_time,
      end_time = submission.end_time,
      venue_id = case when submission.venue is null or btrim(submission.venue) = '' then venue_id else new_venue_id end,
      city = submission.city,
      country = submission.country,
      latitude = submission.latitude,
      longitude = submission.longitude,
      description = submission.description,
      source_url = coalesce(submission.source_url, source_url),
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'source_urls', (
          select coalesce(jsonb_agg(distinct value), '[]'::jsonb)
          from jsonb_array_elements_text(
            coalesce(metadata->'source_urls', '[]'::jsonb)
            || to_jsonb(coalesce(submission.media_links, '{}'::text[]))
            || case when submission.source_url is null then '[]'::jsonb else jsonb_build_array(submission.source_url) end
          ) as links(value)
        )
      ),
      updated_at = now()
    where id = resolved_event_id;
    delete from public.event_people where event_id = resolved_event_id;
  else
    insert into public.events (title, category, start_time, end_time, venue_id, city, country,
      latitude, longitude, description, source_url, status, created_by, metadata)
    values (submission.title, submission.category, submission.start_time, submission.end_time, new_venue_id,
      submission.city, submission.country, submission.latitude, submission.longitude, submission.description,
      submission.source_url, 'published', submission.submitter_id,
      jsonb_build_object('source_urls', to_jsonb(coalesce(submission.media_links, '{}'::text[]))))
    returning id into resolved_event_id;
  end if;

  insert into public.event_sites (event_id, site_id) values (resolved_event_id, 'duo') on conflict do nothing;
  insert into public.event_sites (event_id, site_id)
    select resolved_event_id, site_id from unnest(submission.proposed_sites) site_id
    where site_id in ('duo', 'ayg', 'zyl') on conflict do nothing;
  insert into public.event_sites (event_id, site_id)
    select resolved_event_id, person_id from unnest(submission.person_ids) person_id
    where person_id in ('ayg', 'zyl') on conflict do nothing;
  insert into public.event_people (event_id, person_id, role)
    select resolved_event_id, person_id, 'performer' from unnest(submission.person_ids) person_id
    where person_id in ('ayg', 'zyl') on conflict do nothing;
  insert into public.event_people (event_id, person_id, role)
    select resolved_event_id, site_id, 'performer' from unnest(submission.proposed_sites) site_id
    where site_id in ('ayg', 'zyl') on conflict do nothing;

  insert into public.event_media (event_id, media_id, sort_order)
    select resolved_event_id, sm.media_id, sm.sort_order
    from public.submission_media sm join public.media m on m.id = sm.media_id
    where sm.submission_id = submission.id and m.status = 'available'
    on conflict do nothing;
  insert into public.event_contributors (event_id, user_id, submission_id, contribution_type)
    values (resolved_event_id, submission.submitter_id, submission.id, submission.submission_kind)
    on conflict do nothing;

  update public.event_submissions set status = 'approved', reviewer_id = reviewer,
    review_note = p_review_note, approved_event_id = resolved_event_id,
    reviewed_at = now(), updated_at = now() where id = p_submission_id;
  return resolved_event_id;
end;
$$;

revoke all on function public.review_event_submission(uuid, text, text, uuid) from public;
grant execute on function public.review_event_submission(uuid, text, text, uuid) to authenticated;
