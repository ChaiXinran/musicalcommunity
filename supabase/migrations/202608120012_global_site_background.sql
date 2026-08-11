create table if not exists public.site_settings (
  key text primary key,
  media_id uuid not null references public.media(id) on delete restrict,
  object_key text not null,
  updated_by uuid not null references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now(),
  constraint site_settings_known_key check (key in ('global_background'))
);

alter table public.site_settings enable row level security;

revoke all on table public.site_settings from anon, authenticated;
