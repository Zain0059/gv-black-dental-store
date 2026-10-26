-- Phase 1 security hardening. Apply after supabase/schema.sql.
begin;

-- New Auth users remain pending until an active owner assigns an approved role.
alter table public.profiles alter column role drop not null;
alter table public.profiles alter column role drop default;
alter table public.profiles alter column active set default false;

create or replace function public.is_finite_numeric(p_value numeric)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_value is not null
     and p_value::text not in ('NaN', 'Infinity', '-Infinity');
$$;
revoke all on function public.is_finite_numeric(numeric) from public, anon;
grant execute on function public.is_finite_numeric(numeric) to authenticated;

create or replace function public.has_any_role(allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles as p
    where p.id = auth.uid()
      and p.active is true
      and p.role = any(allowed_roles)
  );
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(id, display_name, role, active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email, ''),
    null,
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.approve_store_user(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
     or not public.has_any_role(array['owner']::text[]) then
    raise exception 'Only an active owner may approve users';
  end if;
  if p_role is null or p_role not in ('manager','sales','inventory','accountant') then
    raise exception 'Invalid approval role';
  end if;
  update public.profiles
  set role = p_role, active = true
  where id = p_user_id and role is null and active is false;
  if not found then
    raise exception 'User is not pending approval';
  end if;
end;
$$;
revoke all on function public.approve_store_user(uuid,text) from public, anon;
grant execute on function public.approve_store_user(uuid,text) to authenticated;

-- Finite constraints also protect direct table writes and future RPCs.
alter table public.products add constraint products_unit_price_finite
  check (public.is_finite_numeric(unit_price) and unit_price >= 0);
alter table public.products add constraint products_stock_qty_finite
  check (public.is_finite_numeric(stock_qty) and stock_qty >= 0);
alter table public.customers add constraint customers_opening_balance_finite
  check (public.is_finite_numeric(opening_balance) and opening_balance >= 0);
alter table public.invoices add constraint invoices_total_finite
  check (public.is_finite_numeric(total) and total >= 0);
alter table public.invoice_items add constraint invoice_items_quantity_finite_positive
  check (public.is_finite_numeric(quantity) and quantity > 0);
alter table public.invoice_items add constraint invoice_items_unit_price_finite
  check (public.is_finite_numeric(unit_price) and unit_price >= 0);
alter table public.invoice_items add constraint invoice_items_line_total_finite
  check (public.is_finite_numeric(line_total) and line_total >= 0);
alter table public.payments add constraint payments_amount_finite_positive
  check (public.is_finite_numeric(amount) and amount > 0);
alter table public.stock_movements add constraint stock_movements_quantity_delta_finite_nonzero
  check (public.is_finite_numeric(quantity_delta) and quantity_delta <> 0);

create or replace function public.adjust_stock(
  p_product_id uuid, p_delta numeric, p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_product public.products%rowtype;
  v_movement_id uuid;
begin
  if auth.uid() is null or not public.has_any_role(array['owner','manager','inventory']::text[]) then
    raise exception 'Not authorized to adjust stock';
  end if;
  if not public.is_finite_numeric(p_delta) or p_delta = 0
     or nullif(pg_catalog.btrim(p_reason), '') is null then
    raise exception 'A finite non-zero quantity and reason are required';
  end if;
  select * into v_product from public.products where id = p_product_id for update;
  if not found then raise exception 'Product is unavailable'; end if;
  if v_product.stock_qty + p_delta < 0 then raise exception 'Stock cannot become negative'; end if;
  update public.products set stock_qty = stock_qty + p_delta, updated_at = pg_catalog.now()
  where id = p_product_id;
  insert into public.stock_movements(product_id, created_by, quantity_delta, reason)
  values (p_product_id, auth.uid(), p_delta, pg_catalog.btrim(p_reason))
  returning id into v_movement_id;
  return v_movement_id;
end;
$$;

create or replace function public.create_sale(
  p_customer_id uuid, p_items jsonb, p_paid numeric default 0, p_method text default 'cash'
)
returns uuid
language plpgsql
security definer
set search_path = ''
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
  if auth.uid() is null or not public.has_any_role(array['owner','manager','sales']::text[]) then
    raise exception 'Not authorized to create sales';
  end if;
  if p_customer_id is null or p_items is null
     or pg_catalog.jsonb_typeof(p_items) is distinct from 'array'
     or pg_catalog.jsonb_array_length(p_items) = 0 then
    raise exception 'Customer and at least one invoice item are required';
  end if;
  if p_paid is not null and (not public.is_finite_numeric(p_paid) or p_paid < 0) then
    raise exception 'Payment must be finite and non-negative';
  end if;
  if coalesce(p_method,'') not in ('cash','bank_transfer','card','wallet') then
    raise exception 'Invalid payment method';
  end if;
  if exists (
    select 1 from pg_catalog.jsonb_to_recordset(p_items) as x(product_id uuid, quantity numeric)
    group by x.product_id having pg_catalog.count(*) > 1
  ) then raise exception 'Each product may appear only once per sale'; end if;
  if exists (
    select 1 from pg_catalog.jsonb_to_recordset(p_items) as x(product_id uuid, quantity numeric)
    where not public.is_finite_numeric(x.quantity) or x.quantity <= 0
  ) then raise exception 'Quantity must be finite and positive'; end if;

  perform 1 from public.customers where id = p_customer_id and active for key share;
  if not found then raise exception 'Customer is unavailable'; end if;

  v_invoice_no := 'INV-' || pg_catalog.to_char(pg_catalog.now(), 'YYYY') || '-' ||
    pg_catalog.lpad(pg_catalog.nextval('public.invoice_number_seq')::text, 6, '0');
  insert into public.invoices(invoice_no, customer_id, created_by, total)
  values (v_invoice_no, p_customer_id, auth.uid(), 0)
  returning id into v_invoice_id;

  for v_item in
    select x.product_id, x.quantity
    from pg_catalog.jsonb_to_recordset(p_items) as x(product_id uuid, quantity numeric)
    order by x.product_id
  loop
    v_quantity := v_item.quantity;
    select * into v_product from public.products
    where id = v_item.product_id and active for update;
    if not found then raise exception 'Product is unavailable'; end if;
    if v_product.stock_qty < v_quantity then raise exception 'Insufficient stock for %', v_product.sku; end if;
    v_line_total := pg_catalog.round(v_quantity * v_product.unit_price, 2);
    v_total := v_total + v_line_total;
    insert into public.invoice_items(invoice_id, product_id, sku_snapshot, name_snapshot, quantity, unit_price)
    values (v_invoice_id, v_product.id, v_product.sku, v_product.name, v_quantity, v_product.unit_price);
    update public.products set stock_qty = stock_qty - v_quantity, updated_at = pg_catalog.now()
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
  p_invoice_id uuid, p_amount numeric, p_method text default 'cash'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invoice public.invoices%rowtype;
  v_paid numeric(12,2);
  v_payment_id uuid;
begin
  if auth.uid() is null or not public.has_any_role(array['owner','manager','sales','accountant']::text[]) then
    raise exception 'Not authorized to record payments';
  end if;
  if not public.is_finite_numeric(p_amount) or p_amount <= 0 then
    raise exception 'Payment must be finite and positive';
  end if;
  if coalesce(p_method,'') not in ('cash','bank_transfer','card','wallet') then
    raise exception 'Invalid payment method';
  end if;
  select * into v_invoice from public.invoices where id = p_invoice_id and status = 'issued' for update;
  if not found then raise exception 'Invoice is unavailable'; end if;
  select coalesce(sum(amount),0) into v_paid from public.payments where invoice_id = p_invoice_id;
  if v_paid + p_amount > v_invoice.total then raise exception 'Payment exceeds remaining balance'; end if;
  insert into public.payments(invoice_id, received_by, amount, method)
  values (v_invoice.id, auth.uid(), p_amount, p_method)
  returning id into v_payment_id;
  return v_payment_id;
end;
$$;

-- Opening balance is privileged even when a role can otherwise manage customers.
create or replace function public.guard_customer_balance_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('postgres','supabase_admin','service_role') then return new; end if;
  if tg_op = 'INSERT' then
    if new.opening_balance <> 0
       and not public.has_any_role(array['owner','accountant']::text[]) then
      raise exception 'Only owner or accountant may set opening balance';
    end if;
    if not public.has_any_role(array['owner','manager','sales']::text[]) then
      raise exception 'Not authorized to create customers';
    end if;
  elsif tg_op = 'UPDATE' then
    if public.has_any_role(array['accountant']::text[])
       and not public.has_any_role(array['owner']::text[])
       and (new.name is distinct from old.name
         or new.phone is distinct from old.phone
         or new.email is distinct from old.email
         or new.address is distinct from old.address
         or new.active is distinct from old.active) then
      raise exception 'Accountant may only edit opening balance';
    end if;
    if new.opening_balance is distinct from old.opening_balance
       and not public.has_any_role(array['owner','accountant']::text[]) then
      raise exception 'Only owner or accountant may edit opening balance';
    end if;
    if not public.has_any_role(array['owner','manager','sales']::text[]) then
      raise exception 'Not authorized to edit customers';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_customer_balance_write() from public, anon, authenticated;
drop trigger if exists guard_customer_balance_write on public.customers;
create trigger guard_customer_balance_write
before insert or update on public.customers
for each row execute function public.guard_customer_balance_write();

-- Inactive users cannot even read their own profile row.
drop policy if exists "profile read" on public.profiles;
create policy "profile read" on public.profiles for select to authenticated
using (
  (id = auth.uid() and active is true)
  or public.has_any_role(array['owner','manager']::text[])
);

-- Replace broad authenticated reads with active role-scoped policies.
drop policy if exists "products read" on public.products;
create policy "products read" on public.products for select to authenticated
using (public.has_any_role(array['owner','manager','sales','inventory','accountant']::text[]));
drop policy if exists "customers read" on public.customers;
create policy "customers read" on public.customers for select to authenticated
using (public.has_any_role(array['owner','manager','sales','accountant']::text[]));
drop policy if exists "invoices read" on public.invoices;
create policy "invoices read" on public.invoices for select to authenticated
using (public.has_any_role(array['owner','manager','sales','accountant']::text[]));
drop policy if exists "invoice items read" on public.invoice_items;
create policy "invoice items read" on public.invoice_items for select to authenticated
using (public.has_any_role(array['owner','manager','sales','accountant']::text[]));
drop policy if exists "payments read" on public.payments;
create policy "payments read" on public.payments for select to authenticated
using (public.has_any_role(array['owner','manager','accountant']::text[]));
drop policy if exists "stock movements read" on public.stock_movements;
create policy "stock movements read" on public.stock_movements for select to authenticated
using (public.has_any_role(array['owner','manager','inventory','accountant']::text[]));

drop policy if exists "customers write" on public.customers;
create policy "customers insert" on public.customers for insert to authenticated
with check (public.has_any_role(array['owner','manager','sales']::text[]));
create policy "customers update" on public.customers for update to authenticated
using (public.has_any_role(array['owner','manager','sales','accountant']::text[]))
with check (public.has_any_role(array['owner','manager','sales','accountant']::text[]));

-- Ensure existing security-definer functions all use a pinned empty search_path.
-- has_any_role, handle_new_user and the RPCs above are replaced in this migration.
revoke all on function public.has_any_role(text[]) from public, anon;
revoke all on function public.handle_new_user() from public, anon;
revoke all on function public.create_sale(uuid,jsonb,numeric,text) from public, anon;
revoke all on function public.record_payment(uuid,numeric,text) from public, anon;
revoke all on function public.adjust_stock(uuid,numeric,text) from public, anon;
grant execute on function public.has_any_role(text[]) to authenticated;
grant execute on function public.create_sale(uuid,jsonb,numeric,text) to authenticated;
grant execute on function public.record_payment(uuid,numeric,text) to authenticated;
grant execute on function public.adjust_stock(uuid,numeric,text) to authenticated;

commit;
