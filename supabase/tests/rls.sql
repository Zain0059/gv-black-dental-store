-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(20);

-- Auth trigger creates a pending profile; fixtures promote only the test identities.
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
 ('10000000-0000-4000-8000-000000000001','authenticated','authenticated','owner-test@example.test','',now(),'{}','{}',now(),now()),
 ('10000000-0000-4000-8000-000000000002','authenticated','authenticated','sales-test@example.test','',now(),'{}','{}',now(),now()),
 ('10000000-0000-4000-8000-000000000003','authenticated','authenticated','accountant-test@example.test','',now(),'{}','{}',now(),now()),
 ('10000000-0000-4000-8000-000000000004','authenticated','authenticated','inactive-test@example.test','',now(),'{}','{}',now(),now()),
 ('10000000-0000-4000-8000-000000000005','authenticated','authenticated','pending-test@example.test','',now(),'{}','{}',now(),now());

select extensions.is(
  (select role from public.profiles where id='10000000-0000-4000-8000-000000000005'),
  null::text,
  'signup trigger leaves new profile without a role'
);
select extensions.is(
  (select active from public.profiles where id='10000000-0000-4000-8000-000000000005'),
  false,
  'signup trigger leaves new profile inactive'
);

update public.profiles set role='owner', active=true where id='10000000-0000-4000-8000-000000000001';
update public.profiles set role='sales', active=true where id='10000000-0000-4000-8000-000000000002';
update public.profiles set role='accountant', active=true where id='10000000-0000-4000-8000-000000000003';

insert into public.customers(id,name,opening_balance)
values ('20000000-0000-4000-8000-000000000001','RLS test customer',10);
insert into public.products(id,sku,name,unit_price,stock_qty)
values ('30000000-0000-4000-8000-000000000001','RLS-1','RLS test product',5,20);
insert into public.invoices(id,invoice_no,customer_id,created_by,total)
values ('40000000-0000-4000-8000-000000000001','RLS-TEST-1','20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',5);
insert into public.invoice_items(invoice_id,product_id,sku_snapshot,name_snapshot,quantity,unit_price)
values ('40000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','RLS-1','RLS test product',1,5);
insert into public.payments(invoice_id,received_by,amount)
values ('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',2);
insert into public.stock_movements(product_id,created_by,quantity_delta,reason)
values ('30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',1,'test');

set local role authenticated;
select pg_catalog.set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
select extensions.is((select count(*)::int from public.invoices),1,'sales can read invoices');
select extensions.is((select count(*)::int from public.invoice_items),1,'sales can read invoice items');
select extensions.is((select count(*)::int from public.customers),1,'sales can read customers');
select extensions.is((select count(*)::int from public.payments),0,'sales cannot read payments');
select extensions.throws_ok(
  $$update public.customers set opening_balance=11 where id='20000000-0000-4000-8000-000000000001'$$,
  'P0001',
  'Only owner or accountant may edit opening balance',
  'sales cannot edit opening balance'
);
select extensions.is(
 (select opening_balance from public.customers where id='20000000-0000-4000-8000-000000000001'),
 10::numeric,
 'rejected sales update leaves opening balance unchanged'
);
select extensions.throws_ok(
  $$select public.adjust_stock('30000000-0000-4000-8000-000000000001',1,'test')$$,
  'P0001',
  'Not authorized to adjust stock',
  'sales cannot call adjust_stock'
);
select extensions.throws_ok(
  $$select public.create_sale('20000000-0000-4000-8000-000000000001','[{"product_id":"30000000-0000-4000-8000-000000000001","quantity":"NaN"}]'::jsonb,0,'cash')$$,
  'P0001',
  'Quantity must be finite and positive',
  'create_sale rejects NaN quantity'
);
select extensions.throws_ok(
  $$select public.record_payment('40000000-0000-4000-8000-000000000001','Infinity'::numeric,'cash')$$,
  'P0001',
  'Payment must be finite and positive',
  'record_payment rejects Infinity'
);

select pg_catalog.set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
select extensions.is((select count(*)::int from public.payments),1,'accountant can read payments');
update public.customers set opening_balance=12 where id='20000000-0000-4000-8000-000000000001';
select extensions.is(
 (select opening_balance from public.customers where id='20000000-0000-4000-8000-000000000001'),
 12::numeric,
 'accountant can edit opening balance'
);

select pg_catalog.set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000004',true);
select extensions.is((select count(*)::int from public.profiles),0,'inactive user cannot read even their profile');
select extensions.is((select count(*)::int from public.products),0,'inactive user cannot read products');
select extensions.is((select count(*)::int from public.customers),0,'inactive user cannot read customers');
select extensions.is((select count(*)::int from public.invoices),0,'inactive user cannot read invoices');
select extensions.is((select count(*)::int from public.invoice_items),0,'inactive user cannot read invoice items');
select extensions.is((select count(*)::int from public.payments),0,'inactive user cannot read payments');
select extensions.is((select count(*)::int from public.stock_movements),0,'inactive user cannot read stock movements');

select * from extensions.finish();
rollback;
