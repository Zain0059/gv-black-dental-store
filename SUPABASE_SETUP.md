# Supabase setup

The browser app now uses Supabase Auth and the Supabase JavaScript client to read and write store data. The publishable project URL and key are configured in `supabase-config.js`.

## One-time project setup

1. Run `supabase/schema.sql` in the Supabase SQL Editor. It creates the store tables, row-level security policies, and database functions.
2. In **Authentication → Users**, invite the store owner by email and have them sign in once. The database trigger creates a profile with the `sales` role.
3. Promote the first owner from the SQL Editor, using the user's UUID shown in Authentication:
   ```sql
   update public.profiles set role = 'owner' where id = '<auth user uuid>';
   ```
4. Invite staff through Supabase Auth. Assign each profile one of: `manager`, `sales`, `inventory`, or `accountant`.
5. Open the store and use **دخول سحابي** with the invited account's email and password.

## Cloud behavior

- Products, customers, issued invoices, invoice items, payments, and stock load from Supabase after sign-in.
- Sales use the `create_sale` database function, which creates invoice lines, records the payment, and deducts stock atomically.
- Additional payments use `record_payment`; stock changes use `adjust_stock`. Product deletion is a soft archive so past invoices remain intact.
- Signing out returns to the browser's previous local data. Local data is not uploaded automatically; import it only after reviewing what it contains.
- Bulk GTIN import remains available in local mode. While connected, assign GTIN codes one at a time through the scanner so each change is written to Supabase.
- Product/customer creation and other writes are enforced by the schema's role checks and Row Level Security.

## Security

- The configured `publishable` key is designed for browser apps. It is safe to expose only with Row Level Security enabled and policies in place.
- Never put a `secret` or legacy `service_role` key in client code or commit one to GitHub.
- Sign-in uses invited Supabase Auth accounts; the browser does not create new staff accounts.
- This schema is for one store. It does not yet include multi-branch access or invoice void/return workflows.
