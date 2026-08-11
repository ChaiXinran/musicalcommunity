import { AwsClient } from 'aws4fetch';
import { ApiError } from './errors';
import { adminClient, userClient } from './supabase';
import type { WorkerBindings } from './types';

const MIME_RULES = {
  avatar: { max: 5 * 1024 * 1024, types: ['image/jpeg', 'image/png', 'image/webp', 'image/avif'] },
  submission: { max: 100 * 1024 * 1024, types: ['image/jpeg', 'image/png', 'image/webp', 'image/avif', 'video/mp4', 'video/webm'] },
  event_photo: { max: 25 * 1024 * 1024, types: ['image/jpeg', 'image/png', 'image/webp', 'image/avif'] },
  comment_image: { max: 8 * 1024 * 1024, types: ['image/jpeg', 'image/png', 'image/webp', 'image/avif'] },
  site_background: { max: 25 * 1024 * 1024, types: ['image/jpeg', 'image/png', 'image/webp', 'image/avif'] },
} as const;

const EXTENSIONS: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/avif': 'avif',
  'video/mp4': 'mp4',
  'video/webm': 'webm',
};

const PREFIXES = { avatar: 'avatars', submission: 'submissions', event_photo: 'event-photos', comment_image: 'comment-images', site_background: 'site-backgrounds' } as const;

export interface SignUploadInput {
  purpose: keyof typeof MIME_RULES;
  content_type: keyof typeof EXTENSIONS;
  byte_size: number;
  submission_id?: string | null;
}

export function validateMedia(input: SignUploadInput): void {
  const rule = MIME_RULES[input.purpose];
  if (!(rule.types as readonly string[]).includes(input.content_type)) {
    throw new ApiError(415, 'unsupported_media_type', `不支持此用途的文件类型：${input.content_type}`);
  }
  if (input.byte_size > rule.max) {
    throw new ApiError(413, 'file_too_large', `文件超过 ${Math.floor(rule.max / 1024 / 1024)} MB 限制`);
  }
}

export function matchesMagicBytes(contentType: string, bytes: Uint8Array): boolean {
  const ascii = (start: number, end: number) => String.fromCharCode(...bytes.slice(start, end));
  switch (contentType) {
    case 'image/jpeg':
      return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    case 'image/png':
      return bytes[0] === 0x89 && ascii(1, 4) === 'PNG';
    case 'image/webp':
      return ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP';
    case 'image/avif':
      return ascii(4, 8) === 'ftyp' && ['avif', 'avis'].includes(ascii(8, 12));
    case 'video/mp4':
      return ascii(4, 8) === 'ftyp';
    case 'video/webm':
      return bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3;
    default:
      return false;
  }
}

export async function signUpload(env: WorkerBindings, accessToken: string, userId: string, input: SignUploadInput) {
  validateMedia(input);
  if (input.submission_id) {
    const { data, error } = await userClient(env, accessToken)
      .from('event_submissions')
      .select('id,status')
      .eq('id', input.submission_id)
      .eq('submitter_id', userId)
      .in('status', ['draft', 'pending'])
      .maybeSingle();
    if (error || !data) throw new ApiError(404, 'submission_not_found', '投稿不存在或不可添加媒体');
  }

  const id = crypto.randomUUID();
  const objectKey = `${PREFIXES[input.purpose]}/${userId}/${id}.${EXTENSIONS[input.content_type]}`;
  const admin = adminClient(env);
  const { error: insertError } = await admin.from('media').insert({
    id,
    owner_id: userId,
    bucket: env.R2_BUCKET_NAME,
    object_key: objectKey,
    purpose: input.purpose,
    content_type: input.content_type,
    byte_size: input.byte_size,
    status: 'pending_upload',
  });
  if (insertError) throw new ApiError(500, 'media_record_failed', '无法创建媒体记录', insertError.message);

  if (input.submission_id) {
    const { error: joinError } = await admin.from('submission_media').insert({ submission_id: input.submission_id, media_id: id });
    if (joinError) {
      await admin.from('media').delete().eq('id', id);
      throw new ApiError(500, 'media_link_failed', '无法关联投稿媒体', joinError.message);
    }
  }

  const url = new URL(`https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${env.R2_BUCKET_NAME}/${objectKey}`);
  url.searchParams.set('X-Amz-Expires', '900');
  const signer = new AwsClient({ accessKeyId: env.R2_ACCESS_KEY_ID, secretAccessKey: env.R2_SECRET_ACCESS_KEY });
  const uploadHeaders = { 'Content-Type': input.content_type, 'If-None-Match': '*' };
  const signed = await signer.sign(new Request(url, { method: 'PUT', headers: uploadHeaders }), {
    aws: { signQuery: true },
  });

  return { media_id: id, object_key: objectKey, upload_url: signed.url, method: 'PUT', headers: uploadHeaders, expires_in: 900 };
}

export async function completeUpload(env: WorkerBindings, userId: string, mediaId: string) {
  const admin = adminClient(env);
  const { data: media, error } = await admin.from('media').select('*').eq('id', mediaId).eq('owner_id', userId).maybeSingle();
  if (error || !media) throw new ApiError(404, 'media_not_found', '媒体记录不存在');
  if (media.status === 'available') {
    return { media_id: media.id, object_key: media.object_key, public_url: `${env.MEDIA_PUBLIC_BASE_URL}/${media.object_key}` };
  }
  if (media.status !== 'pending_upload') throw new ApiError(409, 'media_not_completable', '该媒体记录当前不可完成');

  const object = await env.MEDIA_BUCKET.head(media.object_key);
  if (!object) throw new ApiError(409, 'upload_missing', 'R2 中尚未找到上传文件');
  if (object.size !== media.byte_size) {
    await env.MEDIA_BUCKET.delete(media.object_key);
    await admin.from('media').update({ status: 'quarantined' }).eq('id', media.id);
    throw new ApiError(409, 'upload_size_mismatch', '实际文件大小与声明不一致，文件已隔离');
  }
  const actualType = object.httpMetadata?.contentType;
  if (actualType && actualType !== media.content_type) {
    await env.MEDIA_BUCKET.delete(media.object_key);
    await admin.from('media').update({ status: 'quarantined' }).eq('id', media.id);
    throw new ApiError(409, 'upload_type_mismatch', '实际文件类型与声明不一致，文件已隔离');
  }
  const prefix = await env.MEDIA_BUCKET.get(media.object_key, { range: { offset: 0, length: 32 } });
  if (!prefix || !matchesMagicBytes(media.content_type, new Uint8Array(await prefix.arrayBuffer()))) {
    await env.MEDIA_BUCKET.delete(media.object_key);
    await admin.from('media').update({ status: 'quarantined' }).eq('id', media.id);
    throw new ApiError(409, 'upload_signature_mismatch', '文件内容与声明类型不一致，文件已隔离');
  }

  const { error: updateError } = await admin.from('media').update({ status: 'available' }).eq('id', media.id).eq('status', 'pending_upload');
  if (updateError) throw new ApiError(500, 'media_finalize_failed', '无法完成媒体记录', updateError.message);
  if (media.purpose === 'avatar') {
    await admin.from('profiles').update({ avatar_key: media.object_key }).eq('user_id', userId);
  }
  return { media_id: media.id, object_key: media.object_key, public_url: `${env.MEDIA_PUBLIC_BASE_URL}/${media.object_key}` };
}
