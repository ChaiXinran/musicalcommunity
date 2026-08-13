import { z } from 'zod';

const optionalText = (max: number) => z.string().trim().max(max).optional().nullable();
const coordinatePair = z.object({
  latitude: z.number().min(-90).max(90).optional().nullable(),
  longitude: z.number().min(-180).max(180).optional().nullable(),
}).refine((value) => (value.latitude == null) === (value.longitude == null), {
  message: 'latitude 和 longitude 必须同时提供',
});

export const submissionSchema = z.object({
  submission_scope: z.enum(['public', 'private']).default('public'),
  submission_kind: z.enum(['create', 'edit']).default('create'),
  target_event_id: z.uuid().optional().nullable(),
  person_ids: z.array(z.enum(['ayg', 'zyl'])).max(2).default([]),
  proposed_sites: z.array(z.enum(['ayg', 'zyl', 'duo'])).max(3).default(['duo']),
  title: z.string().trim().min(1).max(200),
  category: z.string().trim().min(1).max(80),
  start_time: z.iso.datetime({ offset: true }),
  end_time: z.iso.datetime({ offset: true }).optional().nullable(),
  venue: optionalText(200),
  city: optionalText(100),
  country: optionalText(100),
  description: z.string().trim().max(10000).default(''),
  source_url: z.url().refine((url) => /^https?:\/\//.test(url), '只允许 http/https URL').optional().nullable(),
  media_links: z.array(z.url()).max(20).default([]),
  payload_json: z.record(z.string(), z.unknown()).default({}),
  turnstile_token: z.string().min(1).max(2048),
}).and(coordinatePair).superRefine((value, context) => {
  if (value.end_time && Date.parse(value.end_time) < Date.parse(value.start_time)) {
    context.addIssue({ code: 'custom', path: ['end_time'], message: 'end_time 不能早于 start_time' });
  }
  if (value.submission_scope === 'private' && value.submission_kind !== 'create') {
    context.addIssue({ code: 'custom', path: ['submission_kind'], message: '私人投稿只支持添加活动' });
  }
  if (value.submission_kind === 'edit' && !value.target_event_id) {
    context.addIssue({ code: 'custom', path: ['target_event_id'], message: '编辑投稿必须选择原有活动' });
  }
  if (value.submission_scope === 'public' && !value.person_ids.length) {
    context.addIssue({ code: 'custom', path: ['person_ids'], message: '公开投稿至少选择一位人物' });
  }
});

export const reviewSchema = z.object({
  decision: z.enum(['approved', 'rejected', 'merged']),
  review_note: optionalText(2000),
  target_event_id: z.uuid().optional().nullable(),
}).superRefine((value, context) => {
  if (value.decision === 'merged' && !value.target_event_id) {
    context.addIssue({ code: 'custom', path: ['target_event_id'], message: '合并时必须提供目标活动 ID' });
  }
});

export const accountReviewSchema = z.object({
  decision: z.enum(['approved', 'rejected']),
  review_note: optionalText(2000),
});

export const reviewQuestionSchema = z.object({
  prompt: z.string().trim().min(10).max(500),
  site_id: z.enum(['duo', 'ayg', 'zyl']).default('duo'),
});

export const reviewQuestionDecisionSchema = z.object({
  decision: z.enum(['approved', 'rejected']),
  review_note: optionalText(2000),
});

export const managementLevelSchema = z.object({
  level: z.union([z.literal(2), z.literal(3), z.null()]),
});

export const adminRegisterUserSchema = z.object({
  email: z.email().transform((value) => value.trim().toLowerCase()),
  password: z.string().min(8).max(128),
  answer: z.string().trim().min(200).max(5000),
});

export const reportReviewSchema = z.object({
  decision: z.enum(['upheld', 'dismissed']),
  review_note: optionalText(2000),
});

export const reportSubmissionSchema = z.object({
  comment_id: z.uuid().optional().nullable(),
  reported_user_id: z.uuid().optional().nullable(),
  reason: z.string().trim().min(1).max(100).default('快捷举报'),
  details: z.string().trim().max(2000).default(''),
}).superRefine((value, context) => {
  if (Number(Boolean(value.comment_id)) + Number(Boolean(value.reported_user_id)) !== 1) {
    context.addIssue({ code: 'custom', path: ['comment_id'], message: '必须且只能举报一条评论或一个账号' });
  }
});

export const banAppealSchema = z.object({
  message: z.string().trim().min(20).max(5000),
});

export const banAppealReviewSchema = z.object({
  decision: z.enum(['accepted', 'rejected']),
  review_note: optionalText(2000),
  fandom: z.enum(['ayanga', 'zhengyunlong']).optional().nullable(),
}).superRefine((value, context) => {
  if (value.decision === 'rejected' && !value.fandom) {
    context.addIssue({ code: 'custom', path: ['fandom'], message: '拒绝申诉时必须选择毒唯归属' });
  }
  if (value.decision === 'accepted' && value.fandom) {
    context.addIssue({ code: 'custom', path: ['fandom'], message: '接受申诉时不能设置毒唯归属' });
  }
});

export const uploadSignSchema = z.object({
  purpose: z.enum(['avatar', 'submission', 'event_photo', 'comment_image', 'site_background', 'announcement_image', 'promotion_image']),
  content_type: z.enum(['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'image/gif', 'video/mp4', 'video/webm']),
  byte_size: z.number().int().positive().max(100 * 1024 * 1024),
  submission_id: z.uuid().optional().nullable(),
}).superRefine((value, context) => {
  if (value.purpose === 'submission' && !value.submission_id) {
    context.addIssue({ code: 'custom', path: ['submission_id'], message: '投稿媒体必须关联投稿 ID' });
  }
  if (value.purpose !== 'submission' && value.submission_id) {
    context.addIssue({ code: 'custom', path: ['submission_id'], message: '只有投稿媒体可关联投稿 ID' });
  }
});

export const uploadCompleteSchema = z.object({ media_id: z.uuid() });

export const siteBackgroundSchema = z.object({ media_id: z.uuid() });
export const promotionSchema = z.object({ media_id: z.uuid() });

export const announcementSchema = z.object({
  title: z.string().trim().min(1).max(200),
  message: z.string().trim().min(1).max(10000),
  audience: z.enum(['guest', 'registered', 'banned', 'all']),
  site_ids: z.array(z.enum(['duo', 'ayg', 'zyl'])).min(1).max(3),
  image_media_id: z.uuid().optional().nullable(),
});

export const userGroupSchema = z.object({ group: z.enum(['yunv', 'cloud', 'star']) });

export function parseLimit(raw: string | undefined, fallback = 50, maximum = 100): number {
  const value = Number(raw ?? fallback);
  if (!Number.isInteger(value) || value < 1) return fallback;
  return Math.min(value, maximum);
}
