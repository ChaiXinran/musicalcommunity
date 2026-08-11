import { Hono } from 'hono';
import { requireUser } from './auth';
import { ApiError, errorResponse } from './errors';
import { reviewSchema, submissionSchema, uploadCompleteSchema, uploadSignSchema } from './schemas';
import { adminClient, publicClient, userClient } from './supabase';
import { verifyTurnstile } from './turnstile';
import type { AppEnv } from './types';
import { completeUpload, signUpload } from './uploads';

const app = new Hono<AppEnv>();

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

app.get('/v1/events', async (c) => {
  const siteId = c.req.query('site_id');
  if (!siteId || !['ayg', 'zyl', 'duo'].includes(siteId)) throw new ApiError(422, 'invalid_site_id', 'site_id 必须是 ayg、zyl 或 duo');
  const limit = Math.min(Math.max(Number(c.req.query('limit') ?? 50) || 50, 1), 100);
  let query = publicClient(c.env)
    .from('event_sites')
    .select('site_id,event:events(id,slug,title,category,start_time,end_time,city,country,latitude,longitude,description,source_url,venue:venues(id,name,address))')
    .eq('site_id', siteId)
    .order('start_time', { referencedTable: 'events', ascending: false })
    .limit(limit);
  const before = c.req.query('before');
  if (before) query = query.lt('events.start_time', before);
  const { data, error } = await query;
  if (error) throw new ApiError(502, 'database_error', '无法读取活动', error.message);
  c.header('Cache-Control', 'public, max-age=60, stale-while-revalidate=300');
  return c.json({ data: data?.map((row) => row.event) ?? [] });
});

app.post('/v1/submissions', requireUser, async (c) => {
  const parsed = submissionSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '投稿内容不完整或格式错误', parsed.error.flatten());
  const user = c.get('user');
  const rate = await c.env.SUBMISSION_RATE_LIMITER.limit({ key: user.id });
  if (!rate.success) throw new ApiError(429, 'rate_limited', '投稿过于频繁，请稍后再试');
  await verifyTurnstile(c.env, parsed.data.turnstile_token, c.req.header('CF-Connecting-IP'));

  const { turnstile_token: _token, ...submission } = parsed.data;
  const { data, error } = await adminClient(c.env)
    .from('event_submissions')
    .insert({ ...submission, proposed_sites: [...new Set(submission.proposed_sites)], submitter_id: user.id, status: 'pending' })
    .select('id,status,created_at')
    .single();
  if (error) throw new ApiError(422, 'submission_failed', '投稿保存失败', error.message);
  return c.json({ data }, 201);
});

app.post('/v1/admin/submissions/:id/review', requireUser, async (c) => {
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

app.post('/v1/uploads/sign', requireUser, async (c) => {
  const parsed = uploadSignSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) throw new ApiError(422, 'validation_failed', '上传参数格式错误', parsed.error.flatten());
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
