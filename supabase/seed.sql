insert into public.sites (id, name, base_url, status)
values
  ('ayg', '阿云嘎个人站', 'https://aygmusical.ranyechai.site', 'active'),
  ('zyl', '郑云龙个人站', 'https://zyldl.ranyechai.site', 'active'),
  ('duo', '双人站', 'https://musical.ranyechai.site', 'active')
on conflict (id) do update
set name = excluded.name,
    base_url = excluded.base_url,
    status = excluded.status;

insert into public.persons (id, display_name, metadata)
values
  ('ayg', '阿云嘎', '{"site_id":"ayg"}'::jsonb),
  ('zyl', '郑云龙', '{"site_id":"zyl"}'::jsonb)
on conflict (id) do update
set display_name = excluded.display_name,
    metadata = excluded.metadata;

