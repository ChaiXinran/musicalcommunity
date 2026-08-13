alter table public.site_settings drop constraint if exists site_settings_known_key;
alter table public.site_settings add constraint site_settings_known_key
  check (key in (
    'home_background',
    'duo_background','duo_promotion',
    'ayg_background','ayg_promotion',
    'zyl_background','zyl_promotion'
  ));

-- Preserve the current landing-page appearance once it becomes independently managed.
insert into public.site_settings (key, media_id, object_key, updated_by, updated_at)
select 'home_background', media_id, object_key, updated_by, updated_at
from public.site_settings
where key = 'duo_background'
on conflict (key) do nothing;
