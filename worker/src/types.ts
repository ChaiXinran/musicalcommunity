import type { User } from '@supabase/supabase-js';

export interface WorkerBindings {
  SUPABASE_URL: string;
  SUPABASE_PUBLISHABLE_KEY: string;
  SUPABASE_SECRET_KEY: string;
  R2_ACCOUNT_ID: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  R2_BUCKET_NAME: string;
  MEDIA_PUBLIC_BASE_URL: string;
  ALLOWED_ORIGINS: string;
  TURNSTILE_SECRET_KEY: string;
  TURNSTILE_ALLOWED_HOSTNAMES: string;
  MEDIA_BUCKET: R2Bucket;
  SUBMISSION_RATE_LIMITER: RateLimit;
  UPLOAD_RATE_LIMITER: RateLimit;
}

export interface AppEnv {
  Bindings: WorkerBindings;
  Variables: {
    accessToken: string;
    user: User;
  };
}

export interface ApiErrorBody {
  error: {
    code: string;
    message: string;
    details?: unknown;
  };
}

