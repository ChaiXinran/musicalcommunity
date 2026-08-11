import { z } from 'zod';

const optionalText = (max: number) => z.string().trim().max(max).optional().nullable();
const coordinatePair = z.object({
  latitude: z.number().min(-90).max(90).optional().nullable(),
  longitude: z.number().min(-180).max(180).optional().nullable(),
}).refine((value) => (value.latitude == null) === (value.longitude == null), {
  message: 'latitude 和 longitude 必须同时提供',
});

export const submissionSchema = z.object({
  proposed_sites: z.array(z.enum(['ayg', 'zyl', 'duo'])).min(1).max(3),
  title: z.string().trim().min(1).max(200),
  category: z.string().trim().min(1).max(80),
  start_time: z.iso.datetime({ offset: true }),
  end_time: z.iso.datetime({ offset: true }).optional().nullable(),
  venue: optionalText(200),
  city: optionalText(100),
  country: optionalText(100),
  description: z.string().trim().max(10000).default(''),
  source_url: z.url().refine((url) => /^https?:\/\//.test(url), '只允许 http/https URL').optional().nullable(),
  payload_json: z.record(z.string(), z.unknown()).default({}),
  turnstile_token: z.string().min(1).max(2048),
}).and(coordinatePair).superRefine((value, context) => {
  if (value.end_time && Date.parse(value.end_time) < Date.parse(value.start_time)) {
    context.addIssue({ code: 'custom', path: ['end_time'], message: 'end_time 不能早于 start_time' });
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
});

export const reviewQuestionDecisionSchema = z.object({
  decision: z.enum(['approved', 'rejected']),
  review_note: optionalText(2000),
});

export const managementLevelSchema = z.object({
  level: z.union([z.literal(2), z.literal(3), z.null()]),
});

export const reportReviewSchema = z.object({
  decision: z.enum(['resolved', 'dismissed']),
  review_note: optionalText(2000),
});

export const uploadSignSchema = z.object({
  purpose: z.enum(['avatar', 'submission', 'event_photo', 'comment_image']),
  content_type: z.enum(['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'video/mp4', 'video/webm']),
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

export function parseLimit(raw: string | undefined, fallback = 50, maximum = 100): number {
  const value = Number(raw ?? fallback);
  if (!Number.isInteger(value) || value < 1) return fallback;
  return Math.min(value, maximum);
}
