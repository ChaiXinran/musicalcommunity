import { ApiError } from './errors';
import type { WorkerBindings } from './types';

interface TurnstileResult {
  success: boolean;
  hostname?: string;
  'error-codes'?: string[];
}

export async function verifyTurnstile(env: WorkerBindings, token: string, remoteIp?: string): Promise<void> {
  const body = new FormData();
  body.set('secret', env.TURNSTILE_SECRET_KEY);
  body.set('response', token);
  body.set('idempotency_key', crypto.randomUUID());
  if (remoteIp) body.set('remoteip', remoteIp);

  let response: Response;
  try {
    response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body });
  } catch {
    throw new ApiError(502, 'captcha_unavailable', '人机验证服务暂时不可用');
  }
  if (!response.ok) throw new ApiError(502, 'captcha_unavailable', '人机验证服务暂时不可用');

  const result = (await response.json()) as TurnstileResult;
  if (!result.success) {
    throw new ApiError(403, 'captcha_failed', '人机验证失败，请刷新后重试', result['error-codes']);
  }

  const allowedHosts = env.TURNSTILE_ALLOWED_HOSTNAMES.split(',').map((value) => value.trim()).filter(Boolean);
  const usingTestSecret = env.TURNSTILE_SECRET_KEY.startsWith('1x000000000000000000');
  if (!usingTestSecret && allowedHosts.length > 0 && (!result.hostname || !allowedHosts.includes(result.hostname))) {
    throw new ApiError(403, 'captcha_hostname_mismatch', '人机验证来源无效');
  }
}

