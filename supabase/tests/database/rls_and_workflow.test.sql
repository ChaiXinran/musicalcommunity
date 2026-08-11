begin;

select plan(52);

select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'sites', 'sites table exists');
select has_table('public', 'events', 'events table exists');
select has_table('public', 'comments', 'comments table exists');
select has_table('public', 'event_submissions', 'event_submissions table exists');
select has_table('public', 'media', 'media table exists');
select has_table('public', 'account_review_questions', 'account review questions table exists');
select has_table('public', 'account_applications', 'account applications table exists');
select has_table('public', 'notifications', 'notifications table exists');

insert into public.account_review_questions (id, prompt, status)
values (
  '50000000-0000-0000-0000-000000000001',
  'Please explain why you want to join this community and how you will contribute.',
  'approved'
);

insert into auth.users (id, email, raw_user_meta_data)
values
  ('10000000-0000-0000-0000-000000000001', 'one@example.com', '{"display_name":"One"}'::jsonb),
  ('10000000-0000-0000-0000-000000000002', 'two@example.com', '{"display_name":"Two"}'::jsonb),
  ('10000000-0000-0000-0000-000000000003', 'mod@example.com', '{"display_name":"Mod"}'::jsonb),
  ('10000000-0000-0000-0000-000000000004', 'applicant@example.com', jsonb_build_object(
    'display_name', 'Applicant',
    'review_question_id', '50000000-0000-0000-0000-000000000001',
    'review_answer', repeat('A', 200)
  )),
  ('10000000-0000-0000-0000-000000000005', 'level2@example.com', '{"display_name":"Level 2"}'::jsonb),
  ('10000000-0000-0000-0000-000000000006', 'level3@example.com', '{"display_name":"Level 3"}'::jsonb),
  ('10000000-0000-0000-0000-000000000007', 'applicant2@example.com', jsonb_build_object(
    'display_name', 'Applicant 2',
    'review_question_id', '50000000-0000-0000-0000-000000000001',
    'review_answer', repeat('B', 200)
  ));

select is((select count(*)::integer from public.profiles where user_id in (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-000000000004',
  '10000000-0000-0000-0000-000000000005',
  '10000000-0000-0000-0000-000000000006',
  '10000000-0000-0000-0000-000000000007'
  )), 7, 'auth trigger creates one profile per user');

select is(
  (select status::text from public.profiles where user_id = '10000000-0000-0000-0000-000000000004'),
  'pending',
  'new accounts start in the pending review state'
);

select is(
  (select char_length(answer)::integer from public.account_applications where user_id = '10000000-0000-0000-0000-000000000004'),
  200,
  'signup metadata creates an application with a 200 character answer'
);

update public.profiles set status = 'active'
where user_id in (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000005',
    '10000000-0000-0000-0000-000000000006'
);

insert into public.user_roles (user_id, role)
values
  ('10000000-0000-0000-0000-000000000003', 'moderator'),
  ('10000000-0000-0000-0000-000000000003', 'admin'),
  ('10000000-0000-0000-0000-000000000005', 'editor'),
  ('10000000-0000-0000-0000-000000000006', 'moderator');

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000006';
select throws_ok(
  $$select public.review_account_application('10000000-0000-0000-0000-000000000007', 'approved')$$,
  '42501',
  'Level 1 or level 2 administrator required',
  'a level 3 administrator cannot review accounts'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000005';
select is(
  public.review_account_application('10000000-0000-0000-0000-000000000007', 'approved')::text,
  'active',
  'a level 2 administrator can review accounts'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000007';
select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000007' and title = '账号审核已通过'),
  1,
  'account review automatically notifies the applicant'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000005';

select is(
  (public.submit_account_review_question('How will you help keep community discussions respectful and useful?')).status::text,
  'pending',
  'a level 2 administrator question requires level 1 approval'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';
select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000003' and title = '新的审核问题'),
  1,
  'a pending review question automatically notifies level 1 administrators'
);

select is(
  public.review_account_review_question(
    (select id from public.account_review_questions where proposed_by = '10000000-0000-0000-0000-000000000005' order by created_at desc limit 1),
    'approved'
  )::text,
  'approved',
  'a level 1 administrator can approve a proposed question'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000005';
select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000005' and title = '审核问题已通过'),
  1,
  'question review automatically notifies its proposer'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';

select is(
  (public.update_account_review_question(
    (select id from public.account_review_questions where proposed_by = '10000000-0000-0000-0000-000000000005' order by created_at desc limit 1),
    'How will you keep community discussions respectful, accurate, and useful?'
  )).prompt,
  'How will you keep community discussions respectful, accurate, and useful?',
  'a level 1 administrator can edit an approved question'
);

select ok(
  public.delete_account_review_question(
    (select id from public.account_review_questions where proposed_by = '10000000-0000-0000-0000-000000000005' order by created_at desc limit 1)
  ),
  'a level 1 administrator can soft-delete an approved question'
);

reset role;

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

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
select public.submit_report(
  (select id from public.comments where content = 'root'),
  null,
  'test report',
  ''
);

reset role;

select is(
  (select status::text from public.profiles where user_id = '10000000-0000-0000-0000-000000000001'),
  'pending',
  'an ordinary report immediately freezes the reported account'
);

select is(
  (select status::text from public.comments where content = 'root'),
  'hidden',
  'an ordinary comment report immediately hides the reported comment'
);

set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';

select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000002' and title = '举报已提交'),
  1,
  'a new report automatically notifies its reporter'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000006';
select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000006' and title = '新的举报'),
  1,
  'a new report automatically notifies administrators'
);

select is(
  public.review_report(
    (select id from public.reports where reporter_id = '10000000-0000-0000-0000-000000000002' and reason = 'test report'),
    'dismissed'
  )::text,
  'dismissed',
  'a level 3 administrator can dismiss a report'
);

select is(
  (select status::text from public.profiles where user_id = '10000000-0000-0000-0000-000000000001'),
  'active',
  'dismissing a report restores the reported account'
);

select is(
  (select status::text from public.comments where content = 'root'),
  'published',
  'dismissing a report restores the hidden comment'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000002' and title = '举报已关闭'),
  1,
  'report dismissal automatically notifies its reporter'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000004';
select throws_ok(
  $$insert into public.comments (site_id, event_id, user_id, content)
    values ('ayg', '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000004', 'pending user comment')$$,
  '42501',
  null,
  'a pending account cannot create a comment'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000003';
select is(
  public.review_account_application('10000000-0000-0000-0000-000000000004', 'approved')::text,
  'active',
  'an admin can approve an account application'
);

select is(
  (select status::text from public.profiles where user_id = '10000000-0000-0000-0000-000000000004'),
  'active',
  'account approval unlocks the profile'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000004';
select lives_ok(
  $$insert into public.comments (site_id, event_id, user_id, content)
    values ('ayg', '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000004', 'approved user comment')$$,
  'an approved account can create a comment'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';

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
set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000001' and title = '投稿已提交'),
  1,
  'a pending submission automatically notifies its submitter'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000006';
select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000006' and title = '新的活动投稿'),
  1,
  'a pending submission automatically notifies administrators'
);

select ok(
  public.review_event_submission('40000000-0000-0000-0000-000000000003', 'approved') is not null,
  'a moderator can atomically approve a pending submission'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
select is(
  (select count(*)::integer from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000001' and title = '投稿审核已通过'),
  1,
  'submission review automatically notifies its submitter'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000006';

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

select is(
  (public.submit_report(
    (select id from public.comments where content = 'approved user comment'),
    null,
    'administrator direct report',
    ''
  )).status::text,
  'resolved',
  'an administrator report is resolved immediately without another review'
);

select is(
  (select status::text from public.profiles where user_id = '10000000-0000-0000-0000-000000000004'),
  'suspended',
  'an administrator report immediately suspends the target account'
);

select is(
  (select status::text from public.comments where user_id = '10000000-0000-0000-0000-000000000004'),
  'deleted',
  'an administrator report permanently deletes the target comment'
);

select is(
  (select count(*)::integer from public.user_bans where user_id = '10000000-0000-0000-0000-000000000004' and revoked_at is null and ends_at is null),
  1,
  'an administrator report creates a permanent application-level email ban'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000004';
select is(
  (public.submit_ban_appeal('I believe the permanent ban was mistaken and request a complete review.')).status::text,
  'pending',
  'a permanently banned user can submit one appeal'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000006';
select is(
  (public.review_ban_appeal(
    (select id from public.ban_appeals where user_id = '10000000-0000-0000-0000-000000000004'),
    'rejected',
    'The original decision remains in effect.',
    'ayanga'
  )).status::text,
  'rejected',
  'an administrator can reject an appeal with a required fandom label'
);

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000004';
select is(
  (select metadata->>'result_image' from public.notifications
    where user_id = '10000000-0000-0000-0000-000000000004' and title = '申诉被拒绝'
    order by created_at desc limit 1),
  '/assets/moderation/appeal-ayanga.jpg',
  'a rejected appeal notification includes the selected result image'
);

select * from finish();
rollback;
