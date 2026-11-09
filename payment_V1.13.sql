-- 咚咚造物局 V1.13。先完成 V1.12.1 與店主管理權限設定。
begin;

alter table public.orders
  add column if not exists remittance_last5 text check (remittance_last5 ~ '^[0-9]{5}$'),
  add column if not exists remittance_at timestamptz,
  add column if not exists remittance_reported_at timestamptz;

create table if not exists public.figurine_bank_settings (
  singleton boolean primary key default true check (singleton),
  bank_name text not null,
  bank_code text not null check (bank_code ~ '^[0-9]{3}$'),
  account_name text not null,
  account_number text not null check (account_number ~ '^[0-9]{6,20}$')
);
alter table public.figurine_bank_settings enable row level security;
revoke all on public.figurine_bank_settings from public, anon, authenticated;

create or replace function public.figurine_bank_for_checkout()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('bank_name', bank_name, 'bank_code', bank_code,
    'account_name', account_name, 'account_number', account_number)
  from public.figurine_bank_settings where singleton;
$$;

create or replace function public.admin_figurine_bank(p_settings jsonb default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_figurine_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;
  if p_settings is not null then
    if coalesce(char_length(btrim(p_settings->>'bank_name')), 0) not between 1 and 80
       or coalesce(p_settings->>'bank_code', '') !~ '^[0-9]{3}$'
       or coalesce(char_length(btrim(p_settings->>'account_name')), 0) not between 1 and 80
       or coalesce(p_settings->>'account_number', '') !~ '^[0-9]{6,20}$' then
      raise exception 'INVALID_BANK_SETTINGS';
    end if;
    insert into public.figurine_bank_settings (singleton, bank_name, bank_code, account_name, account_number)
    values (true, btrim(p_settings->>'bank_name'), p_settings->>'bank_code',
      btrim(p_settings->>'account_name'), p_settings->>'account_number')
    on conflict (singleton) do update set bank_name = excluded.bank_name,
      bank_code = excluded.bank_code, account_name = excluded.account_name,
      account_number = excluded.account_number;
  end if;
  return public.figurine_bank_for_checkout();
end;
$$;

create or replace function public.report_figurine_remittance(
  p_line_user_id text, p_order_id uuid, p_last5 text, p_transferred_at timestamptz
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_last5 is null or p_last5 !~ '^[0-9]{5}$' or p_transferred_at is null
     or p_transferred_at > now() + interval '5 minutes' then
    raise exception 'INVALID_REMITTANCE';
  end if;
  select * into v_order from public.orders
  where id = p_order_id and line_user_id = p_line_user_id for update;
  if not found or v_order.status <> 'pending_payment' then
    raise exception 'ORDER_NOT_PAYABLE';
  end if;
  if v_order.remittance_reported_at is not null then
    if v_order.remittance_last5 = p_last5 and v_order.remittance_at = p_transferred_at then
      return jsonb_build_object('reported', true);
    end if;
    raise exception 'ALREADY_REPORTED';
  end if;
  if not exists (select 1 from public.figurine_bank_settings where singleton) then
    raise exception 'BANK_NOT_CONFIGURED';
  end if;
  update public.orders set remittance_last5 = p_last5, remittance_at = p_transferred_at,
    remittance_reported_at = now() where id = p_order_id;
  return jsonb_build_object('reported', true);
end;
$$;

create or replace function public.admin_return_figurine_remittance(p_order_id uuid, p_reported_at timestamptz)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_figurine_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;
  update public.orders set remittance_last5 = null, remittance_at = null, remittance_reported_at = null
  where id = p_order_id and status = 'pending_payment' and remittance_reported_at = p_reported_at;
  if not found then raise exception 'REPORT_CHANGED'; end if;
end;
$$;

create or replace function public.guard_figurine_payment_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if old.status = 'pending_payment' and old.line_user_id is not null then
    if new.status = 'paid' and old.remittance_reported_at is null then
      raise exception 'PAYMENT_REPORT_REQUIRED';
    end if;
    if new.status = 'cancelled' and old.remittance_reported_at is not null then
      raise exception 'PAYMENT_REPORT_PENDING';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists figurine_payment_transition on public.orders;
create trigger figurine_payment_transition before update of status on public.orders
for each row execute function public.guard_figurine_payment_transition();

revoke all on function public.figurine_bank_for_checkout(), public.admin_figurine_bank(jsonb),
  public.report_figurine_remittance(text, uuid, text, timestamptz),
  public.admin_return_figurine_remittance(uuid, timestamptz), public.guard_figurine_payment_transition()
  from public, anon, authenticated;
grant execute on function public.figurine_bank_for_checkout(),
  public.report_figurine_remittance(text, uuid, text, timestamptz) to service_role;
grant execute on function public.admin_figurine_bank(jsonb),
  public.admin_return_figurine_remittance(uuid, timestamptz) to authenticated;

create or replace function public.list_line_figurine_orders(p_line_user_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', shop_order.id,
    'created_at', shop_order.created_at,
    'status', shop_order.status,
    'remittance_reported', shop_order.remittance_reported_at is not null,
    'total_ntd', shop_order.shipping_fee_ntd + details.subtotal,
    'items', details.items
  ) order by shop_order.created_at desc, shop_order.id desc), '[]'::jsonb)
  from (
    select id, created_at, status, shipping_fee_ntd, remittance_reported_at from public.orders
    where line_user_id = p_line_user_id
    order by created_at desc, id desc
    limit 50
  ) as shop_order
  cross join lateral (
    select coalesce(sum(i.unit_price_ntd::bigint * i.quantity), 0) as subtotal,
      coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity)
        order by i.product_sku), '[]'::jsonb) as items
    from public.order_items as i where i.order_id = shop_order.id
  ) as details;
$function$;

create or replace function public.admin_confirm_figurine_remittance(p_order_id uuid, p_reported_at timestamptz)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_figurine_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;
  update public.orders set status = 'paid'
  where id = p_order_id and status = 'pending_payment' and remittance_reported_at = p_reported_at;
  if not found then raise exception 'REPORT_CHANGED'; end if;
end;
$$;
revoke all on function public.admin_confirm_figurine_remittance(uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function public.admin_confirm_figurine_remittance(uuid, timestamptz) to authenticated;

commit;
