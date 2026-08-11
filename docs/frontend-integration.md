# 三前端接入说明

## 每个仓库固定一个站点 ID

```js
// ayg
export const SITE_ID = 'ayg';

// zyl
export const SITE_ID = 'zyl';

// event-earth-demo
export const SITE_ID = 'duo';
```

三站使用完全相同的 `SUPABASE_URL` 和 `SUPABASE_PUBLISHABLE_KEY`。Publishable Key 可以进入浏览器；权限由 RLS 控制。

## 活动

地图查询推荐调用：

```js
const response = await fetch(`${API_BASE_URL}/v1/events?site_id=${SITE_ID}&limit=100`);
const { data: events } = await response.json();
```

也可以直接查询 Supabase 的 `event_sites` 并展开 `events`。不要再为三个站建立三张活动表，也不要给 `events` 添加单值 `site_id`。

## 评论

创建评论时，`user_id` 必须来自已验证 session，`site_id` 必须使用仓库固定常量：

```js
await supabase.from('comments').insert({
  site_id: SITE_ID,
  event_id: eventId,
  user_id: session.user.id,
  parent_id: parentId ?? null,
  content,
});
```

读取时始终同时过滤：

```js
.eq('site_id', SITE_ID)
.eq('event_id', eventId)
```

数据库会拒绝跨站回复以及第三层嵌套。删除评论：

```js
await supabase.rpc('delete_own_comment', { p_comment_id: commentId });
```

## 收藏

收藏只写 `user_id + event_id`，不写 `site_id`。因此用户在 AYG 站收藏共同活动后，在双人站的个人中心仍能看到。

## 登录

V1 的正确预期是“同一账号、同一资料、同一收藏”，不是跨 Origin 自动共享浏览器 session。三个站各自初始化 Supabase 客户端即可。

不要：

- 在站点间通过 URL 传 access token。
- 把 token 复制到第三方可读 Cookie。
- 在前端判断 `role=admin` 后直接放行敏感操作。
- 把 Supabase Secret Key、R2 Secret 或 Turnstile Secret 打进构建产物。

V2 如需真正单点登录，统一迁移到 `auth.ranyechai.site`，使用 `HttpOnly; Secure; SameSite=Lax; Domain=.ranyechai.site` Cookie + PKCE，并确保认证响应不被 CDN 公共缓存。

