-- Website data and RPCs are accessible only after authentication.
-- Login Edge Functions remain public endpoints and create a verified session.

revoke all privileges on all tables in schema public from public, anon;
revoke all privileges on all sequences in schema public from public, anon;

-- Authenticated operations remain constrained by the existing RLS policies.
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- PostgreSQL functions are executable by PUBLIC by default; remove that
-- implicit access and explicitly expose only authenticated application RPCs.
revoke execute on all functions in schema public from public, anon;

grant execute on function public.telegram_subject() to authenticated;
grant execute on function public.is_allowed() to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.assert_allowed() to authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.get_my_access_state() to authenticated;
grant execute on function public.get_catalog() to authenticated;
grant execute on function public.get_demo_info() to authenticated;
grant execute on function public.get_my_kyc_status() to authenticated;
grant execute on function public.play_game(public.game_type) to authenticated;
grant execute on function public.redeem_reward(uuid, uuid) to authenticated;
grant execute on function public.submit_feedback(uuid, integer, text) to authenticated;

grant execute on function public.admin_dashboard() to authenticated;
grant execute on function public.admin_set_profile_blocked(uuid, boolean) to authenticated;
grant execute on function public.admin_adjust_wallet(uuid, integer, integer, integer, text) to authenticated;
grant execute on function public.admin_update_order_status(uuid, public.order_status, text) to authenticated;
grant execute on function public.admin_create_broadcast(text, text, boolean) to authenticated;
grant execute on function public.admin_create_demo_product(text, uuid, jsonb, boolean) to authenticated;
grant execute on function public.admin_delete_product(uuid) to authenticated;
grant execute on function public.admin_delete_category(uuid) to authenticated;
grant execute on function public.admin_log_kyc_view(uuid) to authenticated;
grant execute on function public.admin_review_kyc(uuid, text, text) to authenticated;
grant execute on function public.admin_moderate_feedback(uuid, public.feedback_status) to authenticated;
grant execute on function public.admin_set_token_tier(integer, integer) to authenticated;

grant execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) to service_role;
grant execute on function public.telegram_admin_order_action(uuid, uuid, text) to service_role;
