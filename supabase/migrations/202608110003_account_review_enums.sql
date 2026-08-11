-- Account applications are stored as profile states. Keep enum changes in a
-- separate migration because PostgreSQL cannot safely use new enum values in
-- the same transaction that introduces them.

alter type public.profile_status add value if not exists 'pending' before 'active';
alter type public.profile_status add value if not exists 'rejected' after 'suspended';

alter type public.moderation_action_type add value if not exists 'approve_user';
alter type public.moderation_action_type add value if not exists 'reject_user';

