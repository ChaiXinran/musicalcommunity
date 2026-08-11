# 邮箱确认登录配置

双人站使用“邮箱 + 密码注册，点击确认邮件，再由管理员审核”的流程。前端会把确认链接回跳到当前网站的 `?community=account` 并显示待审核状态；管理员批准后才解锁评论和投稿。

## 1. 开启邮箱注册与确认

在 Supabase Dashboard 进入 `Authentication -> Providers -> Email`：

- 开启 Email Provider。
- 开启 Allow new users to sign up。
- 开启 Confirm email。
- OTP Expiry 建议不超过 3600 秒。

## 2. 配置回跳地址

在 `Authentication -> URL Configuration` 设置：

```text
Site URL
https://musical.ranyechai.site

Redirect URLs
https://musical.ranyechai.site/**
https://aygmusical.ranyechai.site/**
https://zyldl.ranyechai.site/**
http://localhost:3000/**
```

## 3. 配置 SMTP

在 `Authentication -> Emails -> SMTP Settings` 启用 Custom SMTP，并填写邮件服务商提供的 Host、Port、Username 和 Password。建议：

```text
Sender name: Musical Community
Sender email: no-reply@auth.ranyechai.site
```

为发信域名配置 SPF、DKIM 和 DMARC；关闭邮件服务商的链接追踪，避免确认链接被改写。

## 4. 修改确认邮件模板

在 `Authentication -> Emails -> Templates -> Confirm signup` 使用：

```html
<h2>确认邮箱，加入 Musical Community</h2>
<p>感谢你注册我们的剧场地图社区。请点击下面的按钮确认邮箱：</p>
<p><a href="{{ .ConfirmationURL }}">确认邮箱并加入社区</a></p>
<p>如果不是你发起的注册，可以忽略这封邮件。</p>
```

邮件主题建议使用：

```text
确认你的 Musical Community 账号
```

## 5. 启用 Turnstile

在 `Authentication -> Bot and Abuse Protection` 选择 Cloudflare Turnstile，填写生产 Widget 的 Site Key 和 Secret Key。Widget hostname 只允许：

```text
musical.ranyechai.site
aygmusical.ranyechai.site
zyldl.ranyechai.site
```

Site Key 可以进入前端；Secret Key 只能保存在 Supabase Dashboard 和 Worker Secret。生产 Widget 不需要允许 `localhost`。

## 6. 验收

1. 用一个未注册邮箱提交注册。
2. 确认页面进入“确认邮件已发送”状态。
3. 未点击邮件前尝试登录，应提示邮箱尚未确认。
4. 点击邮件按钮，应回到社区账号面板并显示“等待审核”。
5. 待审核账号不能评论或投稿，但可以使用私人收藏。
6. 管理员在审核工作台批准账号，用户刷新后立即解锁评论和投稿。
7. 测试“重新发送确认邮件”的 60 秒冷却。
