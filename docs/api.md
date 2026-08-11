# API 契约

Base URL：`https://api.ranyechai.site`

所有响应使用 JSON。错误格式固定为：

```json
{
  "error": {
    "code": "validation_failed",
    "message": "投稿内容不完整或格式错误",
    "details": {}
  }
}
```

需要登录的接口传入 Supabase access token：

```http
Authorization: Bearer <access_token>
```

Worker 会调用 Supabase Auth `getUser(token)` 进行在线校验，不信任前端传来的 `user_id` 或角色。

## 当前账号

### `GET /v1/me`

返回当前登录账号的资料、审核状态、角色和能力：

```json
{
  "profile": { "status": "pending" },
  "roles": ["user"],
  "capabilities": { "comment": false, "submit": false, "admin": false }
}
```

新账号确认邮箱后默认是 `pending`。只有状态为 `active` 的账号可以评论、点赞和投稿；收藏仍可使用。

## 公共接口

### `GET /health`

健康检查。

### `GET /v1/sites`

返回已启用站点。

### `GET /v1/events?site_id=ayg&limit=50&before=<ISO_TIME>`

- `site_id`：`ayg`、`zyl` 或 `duo`，必填。
- `limit`：1–100。
- `before`：可选的 ISO 时间游标。

只返回 `published` 活动。一个活动可在多个站点返回，但数据库只保存一份活动本体。

## 投稿

### `POST /v1/submissions`

需要登录、Turnstile 和用户级限频。

```json
{
  "proposed_sites": ["ayg", "duo"],
  "title": "活动名称",
  "category": "音乐剧",
  "start_time": "2026-08-11T19:30:00+08:00",
  "end_time": "2026-08-11T22:00:00+08:00",
  "venue": "剧院名称",
  "city": "上海",
  "country": "中国",
  "latitude": 31.2304,
  "longitude": 121.4737,
  "description": "活动说明",
  "source_url": "https://example.com/source",
  "payload_json": {},
  "turnstile_token": "<token>"
}
```

成功后状态固定为 `pending`。如需草稿，可由登录用户直接通过 Supabase Data API 写入自己的 `draft`；RLS 不允许浏览器直接写 `pending`。

## 审核

### `GET /v1/admin/applications`

仅 `admin`。列出待审核账号申请。

### `POST /v1/admin/applications/:id/review`

仅 `admin`。账号通过：

```json
{ "decision": "approved", "review_note": "资料正常" }
```

账号拒绝：

```json
{ "decision": "rejected", "review_note": "拒绝原因" }
```

### `GET /v1/admin/submissions`

仅 `admin`。列出待审核投稿。

### `POST /v1/admin/submissions/:id/review`

网站管理工作台要求 `admin` 角色。底层数据库 RPC 仍允许 `moderator` 或 `admin`，便于未来拆分内容审核员角色。

批准：

```json
{ "decision": "approved", "review_note": "信息核验通过" }
```

合并重复活动：

```json
{
  "decision": "merged",
  "target_event_id": "00000000-0000-0000-0000-000000000000",
  "review_note": "与现有活动重复"
}
```

拒绝：

```json
{ "decision": "rejected", "review_note": "缺少可核验来源" }
```

数据库会锁定投稿行，避免两个审核员重复处理。

## 媒体上传

### 1. `POST /v1/uploads/sign`

```json
{
  "purpose": "submission",
  "content_type": "image/webp",
  "byte_size": 245760,
  "submission_id": "00000000-0000-0000-0000-000000000000"
}
```

`purpose` 可为 `avatar`、`submission`、`event_photo`、`comment_image`。投稿媒体必须关联本人拥有且仍可添加媒体的投稿。

响应中的 `upload_url`、`method` 和全部 `headers` 必须原样使用：

```js
await fetch(upload.upload_url, {
  method: upload.method,
  headers: upload.headers,
  body: file,
});
```

签名包含 `Content-Type` 和 `If-None-Match: *`；同一个 object key 只能写入一次，避免完成校验后被覆盖。

### 2. `POST /v1/uploads/complete`

```json
{ "media_id": "00000000-0000-0000-0000-000000000000" }
```

Worker 用 R2 Binding 复查对象大小、Content-Type 和文件头。通过后媒体变为 `available`；头像会同步更新 `profiles.avatar_key`。

## 可直接使用 Supabase + RLS 的功能

这些普通行级操作不需要绕 Worker：

- 查询 `events` / `event_sites` / `comments`。
- 登录用户发表或编辑自己的文字评论；删除使用 RPC `delete_own_comment` 做软删除。
- 增删自己的 `comment_likes`。
- 增删和查询自己的 `event_favorites`。
- 查询和编辑自己的 `draft` 投稿。
- 查询和编辑自己的 `profiles` 可编辑字段。

角色分配、待审投稿写入、媒体状态和正式活动写入不能从浏览器完成。
