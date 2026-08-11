create table public.site_announcements (
  id uuid primary key default extensions.gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 200),
  message text not null check (char_length(btrim(message)) between 1 and 10000),
  audience text not null check (audience in ('guest', 'registered', 'banned', 'all')),
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index site_announcements_audience_published_idx
  on public.site_announcements (audience, published_at desc);

create trigger site_announcements_set_updated_at
before update on public.site_announcements
for each row execute function private.set_updated_at();

alter table public.site_announcements enable row level security;
revoke all on table public.site_announcements from anon, authenticated;
