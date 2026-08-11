import type { Context, MiddlewareHandler } from 'hono';
import { ApiError } from './errors';
import { publicClient, userClient } from './supabase';
import type { AppEnv } from './types';

type AppRole = 'user' | 'editor' | 'moderator' | 'admin';
type ProfileStatus = 'pending' | 'active' | 'suspended' | 'rejected' | 'deleted';
export type ManagementLevel = 1 | 2 | 3 | null;

export function managementLevel(roles: AppRole[]): ManagementLevel {
  if (roles.includes('admin')) return 1;
  if (roles.includes('editor')) return 2;
  if (roles.includes('moderator')) return 3;
  return null;
}

export function bearerToken(header: string | undefined): string {
  if (!header) throw new ApiError(401, 'authentication_required', '请先登录');
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match?.[1]) throw new ApiError(401, 'invalid_authorization', 'Authorization 请求头无效');
  return match[1];
}

async function authenticate(c: Context<AppEnv>): Promise<void> {
  const token = bearerToken(c.req.header('Authorization'));
  const { data, error } = await publicClient(c.env).auth.getUser(token);
  if (error || !data.user) throw new ApiError(401, 'invalid_session', '登录状态已失效，请重新登录');
  c.set('accessToken', token);
  c.set('user', data.user);
}

async function loadAccess(c: Context<AppEnv>): Promise<{ status: ProfileStatus; roles: AppRole[] }> {
  const client = userClient(c.env, c.get('accessToken'));
  const userId = c.get('user').id;
  const [{ data: profile, error: profileError }, { data: roleRows, error: rolesError }] = await Promise.all([
    client.from('profiles').select('status').eq('user_id', userId).single(),
    client.from('user_roles').select('role').eq('user_id', userId),
  ]);
  if (profileError || !profile) throw new ApiError(403, 'profile_unavailable', '账号资料不存在或暂不可用', profileError?.message);
  if (rolesError) throw new ApiError(502, 'database_error', '无法读取账号权限', rolesError.message);
  const status = profile.status as ProfileStatus;
  const roles = (roleRows ?? []).map((row) => row.role as AppRole);
  c.set('profileStatus', status);
  c.set('roles', roles);
  c.set('managementLevel', managementLevel(roles));
  return { status, roles };
}

export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  await authenticate(c);
  await next();
};

export const requireApprovedUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  await authenticate(c);
  const { status } = await loadAccess(c);
  if (status === 'pending') throw new ApiError(403, 'account_pending', '账号正在等待管理员审核');
  if (status === 'rejected') throw new ApiError(403, 'account_rejected', '账号申请未通过，请联系管理员');
  if (status !== 'active') throw new ApiError(403, 'account_locked', '账号当前不可参与社区互动');
  await next();
};

export const requireAdmin: MiddlewareHandler<AppEnv> = async (c, next) => {
  return requireManagementLevel(3)(c, next);
};

export function requireManagementLevel(maximumLevel: 1 | 2 | 3): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
  await authenticate(c);
  const { status, roles } = await loadAccess(c);
    const level = managementLevel(roles);
    if (status !== 'active' || level === null || level > maximumLevel) {
      throw new ApiError(403, 'admin_required', `需要${maximumLevel === 1 ? '一级' : maximumLevel === 2 ? '一级或二级' : '管理员'}权限`);
    }
  await next();
  };
}

export const requireLevel1 = requireManagementLevel(1);
export const requireLevel2 = requireManagementLevel(2);
export const requireLevel3 = requireManagementLevel(3);

export async function currentAccess(c: Context<AppEnv>): Promise<{ status: ProfileStatus; roles: AppRole[] }> {
  return loadAccess(c);
}
