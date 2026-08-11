# Musical Community Backend

三个独立前端共享的一套社区后端：

| 前端 | `site_id` | 正式域名 |
| --- | --- | --- |
| 阿云嘎个人站（`ayg` 仓库） | `ayg` | `aygmusical.ranyechai.site` |
| 郑云龙个人站（`zyl` 仓库） | `zyl` | `zyldl.ranyechai.site` |
| 双人站（`event-earth-demo` 仓库） | `duo` | `musical.ranyechai.site` |

统一服务：

- Supabase Auth：唯一账号库，密码和登录会话不进入业务表。
- Supabase Postgres + RLS：活动、评论、点赞、收藏、投稿和审核权限。
- Cloudflare Worker：`api.ranyechai.site` 上的可信操作边界。
- Cloudflare R2：`media.ranyechai.site` 的头像、投稿图片和短视频。

## 已实现

- 注册后自动创建待审核 `profiles` 和默认 `user` 角色；邮箱确认后仍需管理员批准才能评论和投稿。
- 一个 `events` 表，通过 `event_sites` 同时投放到一个或多个网站。
- `event_people` 单独描述“谁参与”，不与“在哪个站展示”混用。
- 评论按 `site_id + event_id` 隔离，数据库强制最多两层回复。
- 评论点赞唯一键防重复；活动收藏不含 `site_id`，因此跨站共享。
- 投稿只能经 Worker + Turnstile 进入 `pending`；浏览器不能绕过验证直接提交待审数据。
- 审核 RPC 在一个数据库事务中完成批准、拒绝或合并；批准后才创建正式活动。
- 管理员 API 可列出并审核账号申请与投稿申请；前端审核工作台只对 `admin` 可见。
- R2 15 分钟签名直传，限制用途、MIME、大小和单次写入；完成时复查实际大小、元数据和文件魔数。
- 用户级 Cloudflare Rate Limiting；举报、封禁和审核审计表已预留。

## 目录

```text
backend/
├── supabase/
│   ├── migrations/       # 数据模型、触发器、RPC、RLS、最小授权
│   ├── tests/database/   # pgTAP 工作流与越权测试
│   ├── config.toml
│   └── seed.sql          # ayg / zyl / duo 与人物种子
├── worker/
│   ├── src/              # API、鉴权、Turnstile、R2 上传
│   ├── test/             # Vitest 单元测试
│   └── wrangler.jsonc
├── config/r2-cors.json
├── scripts/              # 历史活动迁移与前端 UUID 映射生成器
├── reports/              # 导入统计、合并项和跳过项
└── docs/
```

## 本地开发

要求 Node.js 20+、Docker Desktop（Linux 容器）和 npm。

```powershell
npm install
npm run db:start
npm run db:reset
npm run db:test
npm run db:lint
Copy-Item worker/.dev.vars.example worker/.dev.vars
npm run dev
```

常用验证：

```powershell
npm run check
npm test
npm run history:check
```

本地 Supabase 默认 API 为 `http://127.0.0.1:54321`，Studio 为 `http://127.0.0.1:54323`。`worker/.dev.vars` 只用于本机，不提交 Git。

## 生产部署

按 [部署手册](docs/deployment.md) 创建 Supabase、R2、Turnstile 和 Worker。三前端只允许持有：

```text
SUPABASE_URL
SUPABASE_PUBLISHABLE_KEY
API_BASE_URL=https://api.ranyechai.site
MEDIA_PUBLIC_BASE_URL=https://media.ranyechai.site
SITE_ID=ayg | zyl | duo
```

`SUPABASE_SECRET_KEY`、R2 密钥和 `TURNSTILE_SECRET_KEY` 只能进入 Worker Secret。

接口见 [API 契约](docs/api.md)，三个网站的接入方式见 [前端接入说明](docs/frontend-integration.md)。
邮箱确认注册的 Supabase、SMTP、邮件模板和 Turnstile 配置见 [邮箱确认登录配置](docs/auth-email-setup.md)。

## 当前登录阶段

V1 三站使用同一 Supabase Project，因此账号、资料和收藏完全共享；浏览器 session 仍按各站 Origin 保存，用户第一次访问另一个站时可能需要再次登录。真正的“登录一次、三站通用”属于 V2，应单独建设 `auth.ranyechai.site` 的 Cookie + PKCE 流程，不能用复制 localStorage token 的方式实现。
