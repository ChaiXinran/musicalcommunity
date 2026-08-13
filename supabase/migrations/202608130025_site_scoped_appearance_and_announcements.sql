alter table public.site_settings drop constraint if exists site_settings_known_key;
update public.site_settings set key = 'duo_background' where key = 'global_background';
update public.site_settings set key = 'duo_promotion' where key = 'global_promotion';
alter table public.site_settings add constraint site_settings_known_key
  check (key in ('duo_background','duo_promotion','ayg_background','ayg_promotion','zyl_background','zyl_promotion'));

alter table public.site_announcements add column if not exists site_ids text[] not null default array['duo']::text[];
alter table public.site_announcements add constraint site_announcements_site_ids_check
  check (cardinality(site_ids) between 1 and 3 and site_ids <@ array['duo','ayg','zyl']::text[]);
drop index if exists site_announcements_audience_published_idx;
create index site_announcements_sites_idx on public.site_announcements using gin (site_ids);

create or replace function public.assign_user_group(p_user_id uuid, p_group text)
returns text language plpgsql security definer set search_path = '' as $$
declare actor uuid := (select auth.uid()); existing_group text;
begin
  if private.management_level(actor) is distinct from 1 then raise exception 'Level 1 administrator required' using errcode = '42501'; end if;
  if p_user_id = actor then raise exception 'A level 1 administrator cannot change their own group' using errcode = '55000'; end if;
  if private.management_level(p_user_id) = 1 then raise exception 'Another level 1 administrator cannot be changed here' using errcode = '42501'; end if;
  if p_group not in ('yunv','cloud','star') then raise exception 'Invalid user group' using errcode = '22023'; end if;
  select user_group into existing_group from public.profiles where user_id = p_user_id for update;
  if not found then raise exception 'User profile not found' using errcode = 'P0002'; end if;
  update public.profiles set user_group = p_group,
    registration_site = case p_group when 'cloud' then 'ayg' when 'star' then 'zyl' else 'duo' end,
    updated_at = now() where user_id = p_user_id;
  delete from public.user_site_access where user_id = p_user_id;
  if p_group = 'yunv' then
    insert into public.user_site_access (user_id,site_id) values (p_user_id,'duo'),(p_user_id,'ayg'),(p_user_id,'zyl');
  elsif p_group = 'cloud' then insert into public.user_site_access (user_id,site_id) values (p_user_id,'ayg');
  else insert into public.user_site_access (user_id,site_id) values (p_user_id,'zyl'); end if;
  insert into public.admin_audit_log (actor_id,action,target_user_id,metadata)
    values (actor,'assign_user_group',p_user_id,jsonb_build_object('previous_group',existing_group,'new_group',p_group));
  return p_group;
end; $$;
revoke all on function public.assign_user_group(uuid,text) from public;
grant execute on function public.assign_user_group(uuid,text) to authenticated;
