-- G.V. Black Dental Store: Supabase schema
-- Run in the Supabase SQL Editor. Never add a service_role key to the browser app.

create sequence if not exists public.invoice_number_seq;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  role text not null default 'sales' check (role in ('owner','manager','sales','inventory','accountant')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  name text not null,
  manufacturer text not null default '',
  gtin text unique,
  unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  stock_qty numeric(12,3) not null default 0 check (stock_qty >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (gtin is null or gtin ~ '^[0-9]{8}([0-9]{4,6})?$')
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text not null default '',
  email text not null default '',
  address text not null default '',
  opening_balance numeric(12,2) not null default 0 check (opening_balance >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_no text not null unique,
  customer_id uuid not null references public.customers(id),
  created_by uuid not null references public.profiles(id),
  status text not null default 'issued' check (status in ('issued','void')),
  total numeric(12,2) not null default 0 check (total >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  product_id uuid not null references public.products(id),
  sku_snapshot text not null,
  name_snapshot text not null,
  quantity numeric(12,3) not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(12,2) generated always as (round(quantity * unit_price, 2)) stored
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id),
  received_by uuid not null references public.profiles(id),
  amount numeric(12,2) not null check (amount > 0),
  method text not null default 'cash' check (method in ('cash','bank_transfer','card','wallet')),
  received_at timestamptz not null default now()
);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  created_by uuid not null references public.profiles(id),
  quantity_delta numeric(12,3) not null check (quantity_delta <> 0),
  reason text not null,
  invoice_id uuid references public.invoices(id),
  created_at timestamptz not null default now()
);

create or replace function public.has_any_role(allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active and p.role = any(allowed_roles)
  );
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $
begin
  insert into public.profiles(id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email, ''))
  on conflict (id) do nothing;
  return new;
end;
$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.adjust_stock(
  p_product_id uuid,
  p_delta numeric,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $
declare
  v_product public.products%rowtype;
  v_movement_id uuid;
begin
  if auth.uid() is null or not public.has_any_role(array['owner','manager','inventory']) then
    raise exception 'Not authorized to adjust stock';
  end if;
  if p_delta is null or p_delta = 0 or nullif(trim(p_reason), '') is null then
    raise exception 'A non-zero quantity and reason are required';
  end if;
  select * into v_product from public.products where id = p_product_id for update;
  if not found then raise exception 'Product is unavailable'; end if;
  if v_product.stock_qty + p_delta < 0 then raise exception 'Stock cannot become negative'; end if;
  update public.products set stock_qty = stock_qty + p_delta, updated_at = now()
  where id = p_product_id;
  insert into public.stock_movements(product_id, created_by, quantity_delta, reason)
  values (p_product_id, auth.uid(), p_delta, trim(p_reason))
  returning id into v_movement_id;
  return v_movement_id;
end;
$;

create or replace function public.create_sale(
  p_customer_id uuid,
  p_items jsonb,
  p_paid numeric default 0,
  p_method text default 'cash'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invoice_id uuid;
  v_invoice_no text;
  v_item record;
  v_product public.products%rowtype;
  v_total numeric(12,2) := 0;
  v_line_total numeric(12,2);
  v_quantity numeric(12,3);
begin
  if auth.uid() is null or not public.has_any_role(array['owner','manager','sales']) then
    raise exception 'Not authorized to create sales';
  end if;
  if p_customer_id is null or p_items is null or jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Customer and at least one invoice item are required';
  end if;
  if coalesce(p_paid, 0) < 0 then raise exception 'Payment cannot be negative'; end if;
  if coalesce(p_method,'') not in ('cash','bank_transfer','card','wallet') then raise exception 'Invalid payment method'; end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) as x(product_id uuid, quantity numeric)
    group by x.product_id having count(*) > 1
  ) then raise exception 'Each product may appear only once per sale'; end if;

  perform 1 from public.customers where id = p_customer_id and active for key share;
  if not found then raise exception 'Customer is unavailable'; end if;

  v_invoice_no := 'INV-' || to_char(now(), 'YYYY') || '-' ||
    lpad(nextval('public.invoice_number_seq')::text, 6, '0');
  insert into public.invoices(invoice_no, customer_id, created_by, total)
  values (v_invoice_no, p_customer_id, auth.uid(), 0)
  returning id into v_invoice_id;

  for v_item in
    select x.product_id, x.quantity
    from jsonb_to_recordset(p_items) as x(product_id uuid, quantity numeric)
    order by x.product_id
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then raise exception 'Quantity must be positive'; end if;
    v_quantity := v_item.quantity;
    select * into v_product from public.products
    where id = v_item.product_id and active
    for update;
    if not found then raise exception 'Product is unavailable'; end if;
    if v_product.stock_qty < v_quantity then raise exception 'Insufficient stock for %', v_product.sku; end if;
    v_line_total := round(v_quantity * v_product.unit_price, 2);
    v_total := v_total + v_line_total;
    insert into public.invoice_items(invoice_id, product_id, sku_snapshot, name_snapshot, quantity, unit_price)
    values (v_invoice_id, v_product.id, v_product.sku, v_product.name, v_quantity, v_product.unit_price);
    update public.products set stock_qty = stock_qty - v_quantity, updated_at = now()
    where id = v_product.id;
    insert into public.stock_movements(product_id, created_by, quantity_delta, reason, invoice_id)
    values (v_product.id, auth.uid(), -v_quantity, 'sale', v_invoice_id);
  end loop;

  if coalesce(p_paid, 0) > v_total then raise exception 'Payment exceeds invoice total'; end if;
  update public.invoices set total = v_total where id = v_invoice_id;
  if coalesce(p_paid, 0) > 0 then
    insert into public.payments(invoice_id, received_by, amount, method)
    values (v_invoice_id, auth.uid(), p_paid, p_method);
  end if;
  return v_invoice_id;
end;
$$;

create or replace function public.record_payment(
  p_invoice_id uuid,
  p_amount numeric,
  p_method text default 'cash'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invoice public.invoices%rowtype;
  v_paid numeric(12,2);
  v_payment_id uuid;
begin
  if auth.uid() is null or not public.has_any_role(array['owner','manager','sales','accountant']) then
    raise exception 'Not authorized to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment must be positive'; end if;
  if p_method not in ('cash','bank_transfer','card','wallet') then raise exception 'Invalid payment method'; end if;
  select * into v_invoice from public.invoices where id = p_invoice_id and status = 'issued' for update;
  if not found then raise exception 'Invoice is unavailable'; end if;
  select coalesce(sum(amount),0) into v_paid from public.payments where invoice_id = p_invoice_id;
  if v_paid + p_amount > v_invoice.total then raise exception 'Payment exceeds remaining balance'; end if;
  insert into public.payments(invoice_id, received_by, amount, method)
  values (p_invoice_id, auth.uid(), p_amount, p_method)
  returning id into v_payment_id;
  return v_payment_id;
end;
$$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.customers enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;
alter table public.stock_movements enable row level security;

drop policy if exists "profile read" on public.profiles;
create policy "profile read" on public.profiles for select to authenticated
using (id = auth.uid() or public.has_any_role(array['owner','manager']));
drop policy if exists "products read" on public.products;
create policy "products read" on public.products for select to authenticated using (true);
drop policy if exists "products write" on public.products;
create policy "products write" on public.products for all to authenticated
using (public.has_any_role(array['owner','manager','inventory']))
with check (public.has_any_role(array['owner','manager','inventory']));
drop policy if exists "customers read" on public.customers;
create policy "customers read" on public.customers for select to authenticated using (true);
drop policy if exists "customers write" on public.customers;
create policy "customers write" on public.customers for all to authenticated
using (public.has_any_role(array['owner','manager','sales']))
with check (public.has_any_role(array['owner','manager','sales']));
drop policy if exists "invoices read" on public.invoices;
create policy "invoices read" on public.invoices for select to authenticated using (true);
drop policy if exists "invoice items read" on public.invoice_items;
create policy "invoice items read" on public.invoice_items for select to authenticated using (true);
drop policy if exists "payments read" on public.payments;
create policy "payments read" on public.payments for select to authenticated using (true);
drop policy if exists "stock movements read" on public.stock_movements;
create policy "stock movements read" on public.stock_movements for select to authenticated
using (public.has_any_role(array['owner','manager','inventory','accountant']));

revoke all on function public.create_sale(uuid,jsonb,numeric,text) from public, anon;
revoke all on function public.record_payment(uuid,numeric,text) from public, anon;\nrevoke all on function public.adjust_stock(uuid,numeric,text) from public, anon;
grant execute on function public.create_sale(uuid,jsonb,numeric,text) to authenticated;
grant execute on function public.record_payment(uuid,numeric,text) to authenticated;\ngrant execute on function public.adjust_stock(uuid,numeric,text) to authenticated;
grant execute on function public.has_any_role(text[]) to authenticated;
grant select on public.profiles, public.products, public.customers, public.invoices,
  public.invoice_items, public.payments, public.stock_movements to authenticated;
grant insert on public.products, public.customers to authenticated;\ngrant update (sku, name, manufacturer, gtin, unit_price, active) on public.products to authenticated;\ngrant update on public.customers to authenticated;

-- Create the first owner by promoting their profile after they sign in:
-- update public.profiles set role = 'owner' where id = '<auth user uuid>';
