-- Credit a one-time welcome gift immediately after an approved member submits
-- their first order. Normal completion rewards remain separate.
create unique index if not exists loyalty_ledger_one_first_order_gift_per_user
  on public.loyalty_ledger (user_id, reference_type)
  where reference_type = 'first_order_gift';

do $$
declare
  v_definition text;
  v_declarations text := '  v_valid_count integer;';
  v_declarations_with_gift text := '  v_valid_count integer;
  v_is_first_order boolean;
  v_first_order_gift integer := 0;';
  v_first_order_check text := '  if not exists (select 1 from public.orders where user_id = p_user_id) and not exists (';
  v_first_order_check_with_gift text := '  v_is_first_order := not exists (select 1 from public.orders where user_id = p_user_id);
  if v_is_first_order and not exists (';
  v_return text := '  return jsonb_build_object(';
  v_gift_block text := '  if v_is_first_order
    and exists (select 1 from public.kyc_cases where user_id = p_user_id and status = ''approved'')
    and not exists (
      select 1 from public.loyalty_ledger
      where user_id = p_user_id and reference_type = ''first_order_gift''
    )
  then
    select least(5, 100 - points) into v_first_order_gift
    from public.wallet_balances
    where user_id = p_user_id
    for update;
    if coalesce(v_first_order_gift, 0) > 0 then
      update public.wallet_balances
      set points = points + v_first_order_gift, updated_at = now()
      where user_id = p_user_id
      returning * into v_wallet;
      insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
      values (p_user_id, ''Regalo primo ordine'', v_first_order_gift, 0, ''first_order_gift'', v_order);
    end if;
  end if;
';
begin
  select pg_get_functiondef('public.submit_test_order_internal(uuid,jsonb,text,text,text,integer)'::regprocedure)
  into v_definition;

  if position('v_first_order_gift integer' in v_definition) > 0 then
    return;
  end if;
  if position(v_declarations in v_definition) = 0
    or position(v_first_order_check in v_definition) = 0
    or position(v_return in v_definition) = 0
    or position('''tokens_on_complete'', v_expected_tokens, ''xp_on_complete'', v_expected_xp,' in v_definition) = 0
  then
    raise exception 'Impossibile aggiungere il regalo del primo ordine.';
  end if;

  v_definition := replace(v_definition, v_declarations, v_declarations_with_gift);
  v_definition := replace(v_definition, v_first_order_check, v_first_order_check_with_gift);
  v_definition := replace(v_definition, v_return, v_gift_block || v_return);
  v_definition := replace(
    v_definition,
    '''tokens_on_complete'', v_expected_tokens, ''xp_on_complete'', v_expected_xp,',
    '''tokens_on_complete'', v_expected_tokens, ''xp_on_complete'', v_expected_xp,
    ''first_order_gift'', v_first_order_gift,'
  );
  execute v_definition;
end;
$$;
