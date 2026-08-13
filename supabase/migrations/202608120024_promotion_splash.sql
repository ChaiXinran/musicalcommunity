alter type public.media_purpose add value if not exists 'promotion_image';

alter table public.site_settings drop constraint if exists site_settings_known_key;
alter table public.site_settings add constraint site_settings_known_key
  check (key in ('global_background', 'global_promotion'));
