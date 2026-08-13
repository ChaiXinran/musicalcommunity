import { describe, expect, it } from 'vitest';
import { ApiError } from '../src/errors';
import { matchesMagicBytes, validateMedia } from '../src/uploads';

describe('validateMedia', () => {
  it('accepts a small avatar image', () => {
    expect(() => validateMedia({ purpose: 'avatar', content_type: 'image/webp', byte_size: 1024 })).not.toThrow();
  });

  it('rejects video avatars', () => {
    expect(() => validateMedia({ purpose: 'avatar', content_type: 'video/mp4', byte_size: 1024 })).toThrow(ApiError);
  });

  it('rejects oversized comment images', () => {
    expect(() => validateMedia({ purpose: 'comment_image', content_type: 'image/png', byte_size: 9 * 1024 * 1024 })).toThrowError(/8 MB/);
  });

  it('accepts GIF files for every animated-image setting', () => {
    for (const purpose of ['site_background', 'announcement_image', 'promotion_image'] as const) {
      expect(() => validateMedia({ purpose, content_type: 'image/gif', byte_size: 1024 })).not.toThrow();
    }
  });
});

describe('matchesMagicBytes', () => {
  it('recognizes PNG and rejects an executable renamed to PNG', () => {
    expect(matchesMagicBytes('image/png', Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]))).toBe(true);
    expect(matchesMagicBytes('image/png', new TextEncoder().encode('MZ fake executable'))).toBe(false);
  });

  it('recognizes MP4 by its ISO base media signature', () => {
    expect(matchesMagicBytes('video/mp4', Uint8Array.from([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d]))).toBe(true);
  });

  it('recognizes both valid GIF signatures', () => {
    expect(matchesMagicBytes('image/gif', new TextEncoder().encode('GIF87a'))).toBe(true);
    expect(matchesMagicBytes('image/gif', new TextEncoder().encode('GIF89a'))).toBe(true);
  });
});
