begin;

select plan(16);

select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'sites', 'sites table exists');
select has_table('public', 'events', 'events table exists');
select has_table('public', 'comments', 'comments table exists');
select has_table('public', 'event_submissions', 'event_submissions table exists');
select has_table('public', 'media', 'media table exists');

insert into auth.users (id, email, raw_user_meta_data)
values
  ('10000000-0000-0000-0000-000000000001', 'one@example.com', '{"display_name":"One"}'::jsonb),
  ('10000000-0000-0000-0000-000000000002', 'two@example.com', '{"display_name":"Two"}'::jsonb),
  ('10000000-0000-0000-0000-000000000003', 'mod@example.com', '{"display_name":"Mod"}'::jsonb);

select is((select count(*)::integer from public.profiles where user_id in (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000003'
)), 3, 'auth trigger creates one profile per user');

insert into public.user_roles (user_id, role)
values ('10000000-0000-0000-0000-000000000003', 'moderator');

insert into public.sites (id, name, base_url)
values ('ayg', 'AYG', 'https://ayg.test')
on conflict (id) do nothing;

insert into public.events (id, title, category, start_time, status)
values ('20000000-0000-0000-0000-000000000001', 'Existing event', '音乐剧', now(), 'published');
insert into public.event_sites (event_id, site_id)
values ('20000000-0000-0000-0000-000000000001', 'ayg');

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';

select lives_ok(
  $$insert into public.comments (site_id, event_id, user_id, content)
    values ('ayg', '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001', 'root')$$,
  'an active user can create a comment'
);

select lives_ok(
  $$insert into public.comments (site_id, event_id, user_id, parent_id, content)
    values ('ayg', '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001',
      (select id from public.comments where content = 'root'), 'reply')$$,
  'one reply level is accepted'
);

select throws_ok(
  $$insert into public.comments (site_id, event_id, user_id, parent_id, content)
    values ('ayg', '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001',
      (select id from public.comments where content = 'reply'), 'third level')$$,
  '23514',
  'Only two comment levels are supported',
  'a third comment level is rejected'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
select results_eq(
  $$update public.comments set content = 'hacked' where content = 'root' returning id$$,
  $$select null::uuid where false$$,
  'a user cannot update another user comment'
);

select lives_ok(
  $$insert into public.event_submissions (
      submitter_id, proposed_sites, title, category, start_time, status
    ) values (
      '10000000-0000-0000-0000-000000000002', array['ayg'],
      'Draft', '音乐剧', now(), 'draft'
    )$$,
  'a user can save a draft submission'
);

select throws_ok(
  $$insert into public.event_submissions (
      submitter_id, proposed_sites, title, category, start_time, status
    ) values (
      '10000000-0000-0000-0000-000000000002', array['ayg'],
      'Bypass', '音乐剧', now(), 'pending'
    )$$,
  '42501',
  null,
  'a client cannot bypass Worker verification to create a pending submission'
);

reset role;
insert into public.event_submissions (
  id, submitter_id, proposed_sites, title, category, start_time, status
) values (
  '40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', array['ayg'],
  'Approved event', '音乐剧', now(), 'pending'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';
select ok(
  public.review_event_submission('40000000-0000-0000-0000-000000000003', 'approved') is not null,
  'a moderator can atomically approve a pending submission'
);

select is(
  (select count(*)::integer from public.event_submissions where id = '40000000-0000-0000-0000-000000000003' and status = 'approved'),
  1,
  'approval resolves the submission'
);

select is(
  (select count(*)::integer from public.event_sites es
    join public.event_submissions s on s.approved_event_id = es.event_id
    where s.id = '40000000-0000-0000-0000-000000000003' and es.site_id = 'ayg'),
  1,
  'approval publishes the event to every proposed site'
);

select * from finish();
rollback;
