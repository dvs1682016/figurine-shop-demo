-- V1.12：LINE 身分綁定與我的訂單。依賴既有下單函式。
begin;

alter table public.orders add column if not exists line_user_id text;
create index if not exists figurine_orders_line_user_created_idx
  on public.orders (line_user_id, created_at desc, id desc)
  where line_user_id is not null;

create or replace function public.place_line_figurine_order(
  p_line_user_id text,
  p_order jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_id uuid := (p_order ->> 'p_request_id')::uuid;
  v_owner text;
  v_result jsonb;
begin
  if p_line_user_id is null or p_line_user_id !~ '^U[0-9a-f]{32}$' or v_id is null then
    raise exception 'INVALID_ORDER';
  end if;

  -- 既有下單函式使用同一把鎖，防止與舊入口同時使用同一筆請求編號。
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_id::text, 0));
  select line_user_id into v_owner from public.orders where id = v_id;
  if found and v_owner is distinct from p_line_user_id then
    raise exception 'REQUEST_CONFLICT';
  end if;

  v_result := public.place_figurine_order(
    v_id,
    p_order ->> 'p_sku',
    (p_order ->> 'p_quantity')::integer,
    (p_order ->> 'p_expected_price_ntd')::integer,
    p_order ->> 'p_name',
    p_order ->> 'p_phone',
    p_order ->> 'p_address'
  );

  update public.orders set line_user_id = p_line_user_id
  where id = v_id and line_user_id is null;
  return v_result;
end;
$function$;

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
    'total_ntd', shop_order.shipping_fee_ntd + details.subtotal,
    'items', details.items
  ) order by shop_order.created_at desc, shop_order.id desc), '[]'::jsonb)
  from (
    select id, created_at, status, shipping_fee_ntd from public.orders
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

revoke all on function public.place_line_figurine_order(text, jsonb)
  from public, anon, authenticated;
revoke all on function public.list_line_figurine_orders(text)
  from public, anon, authenticated;
grant execute on function public.place_line_figurine_order(text, jsonb),
  public.list_line_figurine_orders(text) to service_role;

commit;
