-- Track Telegram messages created for in-app broadcasts so admins can remove
-- the corresponding bot messages when a broadcast is deleted.
create table if not exists public.broadcast_telegram_messages (
  id uuid primary key default gen_random_uuid(),
  broadcast_id uuid not null references public.broadcasts(id) on delete cascade,
  telegram_subject text not null,
  message_id bigint not null,
  sent_at timestamptz not null default now(),
  unique (broadcast_id, telegram_subject)
);

alter table public.broadcast_telegram_messages enable row level security;

grant select, insert, update, delete on public.broadcast_telegram_messages to authenticated;

drop policy if exists admin_broadcast_telegram_messages_all on public.broadcast_telegram_messages;
create policy admin_broadcast_telegram_messages_all
  on public.broadcast_telegram_messages for all
  using (public.is_admin())
  with check (public.is_admin());

grant execute on function public.get_my_profile() to authenticated;
