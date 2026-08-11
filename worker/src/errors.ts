import type { Context } from 'hono';
import type { AppEnv } from './types';

export class ApiError extends Error {
  constructor(
    public readonly status: 400 | 401 | 403 | 404 | 409 | 413 | 415 | 422 | 429 | 500 | 502,
    public readonly code: string,
    message: string,
    public readonly details?: unknown,
  ) {
    super(message);
  }
}

export function errorResponse(c: Context<AppEnv>, error: unknown): Response {
  if (error instanceof ApiError) {
    return c.json(
      { error: { code: error.code, message: error.message, ...(error.details === undefined ? {} : { details: error.details }) } },
      error.status,
    );
  }

  console.error(error);
  return c.json({ error: { code: 'internal_error', message: '服务器暂时无法处理该请求' } }, 500);
}

