import { describe, expect, it } from 'vitest';
import { bearerToken } from '../src/auth';
import { ApiError } from '../src/errors';

describe('bearerToken', () => {
  it('extracts a bearer access token', () => {
    expect(bearerToken('Bearer abc.def.ghi')).toBe('abc.def.ghi');
  });

  it('rejects missing or malformed authorization', () => {
    expect(() => bearerToken(undefined)).toThrow(ApiError);
    expect(() => bearerToken('Basic abc')).toThrowError(/Authorization/);
  });
});

