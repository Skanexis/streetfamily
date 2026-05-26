-- Administrators may place their first order without completing KYC.
do $$
declare
  v_definition text;
  v_previous text :=
    'if not exists (select 1 from public.orders where user_id = p_user_id) and not exists (
    select 1 from public.kyc_cases where user_id = p_user_id and status = ''approved''
  ) then raise exception ''KYC_REQUIRED_FIRST_ORDER''; end if;';
  v_updated text :=
    'if not exists (select 1 from public.orders where user_id = p_user_id) and not exists (
    select 1 from public.profiles where id = p_user_id and role = ''admin''
  ) and not exists (
    select 1 from public.kyc_cases where user_id = p_user_id and status = ''approved''
  ) then raise exception ''KYC_REQUIRED_FIRST_ORDER''; end if;';
begin
  select pg_get_functiondef('public.submit_test_order_internal(uuid,jsonb,text,text,text,integer)'::regprocedure)
  into v_definition;

  if position(v_updated in v_definition) > 0 then
    return;
  end if;

  if position(v_previous in v_definition) = 0 then
    raise exception 'Impossibile aggiornare la regola KYC per amministratori.';
  end if;

  execute replace(v_definition, v_previous, v_updated);
end;
$$;
