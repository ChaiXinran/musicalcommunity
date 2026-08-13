create or replace function private.notify_account_application_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  result_message text;
begin
  if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform private.create_notification(new.user_id, 'account', '账号申请已提交', '你的账号申请已经提交，请等待一级或二级管理员审核。', jsonb_build_object('user_id', new.user_id, 'status', new.status));
    perform private.notify_management(2::smallint, 'review', '新的账号申请', '有一份新的账号申请等待审核。', jsonb_build_object('user_id', new.user_id, 'queue', 'applications'), new.user_id);
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status in ('approved', 'rejected') then
    result_message := case when new.status = 'approved' then '你的账号已解锁评论和投稿功能。' else '你的账号申请未通过。' end;
    if nullif(btrim(new.review_note), '') is not null then
      result_message := result_message || E'\n\n管理员回复：' || btrim(new.review_note);
    end if;
    perform private.create_notification(new.user_id, 'account', case when new.status = 'approved' then '账号审核已通过' else '账号审核未通过' end, result_message, jsonb_build_object('user_id', new.user_id, 'status', new.status, 'review_note', new.review_note));
  end if;
  return new;
end;
$$;
