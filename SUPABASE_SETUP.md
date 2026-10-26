# Supabase setup

This repository is a browser based prototype. The Supabase schema in `supabase/schema.sql` is the first backend foundation; it is not yet wired into the HTML app. The app currently continues to use browser-local data until the client integration is completed.

## Create the Supabase project

1. Create a Supabase project and open **SQL Editor**.
2. Run `supabase/schema.sql`.
3. In **Authentication → Users**, invite the store owner by email and have them sign in once. The database trigger creates a profile with the `sales` role.
4. Promote that profile to `owner` from the SQL Editor, using the user's UUID shown in Authentication:
   ```sql
   update public.profiles set role = 'owner' where id = '<auth user uuid>';
   ```
5. Invite staff through Supabase Auth. Assign each profile one of: `manager`, `sales`, `inventory`, or `accountant`.

## Security notes

- Use only the project's URL and publishable (anon) key in a browser client. Never use a `service_role` key in client code or commit it to GitHub.
- Row Level Security is enabled on all business tables. Sales and payments are written through database functions that check the signed-in user's role; a sale decrements stock and creates invoice lines, payment, and stock movement atomically.
- This first schema is for one store. It does not yet include multi-branch access, invoice void/return workflows, or historical import from localStorage.
- Product/customer management is role-limited. Existing local sample data is not automatically uploaded.

## Current integration status

The schema and setup steps are prepared on the development branch. The static HTML app still runs on localStorage. Completing cloud login and replacing local writes with Supabase calls requires the project's URL and publishable key, then a separate browser-client integration and data migration. No secret key is needed for that work.
