# 部署手册

## 1. Supabase

创建一个 Supabase Project，然后：

```powershell
npx supabase login
npx supabase link --project-ref <PROJECT_REF>
npx supabase db push --dry-run
npx supabase db push
```

生产环境不要使用 `--include-seed`。迁移已创建表结构；生产站点数据可在 SQL Editor 执行 `supabase/seed.sql`，或由受控后台写入。

在 Authentication 中配置三站 redirect URL，并为注册/找回密码启用 Turnstile。社区投稿使用 Worker 的 Turnstile 校验，两者的保护面不同。

### 历史活动导入

导入器读取双人站的两份人物活动模块，按“日期 + 标准化标题 + 城市”去重，为活动和场馆生成稳定 UUID，并同时生成前端旧 ID 到数据库 UUID 的映射：

```powershell
npm run history:generate
npm run history:check
npx supabase db push --dry-run
npx supabase db push
```

生成内容包括 `supabase/migrations/202608110002_import_historical_events.sql`、双人站的 `core/data/communityEventIds.js` 和 `reports/history-import.json`。没有明确日期的记录不会伪造 `start_time`，会保留在报告的 `skipped` 列表中。已经推送到生产的迁移不得原地重新生成；后续历史数据更新必须指定新的迁移文件名。

### 首位管理员

先正常注册并确认邮箱，再从 `Authentication -> Users` 复制用户 UUID，在 Supabase SQL Editor 完成首位管理员引导：

```sql
begin;

update public.profiles
set status = 'active'
where user_id = '<AUTH_USER_UUID>';

insert into public.user_roles (user_id, role)
values ('<AUTH_USER_UUID>', 'admin')
on conflict do nothing;

commit;
```

后续账号由网站内的“审核”工作台批准，不再执行手工 SQL。角色不能放在用户可修改的 metadata 或 profile 字段中。

迁移只会让“迁移之后注册的新账号”默认进入待审核，不会突然锁定已有用户。若首位管理员建立后需要让所有现有普通账号重新审核，可再执行：

```sql
update public.profiles p
set status = 'pending'
where status = 'active'
  and not exists (
    select 1 from public.user_roles r
    where r.user_id = p.user_id and r.role = 'admin'
  );
```

## 2. R2

创建生产桶 `musical-community` 和预览桶 `musical-community-dev`，将 `media.ranyechai.site` 绑定到生产桶。创建只针对该桶的 Object Read & Write S3 API Token，得到 Access Key ID 和 Secret Access Key。

应用浏览器直传 CORS：

```powershell
npx wrangler r2 bucket cors set musical-community --file config/r2-cors.json
```

Presigned URL 只能使用 `*.r2.cloudflarestorage.com` S3 API 域名；自定义域名仅用于读取。上传 URL 应视为 15 分钟有效的 bearer token。

## 3. Turnstile

创建 Widget，生产 hostname 只允许：

```text
aygmusical.ranyechai.site
zyldl.ranyechai.site
musical.ranyechai.site
```

本地开发使用 Cloudflare 官方测试 sitekey/secret；不要把 `localhost` 加入生产 Widget。

## 4. Worker 配置与 Secret

修改 `worker/wrangler.jsonc` 中所有 `REPLACE_ME`、Supabase URL/Publishable Key 和 R2 桶名。然后在 `worker` 目录运行：

```powershell
npx wrangler secret put SUPABASE_SECRET_KEY
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
npx wrangler secret put TURNSTILE_SECRET_KEY
npm run check
npm test
npx wrangler deploy --dry-run
npx wrangler deploy
```

Worker 的 Cloudflare API Token 至少需要 Workers Scripts、Routes、R2 Binding 和 Rate Limiting 所需权限。不要把 secret 写进 `wrangler.jsonc`。

## 5. 上线前验证

- `npm run db:test`：RLS、两层评论、投稿旁路防护和审核事务。
- `npm run db:lint`：Postgres 函数静态检查。
- `npm run check && npm test`：Worker 类型和单元测试。
- `npx wrangler deploy --dry-run`：Worker 打包与 bindings。
- 从三个正式 Origin 各做一次 CORS 请求；任意其他 Origin 必须失败。
- 用普通用户确认不能读取他人收藏、不能直接创建 `pending` 投稿、不能调用审核 RPC。
- 用新注册用户确认邮箱后仍为 `pending`，不能评论或投稿；管理员批准后立即解锁。
- 用管理员确认可以看到账号申请和投稿申请，批准投稿后公共活动 API 能返回新活动。
- 上传错误大小和伪装扩展名文件，确认对象被删除且媒体记录进入 `quarantined`。

## 6. 运维

- 定期删除长期停留在 `pending_upload` 的媒体记录和孤儿对象。
- R2 对临时/未完成上传配置生命周期规则。
- 为 Worker 5xx、Turnstile 失败率、429 和审核 RPC 异常建立告警。
- 数据库迁移只追加新文件；已经部署的迁移不要原地修改。
- V2 单点登录上线时，认证路由必须绕过 CDN 公共缓存。
