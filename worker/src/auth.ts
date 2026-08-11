import type { MiddlewareHandler } from 'hono';
import { ApiError } from './errors';
import { publicClient } from './supabase';
import type { AppEnv } from './types';

export function bearerToken(header: string | undefined): string {
  if (!header) throw new ApiError(401, 'authentication_required', '请先登录');
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match?.[1]) throw new ApiError(401, 'invalid_authorization', 'Authorization 请求头无效');
  return match[1];
}

export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  const token = bearerToken(c.req.header('Authorization'));
  const { data, error } = await publicClient(c.env).auth.getUser(token);
  if (error || !data.user) throw new ApiError(401, 'invalid_session', '登录状态已失效，请重新登录');
  c.set('accessToken', token);
  c.set('user', data.user);
  await next();
};

