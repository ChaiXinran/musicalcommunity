import { describe, expect, it } from 'vitest';
import { accountReviewSchema, managementLevelSchema, reportReviewSchema, reviewQuestionSchema, submissionSchema, uploadSignSchema } from '../src/schemas';

describe('submissionSchema', () => {
  const valid = {
    proposed_sites: ['ayg'],
    title: '测试音乐剧',
    category: '音乐剧',
    start_time: '2026-08-11T12:00:00+08:00',
    latitude: 31.2304,
    longitude: 121.4737,
    turnstile_token: 'test-token',
  };

  it('accepts a valid pending submission payload', () => {
    expect(submissionSchema.safeParse(valid).success).toBe(true);
  });

  it('requires a complete coordinate pair', () => {
    const result = submissionSchema.safeParse({ ...valid, longitude: undefined });
    expect(result.success).toBe(false);
  });

  it('rejects an end time before the start time', () => {
    const result = submissionSchema.safeParse({ ...valid, end_time: '2026-08-10T12:00:00+08:00' });
    expect(result.success).toBe(false);
  });
});

describe('uploadSignSchema', () => {
  it('requires submission media to be linked to a submission', () => {
    const result = uploadSignSchema.safeParse({ purpose: 'submission', content_type: 'image/webp', byte_size: 1024 });
    expect(result.success).toBe(false);
  });
});

describe('accountReviewSchema', () => {
  it('accepts account approval and rejection only', () => {
    expect(accountReviewSchema.safeParse({ decision: 'approved' }).success).toBe(true);
    expect(accountReviewSchema.safeParse({ decision: 'rejected', review_note: '资料不完整' }).success).toBe(true);
    expect(accountReviewSchema.safeParse({ decision: 'merged' }).success).toBe(false);
  });
});

describe('management review schemas', () => {
  it('accepts only assignable management levels', () => {
    expect(managementLevelSchema.safeParse({ level: 2 }).success).toBe(true);
    expect(managementLevelSchema.safeParse({ level: 3 }).success).toBe(true);
    expect(managementLevelSchema.safeParse({ level: null }).success).toBe(true);
    expect(managementLevelSchema.safeParse({ level: 1 }).success).toBe(false);
  });

  it('validates question and report decisions', () => {
    expect(reviewQuestionSchema.safeParse({ prompt: '请说明你会如何参与社区讨论并维护良好氛围。' }).success).toBe(true);
    expect(reviewQuestionSchema.safeParse({ prompt: '太短' }).success).toBe(false);
    expect(reportReviewSchema.safeParse({ decision: 'resolved' }).success).toBe(true);
    expect(reportReviewSchema.safeParse({ decision: 'approved' }).success).toBe(false);
  });
});
