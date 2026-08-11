import { Hono } from 'hono';
import { currentAccess, managementLevel, requireApprovedUser, requireLevel1, requireLevel2, requireLevel3, requireUser } from './auth';
import { ApiError, errorResponse } from './errors';
import { accountReviewSchema, announcementSchema, banAppealReviewSchema, banAppealSchema, managementLevelSchema, parseLimit, reportReviewSchema, reportSubmissionSchema, reviewQuestionDecisionSchema, reviewQuestionSchema, reviewSchema, siteBackgroundSchema, submissionSchema, uploadCompleteSchema, uploadSignSchema } from './schemas';
import { adminClient, publicClient, userClient } from './supabase';
import { verifyTurnstile } from './turnstile';
import type { AppEnv } from './types';
import { completeUpload, signUpload } from './uploads';

const app = new Hono<AppEnv>();

const publicMediaUrl = (env: AppEnv['Bindings'], objectKey?: string | null) =>
  objectKey ? `${env.MEDIA_PUBLIC_BASE_URL.replace(/\/$/, '')}/${objectKey}` : null;

async function enrichPublishedEvents(env: AppEnv['Bindings'], events: any[]) {
  const eventIds = events.map((event) => event?.id).filter(Boolean);
  if (!eventIds.length) return events;
  const admin = adminClient(env);
  const [{ data: mediaRows }, { data: contributorRows }] = await Promise.all([
    admin.from('event_media').select('event_id,sort_order,media:media(object_key,status,content_type)').in('event_id', eventIds).order('sort_order'),
    admin.from('event_contributors').select('event_id,user_id,contribution_type,created_at').in('event_id', eventIds).order('created_at'),
  ]);
  const contributorIds = [...new Set((contributorRows ?? []).map((row: any) => row.user_id))];
  const { data: profiles } = contributorIds.length
    ? await admin.from('profiles').select('user_id,display_name,avatar_key').in('user_id', contributorIds)
    : { data: [] };
  const profileMap = new Map((profiles ?? []).map((profile: any) => [profile.user_id, profile]));
  const mediaMap = new Map<string, string[]>();
  for (const row of mediaRows ?? []) {
    const media = Array.isArray((row as any).media) ? (row as any).media[0] : (row as any).media;
    if (!media || media.status !== 'available' || !String(media.content_type || '').startsWith('image/')) continue;
    const list = mediaMap.get((row as any).event_id) ?? [];
    const url = publicMediaUrl(env, media.object_key);
    if (url) list.push(url);
    mediaMap.set((row as any).event_id, list);
  }
  const contributorMap = new Map<string, any[]>();
  for (const row of contributorRows ?? []) {
    const profile: any = profileMap.get((row as any).user_id) ?? {};
    const list = contributorMap.get((row as any).event_id) ?? [];
    list.push({
      user_id: (row as any).user_id,
      display_name: profile.display_name || '社区用户',
      avatar_url: publicMediaUrl(env, profile.avatar_key),
      contribution_type: (row as any).contribution_type,
    });
    contributorMap.set((row as any).event_id, list);
  }
  return events.map((event) => ({
    ...event,
    images: mediaMap.get(event.id) ?? [],
    contributors: contributorMap.get(event.id) ?? [],
  }));
}

app.use('*', async (c, next) => {
  const origin = c.req.header('Origin');
  const allowed = c.env.ALLOWED_ORIGINS.split(',').map((value) => value.trim()).filter(Boolean);
  if (origin && allowed.includes(origin)) {
    c.header('Access-Control-Allow-Origin', origin);
    c.header('Vary', 'Origin');
    c.header('Access-Control-Allow-Credentials', 'true');
    c.header('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    c.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    c.header('Access-Control-Max-Age', '86400');
  }
  c.header('X-Content-Type-Options', 'nosniff');
  c.header('Referrer-Policy', 'no-referrer');
  c.header('Cache-Control', 'no-store');
  if (c.req.method === 'OPTIONS') {
    if (!origin || !allowed.includes(origin)) throw new ApiError(403, 'origin_not_allowed', '请求来源不在允许列表');
    return c.body(null, 204);
  }
  await next();
});

app.get('/health', (c) => c.json({ ok: true, service: 'musical-community-api', version: 'v1' }));

app.get('/v1/sites', async (c) => {
  const { data, error } = await publicClient(c.env).from('sites').select('id,name,base_url,metadata').order('id');
  if (error) throw new ApiError(502, 'database_error', '无法读取站点', error.message);
  c.header('Cache-Control', 'public, max-age=300');
  return c.json({ data });
});

app.get('/v1/site-settings/background', async (c) => {
  const { data, error } = await adminClient(c.env)
    .from('site_settings')
    .select('object_key,updated_at')
    .eq('key', 'global_background')
    .maybeSingle();
  if (error) throw new ApiError(502, 'database_error', '无法读取网站背景设置', error.message);
  c.header('Cache-Control', 'public, max-age=60, stale-while-revalidate=300');
  return c.json({ data: {
    background_url: data?.object_key ? `${c.env.MEDIA_PUBLIC_BASE_URL.replace(/\/$/, '')}/${data.object_key}` : null,
    updated_at: data?.updated_at ?? null,
  } });
});

app.get('/v1/events', async (c) => {
  const siteId = c.req.query('site_id');
  if (!siteId || !['ayg', 'zyl', 'duo'].includes(siteId)) throw new ApiError(422, 'invalid_site_id', 'site_id 必须是 ayg、zyl 或 duo');
  const limit = Math.min(Math.max(Number(c.req.query('limit') ?? 50) || 50, 1), 100);
  let query = publicClient(c.env)
    .from('event_sites')
    .select('site_id,event:events(id,slug,title,category,start_time,end_time,city,country,latitude,longitude,description,source_url,metadata,venue:venues(id,name,address),people:event_people(person_id,role),sites:event_sites(site_id))')
    .eq('site_id', siteId)
    .order('start_time', { referencedTable: 'events', ascending: false })
    .limit(limit);
  const before = c.req.query('before');
  if (before) query = query.lt('events.start_time', before);
  const { data, error } = await query;
  if (error) throw new ApiError(502, 'database_error', '无法读取活动', error.message);
  c.header('Cache-Control', 'public, max-age=60, stale-while-revalidate=300');
  const events = (data?.map((row) => row.event).filter(Boolean) ?? []) as any[];
  return c.json({ data: await enrichPublishedEvents(c.env, events) });
});

app.get('/v1/venues', async (c) => {
  const city = c.req.query('city')?.trim();
  let query = publicClient(c.env).from('venues')
    .select('id,name,city,country,latitude,longitude,address')
    .order('name').limit(250);
  if (city) query = query.eq('city', city);
  const { data, error } = await query;
  if (error) throw new ApiError(502, 'database_error', '无法读取场馆列表', error.message);
  c.header('Cache-Control', 'public, max-age=300');
  return c.json({ data: data ?? [] });
});

app.get('/v1/auth/review-question', async (c) => {
  const { data, error } = await publicClient(c.env).rpc('random_account_review_question');
  if (error) throw new ApiError(502, 'database_error', '无法读取注册审核问题', error.message);
  const question = data?.[0];
  if (!question) throw new ApiError(404, 'review_question_unavailable', '暂时没有可用的注册审核问题，请稍后再试');
  return c.json({ data: question });
});

app.get('/v1/me', requireUser, async (c) => {
  const access = await currentAccess(c);
  const level = managementLevel(access.roles);
  const { data: profile, error } = await userClient(c.env, c.get('accessToken'))
    .from('profiles')
    .select('user_id,display_name,avatar_key,bio,status,created_at')
    .eq('user_id', c.get('user').id)
    .single();
  if (error || !profile) throw new ApiError(502, 'database_error', '无法读取账号资料', error?.message);
  const admin = adminClient(c.env);
  const { data: application } = await admin
    .from('account_applications')
    .select('question_snapshot,answer,status,review_note,submitted_at,reviewed_at')
    .eq('user_id', c.get('user').id)
    .maybeSingle();
  const { data: bans } = await admin.from('user_bans')
    .select('id,report_id,reason,starts_at,ends_at,created_at')
    .eq('user_id', c.get('user').id)
    .is('revoked_at', null)
    .is('ends_at', null)
    .order('created_at', { ascending: false })
    .limit(1);
  const activeBan = bans?.[0] ?? null;
  const { data: appeals } = activeBan
    ? await admin.from('ban_appeals').select('id,ban_id,message,status,review_note,fandom,created_at,reviewed_at').eq('ban_id', activeBan.id).limit(1)
    : { data: [] };
  const { data: frozenReports } = await admin.from('reports')
    .select('id,comment_id,reason,status,created_at')
    .eq('subject_user_id', c.get('user').id)
    .in('status', ['open', 'reviewing'])
    .order('created_at', { ascending: false })
    .limit(1);
  return c.json({
    data: {
      user: { id: c.get('user').id, email: c.get('user').email ?? null },
      profile,
      roles: access.roles,
      management_level: level,
      application: application ?? null,
      moderation: { active_report: frozenReports?.[0] ?? null, active_ban: activeBan, appeal: appeals?.[0] ?? null },
      capabilities: {
        comment: access.status === 'active',
        submit: access.status === 'active',
        admin: access.status === 'active' && level !== null,
        review_submissions: access.status === 'active' && level !== null && level <= 3,
        handle_reports: access.status === 'active' && level !== null && level <= 3,
        review_accounts: access.status === 'active' && level !== null && level <= 2,
        submit_questions: access.status === 'active' && level !== null && level <= 2,
        review_questions: access.status === 'active' && level === 1,
        manage_roles: access.status === 'active' && level === 1,
        manage_site_background: access.status === 'active' && level === 1,
        manage_announcements: access.status === 'active' && level === 1,
      },
    },
  });
});

app.post('/v1/reports', requireApprovedUser, async (c) => {
  const parsed = reportSubmissionSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '举报参数格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('submit_report', {
    p_comment_id: parsed.data.comment_id ?? null,
    p_reported_user_id: parsed.data.reported_user_id ?? null,
    p_reason: parsed.data.reason,
    p_details: parsed.data.details,
  });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'report_submit_failed', '无法提交举报', error.message);
  return c.json({ data: { id: data.id, status: data.status, automatic_action: data.automatic_action } }, 201);
});

app.post('/v1/appeals', requireUser, async (c) => {
  const parsed = banAppealSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '申诉内容格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('submit_ban_appeal', { p_message: parsed.data.message });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'appeal_submit_failed', '无法提交申诉', error.message);
  return c.json({ data }, 201);
});

app.get('/v1/announcements', async (c) => {
  let audience: 'guest' | 'registered' | 'banned' = 'guest';
  const token = /^Bearer\s+(.+)$/i.exec(c.req.header('Authorization') || '')?.[1];
  if (token) {
    const { data } = await publicClient(c.env).auth.getUser(token);
    if (data.user) {
      const { data: activeBans } = await adminClient(c.env).from('user_bans')
        .select('id')
        .eq('user_id', data.user.id)
        .is('revoked_at', null)
        .is('ends_at', null)
        .limit(1);
      audience = activeBans?.length ? 'banned' : 'registered';
    }
  }
  const limit = parseLimit(c.req.query('limit'), 50, 100);
  const { data, error } = await adminClient(c.env).from('site_announcements')
    .select('id,title,message,audience,published_at,updated_at')
    .in('audience', ['all', audience])
    .order('published_at', { ascending: false })
    .limit(limit);
  if (error) throw new ApiError(502, 'database_error', '无法读取站内通知', error.message);
  c.header('Cache-Control', 'private, max-age=30');
  return c.json({ data: { items: data ?? [], audience } });
});

app.get('/v1/notifications', requireUser, async (c) => {
  const limit = parseLimit(c.req.query('limit'), 50, 100);
  const userId = c.get('user').id;
  const client = userClient(c.env, c.get('accessToken'));
  const [{ data: items, error: listError }, { count: unreadCount, error: countError }] = await Promise.all([
    client
      .from('notifications')
      .select('id,category,title,message,target_url,metadata,read_at,created_at')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(limit),
    client
      .from('notifications')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId)
      .is('read_at', null),
  ]);
  if (listError || countError) {
    throw new ApiError(502, 'database_error', '无法读取通知', listError?.message ?? countError?.message);
  }
  return c.json({ data: { items: items ?? [], unread_count: unreadCount ?? 0 } });
});

app.post('/v1/notifications/:id/read', requireUser, async (c) => {
  const userId = c.get('user').id;
  const { data, error } = await userClient(c.env, c.get('accessToken'))
    .from('notifications')
    .update({ read_at: new Date().toISOString() })
    .eq('id', c.req.param('id'))
    .eq('user_id', userId)
    .select('id,read_at')
    .maybeSingle();
  if (error) throw new ApiError(502, 'database_error', '无法更新通知', error.message);
  if (!data) throw new ApiError(404, 'notification_not_found', '通知不存在');
  return c.json({ data });
});

app.post('/v1/notifications/read-all', requireUser, async (c) => {
  const userId = c.get('user').id;
  const { data, error } = await userClient(c.env, c.get('accessToken'))
    .from('notifications')
    .update({ read_at: new Date().toISOString() })
    .eq('user_id', userId)
    .is('read_at', null)
    .select('id');
  if (error) throw new ApiError(502, 'database_error', '无法更新通知', error.message);
  return c.json({ data: { updated: data?.length ?? 0 } });
});

app.post('/v1/submissions', requireApprovedUser, async (c) => {
  const parsed = submissionSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '投稿内容不完整或格式错误', parsed.error.flatten());
  const user = c.get('user');
  const rate = await c.env.SUBMISSION_RATE_LIMITER.limit({ key: user.id });
  if (!rate.success) throw new ApiError(429, 'rate_limited', '投稿过于频繁，请稍后再试');
  await verifyTurnstile(c.env, parsed.data.turnstile_token, c.req.header('CF-Connecting-IP'));

  const { turnstile_token: _token, ...input } = parsed.data;
  const admin = adminClient(c.env);
  let beforeSnapshot: Record<string, unknown> | null = null;
  if (input.submission_kind === 'edit' && input.target_event_id) {
    const { data: target, error: targetError } = await admin.from('events')
      .select('id,title,category,start_time,end_time,city,country,latitude,longitude,description,source_url,metadata,venue:venues(id,name,address),people:event_people(person_id,role),sites:event_sites(site_id)')
      .eq('id', input.target_event_id).neq('status', 'archived').maybeSingle();
    if (targetError || !target) throw new ApiError(404, 'target_event_not_found', '要编辑的公开活动不存在');
    beforeSnapshot = target as unknown as Record<string, unknown>;
  }
  const personIds = [...new Set(input.person_ids)];
  const proposedSites = input.submission_scope === 'public'
    ? ['duo', ...personIds.filter((id) => ['ayg', 'zyl'].includes(id))]
    : ['duo'];
  const submission = { ...input, person_ids: personIds, proposed_sites: proposedSites, before_snapshot: beforeSnapshot };
  const { data, error } = await admin
    .from('event_submissions')
    .insert({ ...submission, submitter_id: user.id, status: input.submission_scope === 'private' ? 'draft' : 'pending' })
    .select('id,status,created_at')
    .single();
  if (error) throw new ApiError(422, 'submission_failed', '投稿保存失败', error.message);
  if (input.submission_scope === 'private') {
    const { data: privateEvent, error: privateError } = await admin.from('private_events').insert({
      owner_id: user.id, submission_id: data.id, title: input.title, category: input.category,
      start_time: input.start_time, end_time: input.end_time ?? null, venue: input.venue ?? null,
      city: input.city ?? null, country: input.country ?? null, latitude: input.latitude ?? null,
      longitude: input.longitude ?? null, description: input.description, media_links: input.media_links,
    }).select('id').single();
    if (privateError) {
      await admin.from('event_submissions').delete().eq('id', data.id);
      throw new ApiError(422, 'private_event_failed', '私人活动保存失败', privateError.message);
    }
    return c.json({ data: { ...data, private_event_id: privateEvent.id, visibility: 'private' } }, 201);
  }
  return c.json({ data: { ...data, visibility: 'public' } }, 201);
});

app.get('/v1/private-events', requireApprovedUser, async (c) => {
  const userId = c.get('user').id;
  const admin = adminClient(c.env);
  const { data: events, error } = await admin.from('private_events')
    .select('id,submission_id,title,category,start_time,end_time,venue,city,country,latitude,longitude,description,media_links,created_at')
    .eq('owner_id', userId).order('start_time', { ascending: false });
  if (error) throw new ApiError(502, 'database_error', '无法读取私人活动', error.message);
  const submissionIds = (events ?? []).map((event) => event.submission_id);
  const { data: mediaRows } = submissionIds.length
    ? await admin.from('submission_media').select('submission_id,sort_order,media:media(object_key,status,content_type)').in('submission_id', submissionIds).order('sort_order')
    : { data: [] };
  const mediaMap = new Map<string, string[]>();
  for (const row of mediaRows ?? []) {
    const media = Array.isArray((row as any).media) ? (row as any).media[0] : (row as any).media;
    if (!media || media.status !== 'available' || !String(media.content_type || '').startsWith('image/')) continue;
    const list = mediaMap.get((row as any).submission_id) ?? [];
    const url = publicMediaUrl(c.env, media.object_key);
    if (url) list.push(url);
    mediaMap.set((row as any).submission_id, list);
  }
  return c.json({ data: (events ?? []).map((event) => ({ ...event, images: mediaMap.get(event.submission_id) ?? [] })) });
});

app.get('/v1/admin/applications', requireLevel2, async (c) => {
  const limit = parseLimit(c.req.query('limit'), 50, 100);
  const { data: applications, error } = await adminClient(c.env)
    .from('account_applications')
    .select('user_id,question_snapshot,answer,status,submitted_at')
    .eq('status', 'pending')
    .order('submitted_at', { ascending: true })
    .limit(limit);
  if (error) throw new ApiError(502, 'database_error', '无法读取账号申请', error.message);
  const userIds = (applications ?? []).map((item) => item.user_id);
  const { data: profiles } = userIds.length
    ? await adminClient(c.env).from('profiles').select('user_id,display_name,created_at').in('user_id', userIds)
    : { data: [] };
  const profileMap = new Map((profiles ?? []).map((profile) => [profile.user_id, profile]));
  const rows = await Promise.all((applications ?? []).map(async (application) => {
    const { data } = await adminClient(c.env).auth.admin.getUserById(application.user_id);
    return { ...application, ...profileMap.get(application.user_id), email: data.user?.email ?? null };
  }));
  return c.json({ data: rows });
});

app.post('/v1/admin/applications/:id/review', requireLevel2, async (c) => {
  const parsed = accountReviewSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '账号审核参数格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('review_account_application', {
    p_user_id: c.req.param('id'),
    p_decision: parsed.data.decision,
    p_review_note: parsed.data.review_note ?? null,
  });
  if (error) {
    const forbidden = error.code === '42501';
    throw new ApiError(forbidden ? 403 : 409, forbidden ? 'admin_required' : 'review_failed', forbidden ? '需要管理员权限' : '无法审核该账号申请', error.message);
  }
  return c.json({ data: { user_id: c.req.param('id'), status: data } });
});

app.get('/v1/admin/submissions', requireLevel3, async (c) => {
  const limit = parseLimit(c.req.query('limit'), 50, 100);
  const { data: submissions, error } = await adminClient(c.env)
    .from('event_submissions')
    .select('id,submitter_id,submission_scope,submission_kind,target_event_id,person_ids,proposed_sites,title,category,start_time,end_time,venue,city,country,latitude,longitude,description,source_url,media_links,before_snapshot,status,created_at,media:submission_media(sort_order,asset:media(object_key,status,content_type))')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .limit(limit);
  if (error) throw new ApiError(502, 'database_error', '无法读取投稿申请', error.message);
  const submitterIds = [...new Set((submissions ?? []).map((item) => item.submitter_id))];
  const { data: profiles, error: profilesError } = submitterIds.length
    ? await adminClient(c.env).from('profiles').select('user_id,display_name').in('user_id', submitterIds)
    : { data: [], error: null };
  if (profilesError) throw new ApiError(502, 'database_error', '无法读取投稿人资料', profilesError.message);
  const names = new Map((profiles ?? []).map((profile) => [profile.user_id, profile.display_name]));
  return c.json({ data: (submissions ?? []).map((item: any) => ({
    ...item,
    submitter_name: names.get(item.submitter_id) ?? '社区用户',
    images: (item.media ?? []).map((entry: any) => Array.isArray(entry.asset) ? entry.asset[0] : entry.asset)
      .filter((asset: any) => asset?.status === 'available' && String(asset.content_type || '').startsWith('image/'))
      .map((asset: any) => publicMediaUrl(c.env, asset.object_key)),
  })) });
});

app.post('/v1/admin/submissions/:id/review', requireLevel3, async (c) => {
  const parsed = reviewSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '审核参数格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('review_event_submission', {
    p_submission_id: c.req.param('id'),
    p_decision: parsed.data.decision,
    p_review_note: parsed.data.review_note ?? null,
    p_target_event_id: parsed.data.target_event_id ?? null,
  });
  if (error) {
    const forbidden = error.code === '42501';
    throw new ApiError(forbidden ? 403 : 409, forbidden ? 'moderator_required' : 'review_failed', forbidden ? '需要审核员权限' : '无法审核该投稿', error.message);
  }
  return c.json({ data: { event_id: data, decision: parsed.data.decision } });
});

app.get('/v1/admin/reports', requireLevel3, async (c) => {
  const limit = parseLimit(c.req.query('limit'), 50, 100);
  const { data: reports, error } = await adminClient(c.env)
    .from('reports')
    .select('id,reporter_id,comment_id,reported_user_id,subject_user_id,reason,details,status,automatic_action,created_at,comment:comments(id,content,user_id,site_id,event_id)')
    .in('status', ['open', 'reviewing'])
    .order('created_at', { ascending: true })
    .limit(limit);
  if (error) throw new ApiError(502, 'database_error', '无法读取举报列表', error.message);
  const userIds = [...new Set((reports ?? []).flatMap((item) => [item.reporter_id, item.subject_user_id].filter(Boolean)))] as string[];
  const { data: profiles } = userIds.length
    ? await adminClient(c.env).from('profiles').select('user_id,display_name').in('user_id', userIds)
    : { data: [] };
  const names = new Map((profiles ?? []).map((profile) => [profile.user_id, profile.display_name]));
  return c.json({ data: (reports ?? []).map((item) => ({
    ...item,
    reporter_name: names.get(item.reporter_id) ?? '社区用户',
    reported_user_name: names.get(item.subject_user_id) ?? '社区用户',
  })) });
});

app.post('/v1/admin/reports/:id/review', requireLevel3, async (c) => {
  const parsed = reportReviewSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '举报处理参数格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('review_report', {
    p_report_id: c.req.param('id'),
    p_decision: parsed.data.decision,
    p_review_note: parsed.data.review_note ?? null,
  });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'report_review_failed', '无法处理该举报', error.message);
  return c.json({ data: { id: c.req.param('id'), status: data } });
});

app.get('/v1/admin/appeals', requireLevel3, async (c) => {
  const limit = parseLimit(c.req.query('limit'), 50, 100);
  const admin = adminClient(c.env);
  const { data: appeals, error } = await admin.from('ban_appeals')
    .select('id,ban_id,user_id,message,status,created_at,ban:user_bans(id,reason,report_id,created_at)')
    .eq('status', 'pending')
    .order('created_at', { ascending: true })
    .limit(limit);
  if (error) throw new ApiError(502, 'database_error', '无法读取封禁申诉', error.message);
  const userIds = [...new Set((appeals ?? []).map((item) => item.user_id))] as string[];
  const [{ data: profiles }, { data: authUsers }] = await Promise.all([
    userIds.length ? admin.from('profiles').select('user_id,display_name').in('user_id', userIds) : Promise.resolve({ data: [] }),
    Promise.all(userIds.map((id) => admin.auth.admin.getUserById(id))).then((items) => ({ data: items.map((item) => item.data.user) })),
  ]);
  const names = new Map((profiles ?? []).map((profile) => [profile.user_id, profile.display_name]));
  const emails = new Map((authUsers ?? []).map((user) => [user?.id, user?.email ?? null]));
  return c.json({ data: (appeals ?? []).map((item) => ({ ...item, display_name: names.get(item.user_id) ?? '社区用户', email: emails.get(item.user_id) ?? null })) });
});

app.post('/v1/admin/appeals/:id/review', requireLevel3, async (c) => {
  const parsed = banAppealReviewSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '申诉审核参数格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('review_ban_appeal', {
    p_appeal_id: c.req.param('id'),
    p_decision: parsed.data.decision,
    p_review_note: parsed.data.review_note ?? null,
    p_fandom: parsed.data.fandom ?? null,
  });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'appeal_review_failed', '无法审核该申诉', error.message);
  return c.json({ data });
});

app.get('/v1/admin/questions', requireLevel2, async (c) => {
  const { data, error } = await adminClient(c.env)
    .from('account_review_questions')
    .select('id,prompt,status,is_active,proposed_by,reviewed_by,review_note,created_at,reviewed_at')
    .order('created_at', { ascending: false })
    .limit(200);
  if (error) throw new ApiError(502, 'database_error', '无法读取审核问题库', error.message);
  return c.json({ data });
});

app.post('/v1/admin/questions', requireLevel2, async (c) => {
  const parsed = reviewQuestionSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '审核问题格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('submit_account_review_question', { p_prompt: parsed.data.prompt });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'question_submit_failed', '无法提交审核问题', error.message);
  return c.json({ data }, 201);
});

app.post('/v1/admin/questions/:id/review', requireLevel1, async (c) => {
  const parsed = reviewQuestionDecisionSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '问题审核参数格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('review_account_review_question', {
    p_question_id: c.req.param('id'),
    p_decision: parsed.data.decision,
    p_review_note: parsed.data.review_note ?? null,
  });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'question_review_failed', '无法审核该问题', error.message);
  return c.json({ data: { id: c.req.param('id'), status: data } });
});

app.post('/v1/admin/questions/:id/edit', requireLevel1, async (c) => {
  const parsed = reviewQuestionSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '审核问题格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('update_account_review_question', {
    p_question_id: c.req.param('id'),
    p_prompt: parsed.data.prompt,
  });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'question_update_failed', '无法编辑该问题', error.message);
  return c.json({ data });
});

app.post('/v1/admin/questions/:id/delete', requireLevel1, async (c) => {
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('delete_account_review_question', {
    p_question_id: c.req.param('id'),
  });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'question_delete_failed', '无法删除该问题', error.message);
  return c.json({ data: { id: c.req.param('id'), deleted: data } });
});

app.get('/v1/admin/users', requireLevel1, async (c) => {
  const authUsers = [];
  for (let page = 1; page <= 10; page += 1) {
    const { data, error } = await adminClient(c.env).auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new ApiError(502, 'auth_admin_error', '无法读取账号列表', error.message);
    authUsers.push(...data.users);
    if (data.users.length < 1000) break;
  }
  const userIds = authUsers.map((user) => user.id);
  const [{ data: profiles, error: profileError }, { data: roleRows, error: roleError }] = await Promise.all([
    userIds.length ? adminClient(c.env).from('profiles').select('user_id,display_name,status,created_at').in('user_id', userIds) : Promise.resolve({ data: [], error: null }),
    userIds.length ? adminClient(c.env).from('user_roles').select('user_id,role').in('user_id', userIds) : Promise.resolve({ data: [], error: null }),
  ]);
  if (profileError || roleError) throw new ApiError(502, 'database_error', '无法读取账号权限资料', profileError?.message ?? roleError?.message);
  const profileMap = new Map((profiles ?? []).map((profile) => [profile.user_id, profile]));
  const rolesByUser = new Map<string, string[]>();
  for (const row of roleRows ?? []) rolesByUser.set(row.user_id, [...(rolesByUser.get(row.user_id) ?? []), row.role]);
  return c.json({ data: authUsers.map((user) => {
    const roles = rolesByUser.get(user.id) ?? ['user'];
    return { id: user.id, email: user.email ?? null, email_confirmed_at: user.email_confirmed_at, ...profileMap.get(user.id), roles, management_level: managementLevel(roles as Array<'user' | 'editor' | 'moderator' | 'admin'>) };
  }) });
});

app.post('/v1/admin/users/:id/management-level', requireLevel1, async (c) => {
  const parsed = managementLevelSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '管理员级别参数格式错误', parsed.error.flatten());
  const { data, error } = await userClient(c.env, c.get('accessToken')).rpc('assign_management_level', {
    p_user_id: c.req.param('id'),
    p_level: parsed.data.level,
  });
  if (error) throw new ApiError(error.code === '42501' ? 403 : 409, 'role_assignment_failed', '无法修改管理员级别', error.message);
  return c.json({ data: { user_id: c.req.param('id'), management_level: data } });
});

app.post('/v1/admin/site-background', requireLevel1, async (c) => {
  const parsed = siteBackgroundSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '网站背景参数格式错误', parsed.error.flatten());
  const admin = adminClient(c.env);
  const { data: media, error: mediaError } = await admin.from('media')
    .select('id,object_key,purpose,status')
    .eq('id', parsed.data.media_id)
    .eq('owner_id', c.get('user').id)
    .maybeSingle();
  if (mediaError || !media || media.purpose !== 'site_background' || media.status !== 'available') {
    throw new ApiError(409, 'background_media_unavailable', '背景图片尚未完成上传或不可使用', mediaError?.message);
  }
  const updatedAt = new Date().toISOString();
  const { error } = await admin.from('site_settings').upsert({
    key: 'global_background',
    media_id: media.id,
    object_key: media.object_key,
    updated_by: c.get('user').id,
    updated_at: updatedAt,
  }, { onConflict: 'key' });
  if (error) throw new ApiError(502, 'database_error', '无法保存网站背景设置', error.message);
  return c.json({ data: {
    media_id: media.id,
    object_key: media.object_key,
    background_url: `${c.env.MEDIA_PUBLIC_BASE_URL.replace(/\/$/, '')}/${media.object_key}`,
    updated_at: updatedAt,
  } });
});

app.get('/v1/admin/announcements', requireLevel1, async (c) => {
  const limit = parseLimit(c.req.query('limit'), 100, 100);
  const { data, error } = await adminClient(c.env).from('site_announcements')
    .select('id,title,message,audience,published_at,created_at,updated_at')
    .order('published_at', { ascending: false })
    .limit(limit);
  if (error) throw new ApiError(502, 'database_error', '无法读取已发布通知', error.message);
  return c.json({ data: data ?? [] });
});

app.post('/v1/admin/announcements', requireLevel1, async (c) => {
  const parsed = announcementSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '通知内容格式错误', parsed.error.flatten());
  const userId = c.get('user').id;
  const { data, error } = await adminClient(c.env).from('site_announcements')
    .insert({ ...parsed.data, created_by: userId, updated_by: userId })
    .select('id,title,message,audience,published_at,created_at,updated_at')
    .single();
  if (error) throw new ApiError(502, 'database_error', '无法发布通知', error.message);
  return c.json({ data }, 201);
});

app.post('/v1/admin/announcements/:id/edit', requireLevel1, async (c) => {
  const parsed = announcementSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '通知内容格式错误', parsed.error.flatten());
  const { data, error } = await adminClient(c.env).from('site_announcements')
    .update({ ...parsed.data, updated_by: c.get('user').id })
    .eq('id', c.req.param('id'))
    .select('id,title,message,audience,published_at,created_at,updated_at')
    .maybeSingle();
  if (error) throw new ApiError(502, 'database_error', '无法修改通知', error.message);
  if (!data) throw new ApiError(404, 'announcement_not_found', '通知不存在');
  return c.json({ data });
});

app.post('/v1/admin/announcements/:id/delete', requireLevel1, async (c) => {
  const { data, error } = await adminClient(c.env).from('site_announcements')
    .delete()
    .eq('id', c.req.param('id'))
    .select('id')
    .maybeSingle();
  if (error) throw new ApiError(502, 'database_error', '无法删除通知', error.message);
  if (!data) throw new ApiError(404, 'announcement_not_found', '通知不存在');
  return c.json({ data });
});

app.post('/v1/uploads/sign', requireUser, async (c) => {
  const parsed = uploadSignSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '上传参数格式错误', parsed.error.flatten());
  if (parsed.data.purpose === 'site_background') {
    const access = await currentAccess(c);
    if (access.status !== 'active' || managementLevel(access.roles) !== 1) {
      throw new ApiError(403, 'level_1_required', '只有一级管理员可以上传网站背景');
    }
  }
  const user = c.get('user');
  const rate = await c.env.UPLOAD_RATE_LIMITER.limit({ key: user.id });
  if (!rate.success) throw new ApiError(429, 'rate_limited', '上传请求过于频繁，请稍后再试');
  return c.json({ data: await signUpload(c.env, c.get('accessToken'), user.id, parsed.data) }, 201);
});

app.post('/v1/uploads/complete', requireUser, async (c) => {
  const parsed = uploadCompleteSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '媒体 ID 格式错误', parsed.error.flatten());
  return c.json({ data: await completeUpload(c.env, c.get('user').id, parsed.data.media_id) });
});

app.notFound((c) => c.json({ error: { code: 'not_found', message: '接口不存在' } }, 404));
app.onError((error, c) => errorResponse(c, error));

export default app;
