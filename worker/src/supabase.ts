import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { WorkerBindings } from './types';

const commonOptions = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
} as const;

export function publicClient(env: WorkerBindings): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, commonOptions);
}

export function userClient(env: WorkerBindings, accessToken: string): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, {
    ...commonOptions,
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

export function adminClient(env: WorkerBindings): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, commonOptions);
}

