# Supabase setup

The browser app uses Supabase Auth and the Supabase JavaScript client. The project URL and publishable key are configured in `supabase-config.js`.

## One-time project setup

1. In Supabase, open **Authentication → Sign In / Providers → User Signups** (the exact label can vary by dashboard version) and turn off **Allow new users to sign up**. Keep this disabled so only invited accounts can enter the approval flow.
2. Run `supabase/schema.sql` in the Supabase SQL Editor.
3. Apply the newest migration in `supabase/migrations/` (the role and numeric hardening migration) after the schema. With the Supabase CLI, link the project and run `supabase db push`; alternatively paste the migration SQL into the SQL Editor.
4. In **Authentication → Users**, invite the store owner by email and have them sign in once. The trigger creates the profile as pending (`role = NULL`, `active = false`).
5. Bootstrap the first owner from the SQL Editor using the UUID shown for that Auth user:
   ```sql
   update public.profiles
   set role = 'owner', active = true
   where id = '<auth user uuid>';
   ```
   Run this only for the trusted first owner.
6. Invite each staff member through **Authentication → Users**. A new profile stays inactive and cannot read store data until approval.
7. Approve staff accounts only after verifying the person and assigning the least-privileged suitable role. The supported roles are `manager`, `sales`, `inventory`, and `accountant`. The owner approval RPC is:
   ```js
   await supabase.rpc('approve_store_user', {
     p_user_id: '<auth user uuid>',
     p_role: 'sales'
   });
   ```
   This RPC must be called from an authenticated session belonging to an active owner. The app currently has no approval screen. Until one is added, an administrator can approve a verified invitation in the SQL Editor:
   ```sql
   update public.profiles
   set role = 'sales', active = true
   where id = '<auth user uuid>' and role is null and active = false;
   ```
   Replace `sales` with the approved role. Do not enable public signups as a substitute for invitations.
8. Open the store and sign in with the invited account's email and password.

## Cloud behavior

- Products, customers, issued invoices, invoice items, payments, and stock load from Supabase after sign-in, subject to role and active-status policies.
- Sales use the `create_sale` database function, which creates invoice lines, records the payment, and deducts stock atomically.
- Additional payments use `record_payment`; stock changes use `adjust_stock`. Product deletion is a soft archive so past invoices remain intact.
- Only owners and accountants may set or change customer opening balances. Sales may create customers with a zero opening balance.
- Signing out returns to the browser's previous local data. Local data is not uploaded automatically; import it only after reviewing what it contains.
- Bulk GTIN import remains available in local mode. While connected, assign GTIN codes one at a time through the scanner so each change is written to Supabase.

## Database tests

Run `supabase test db` against the configured local Supabase stack to execute `supabase/tests/rls.sql`. The tests cover role-scoped reads, pending users, opening-balance permissions, stock RPC access, and rejection of non-finite values.

## Security

- The configured `publishable` key is designed for browser apps. It is safe to expose only with Row Level Security enabled and policies in place.
- Never put a `secret` or legacy `service_role` key in client code or commit one to GitHub. If a secret key was shared, rotate it in Supabase.
- Invited accounts remain blocked until an owner approves and activates their profile.
- This schema is for one store. It does not yet include multi-branch access or invoice void/return workflows.
