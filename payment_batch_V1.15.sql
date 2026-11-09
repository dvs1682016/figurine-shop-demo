-- 咚咚造物局 V1.15：從已驗收的 V1.14 升級，保留舊批次金額。
begin;

create table if not exists public.figurine_payment_batches (
  id uuid primary key,
  line_user_id text not null,
  order_ids uuid[] not null check (cardinality(order_ids) between 2 and 50),
  total_ntd bigint not null check (total_ntd > 0),
  last5 text not null check (last5 ~ '^[0-9]{5}$'),
  transferred_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending','confirmed','returned'))
);
alter table public.figurine_payment_batches
  add column if not exists combined_shipping boolean not null default false,
  add column if not exists batch_shipping_fee_ntd bigint,
  add column if not exists item_lines jsonb;
alter table public.figurine_payment_batches
  drop constraint if exists figurine_payment_batches_status_check;
alter table public.figurine_payment_batches
  add constraint figurine_payment_batches_status_check
  check (status in ('pending','confirmed','returned','shipped'));
alter table public.figurine_payment_batches enable row level security;
revoke all on public.figurine_payment_batches from public, anon, authenticated;
grant select on public.figurine_payment_batches to authenticated;
drop policy if exists figurine_batches_admin_read on public.figurine_payment_batches;
create policy figurine_batches_admin_read on public.figurine_payment_batches
  for select to authenticated using ((select public.is_figurine_admin()));

alter table public.orders add column if not exists payment_batch_id uuid
  references public.figurine_payment_batches(id);
create index if not exists orders_figurine_payment_batch_idx
  on public.orders(payment_batch_id) where payment_batch_id is not null;

-- 以訂單保存的成交單價補齊舊批次明細，原應收金額不變。
with historical as (
  select b.id,
    coalesce(jsonb_agg(jsonb_build_object('order_id', i.order_id, 'name', i.product_name,
      'quantity', i.quantity, 'unit_price_ntd', i.unit_price_ntd)
      order by i.order_id, i.product_sku) filter (where i.order_id is not null), '[]'::jsonb) as lines,
    coalesce(sum(i.unit_price_ntd::bigint * i.quantity), 0) as subtotal
  from public.figurine_payment_batches b
  left join public.order_items i on i.order_id = any(b.order_ids)
  where b.item_lines is null
  group by b.id
)
update public.figurine_payment_batches b
set item_lines = h.lines, batch_shipping_fee_ntd = b.total_ntd - h.subtotal
from historical h where h.id = b.id;

create or replace function public.report_figurine_payment_batch(
  p_line_user_id text, p_batch_id uuid, p_order_ids uuid[], p_expected_total bigint,
  p_last5 text, p_transferred_at timestamptz
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_ids uuid[];
  v_batch public.figurine_payment_batches%rowtype;
  v_total bigint;
  v_count integer;
  v_delivery_count integer;
  v_lines jsonb;
  v_shipping constant integer := 60;
begin
  if p_line_user_id is null or p_batch_id is null or p_order_ids is null
     or cardinality(p_order_ids) not between 2 and 50
     or p_expected_total is null or p_expected_total <= 0
     or p_last5 is null or p_last5 !~ '^[0-9]{5}$'
     or p_transferred_at is null or not isfinite(p_transferred_at)
     or p_transferred_at > now() + interval '5 minutes' then
    raise exception 'INVALID_BATCH';
  end if;
  select array_agg(distinct id order by id) into v_ids
  from unnest(p_order_ids) as incoming(id) where id is not null;
  if cardinality(v_ids) is distinct from cardinality(p_order_ids) then
    raise exception 'INVALID_BATCH';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('figurine-payment:' || p_batch_id::text, 0));
  select * into v_batch from public.figurine_payment_batches where id = p_batch_id;
  if found then
    if v_batch.line_user_id = p_line_user_id and v_batch.order_ids = v_ids
       and v_batch.total_ntd = p_expected_total and v_batch.last5 = p_last5
       and v_batch.transferred_at = p_transferred_at and v_batch.status <> 'returned' then
      return jsonb_build_object('reported', true, 'batch_id', p_batch_id);
    end if;
    raise exception 'BATCH_CONFLICT';
  end if;
  if not exists (select 1 from public.figurine_bank_settings where singleton) then
    raise exception 'BANK_NOT_CONFIGURED';
  end if;

  -- 固定順序鎖住訂單，防止同一筆訂單被兩個匯款回報同時使用。
  perform id from public.orders where id = any(v_ids) and line_user_id = p_line_user_id
  order by id for update;

  select count(*), count(distinct (btrim(o.customer_name), btrim(o.customer_phone), btrim(o.shipping_address)))
  into v_count, v_delivery_count
  from public.orders as o
  where o.id = any(v_ids) and o.line_user_id = p_line_user_id and o.status = 'pending_payment'
    and o.remittance_reported_at is null and o.payment_batch_id is null;
  if v_count <> cardinality(v_ids) then raise exception 'ORDER_NOT_PAYABLE'; end if;
  if v_delivery_count <> 1 then raise exception 'DELIVERY_MISMATCH'; end if;
  select coalesce(sum(i.unit_price_ntd::bigint * i.quantity), 0) + v_shipping,
    jsonb_agg(jsonb_build_object('order_id', i.order_id, 'name', i.product_name,
      'quantity', i.quantity, 'unit_price_ntd', i.unit_price_ntd)
      order by i.order_id, i.product_sku)
  into v_total, v_lines
  from public.order_items i where i.order_id = any(v_ids);
  if v_lines is null or v_total <> p_expected_total then raise exception 'TOTAL_CHANGED'; end if;

  insert into public.figurine_payment_batches
    (id, line_user_id, order_ids, total_ntd, last5, transferred_at,
      combined_shipping, batch_shipping_fee_ntd, item_lines)
  values (p_batch_id, p_line_user_id, v_ids, v_total, p_last5, p_transferred_at,
    true, v_shipping, v_lines);
  update public.orders set payment_batch_id = p_batch_id,
    remittance_last5 = p_last5, remittance_at = p_transferred_at, remittance_reported_at = now()
  where id = any(v_ids);
  return jsonb_build_object('reported', true, 'batch_id', p_batch_id);
end;
$$;

create or replace function public.admin_resolve_figurine_batch(p_batch_id uuid, p_confirm boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_batch public.figurine_payment_batches%rowtype;
  v_count integer;
  v_status text;
begin
  if not public.is_figurine_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;
  if p_confirm is null then raise exception 'BATCH_CONFLICT'; end if;
  v_status := case when p_confirm then 'confirmed' else 'returned' end;
  select * into v_batch from public.figurine_payment_batches where id = p_batch_id for update;
  if not found then raise exception 'BATCH_CONFLICT'; end if;
  if v_batch.status = v_status or (p_confirm and v_batch.status = 'shipped') then return; end if;
  if v_batch.status <> 'pending' then raise exception 'BATCH_CONFLICT'; end if;
  perform id from public.orders where payment_batch_id = p_batch_id order by id for update;
  update public.figurine_payment_batches set status = v_status where id = p_batch_id;
  if p_confirm then
    update public.orders set status = 'paid'
    where payment_batch_id = p_batch_id and id = any(v_batch.order_ids) and status = 'pending_payment';
  else
    update public.orders set payment_batch_id = null, remittance_last5 = null,
      remittance_at = null, remittance_reported_at = null
    where payment_batch_id = p_batch_id and id = any(v_batch.order_ids) and status = 'pending_payment';
  end if;
  get diagnostics v_count = row_count;
  if v_count <> cardinality(v_batch.order_ids) then raise exception 'BATCH_CONFLICT'; end if;
end;
$$;

-- 舊單筆後台也不能將合併回報拆開確認或退回。
create or replace function public.guard_figurine_batch_transition()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_status text;
  v_combined boolean;
begin
  if old.payment_batch_id is null then return new; end if;
  if old.status = 'paid' and new.status = 'shipped' then
    select status, combined_shipping into v_status, v_combined
    from public.figurine_payment_batches where id = old.payment_batch_id;
    if v_combined and v_status is distinct from 'shipped' then
      raise exception 'BATCH_SHIPMENT_REQUIRED';
    end if;
  end if;
  if (old.status = 'pending_payment' and new.status = 'paid')
     or (old.remittance_reported_at is not null and new.remittance_reported_at is null) then
    select status into v_status from public.figurine_payment_batches where id = old.payment_batch_id;
    if new.status = 'paid' and v_status is distinct from 'confirmed' then
      raise exception 'BATCH_REQUIRED';
    end if;
    if new.remittance_reported_at is null and v_status is distinct from 'returned' then
      raise exception 'BATCH_REQUIRED';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists figurine_batch_transition on public.orders;
create trigger figurine_batch_transition
before update of status, remittance_reported_at on public.orders
for each row execute function public.guard_figurine_batch_transition();

revoke all on function public.report_figurine_payment_batch(text,uuid,uuid[],bigint,text,timestamptz),
  public.admin_resolve_figurine_batch(uuid,boolean), public.guard_figurine_batch_transition()
  from public, anon, authenticated;
grant execute on function public.report_figurine_payment_batch(text,uuid,uuid[],bigint,text,timestamptz) to service_role;
grant execute on function public.admin_resolve_figurine_batch(uuid,boolean) to authenticated;

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
    'items', details.items,
    'subtotal_ntd', details.subtotal,
    'delivery_group', shop_order.delivery_group,
    'batch_id', batch.id,
    'batch_total_ntd', batch.total_ntd
  ) order by shop_order.created_at desc, shop_order.id desc), '[]'::jsonb)
  from (
    select id, created_at, status, shipping_fee_ntd, remittance_reported_at, payment_batch_id,
      dense_rank() over (order by btrim(customer_name), btrim(customer_phone), btrim(shipping_address)) as delivery_group
    from public.orders
    where line_user_id = p_line_user_id
    order by created_at desc, id desc
    limit 50
  ) as shop_order
  left join public.figurine_payment_batches batch on batch.id = shop_order.payment_batch_id
  cross join lateral (
    select coalesce(sum(i.unit_price_ntd::bigint * i.quantity), 0) as subtotal,
      coalesce(jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'unit_price_ntd', i.unit_price_ntd)
        order by i.product_sku), '[]'::jsonb) as items
    from public.order_items as i where i.order_id = shop_order.id
  ) as details;
$function$;

create or replace function public.admin_ship_figurine_batch(p_batch_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_batch public.figurine_payment_batches%rowtype;
  v_count integer;
begin
  if not public.is_figurine_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;
  select * into v_batch from public.figurine_payment_batches where id = p_batch_id for update;
  if not found or not v_batch.combined_shipping then raise exception 'BATCH_CONFLICT'; end if;
  if v_batch.status = 'shipped' then return; end if;
  if v_batch.status <> 'confirmed' then raise exception 'BATCH_CONFLICT'; end if;
  perform id from public.orders where payment_batch_id = p_batch_id order by id for update;
  update public.figurine_payment_batches set status = 'shipped' where id = p_batch_id;
  update public.orders set status = 'shipped'
  where payment_batch_id = p_batch_id and id = any(v_batch.order_ids) and status = 'paid';
  get diagnostics v_count = row_count;
  if v_count <> cardinality(v_batch.order_ids) then raise exception 'BATCH_CONFLICT'; end if;
end;
$$;
revoke all on function public.admin_ship_figurine_batch(uuid), public.list_line_figurine_orders(text)
  from public, anon, authenticated;
grant execute on function public.admin_ship_figurine_batch(uuid) to authenticated;
grant execute on function public.list_line_figurine_orders(text) to service_role;

commit;
