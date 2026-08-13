alter type public.media_purpose add value if not exists 'announcement_image';

alter table public.site_announcements
  add column if not exists image_media_id uuid references public.media(id) on delete set null;
