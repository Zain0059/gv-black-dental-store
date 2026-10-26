# Phase 0 Security Audit

**Scope:** read-only audit of `main` at commit `22621216cde141cbbbc292ed2d420960dde86784`, dated 2026-10-27.

**Files reviewed:** `supabase/schema.sql`, `supabase-client.js`, and `supabase-config.js`. No SQL was run against the live Supabase project. No application or schema code was changed in this phase.

## Findings

### P1 — Authenticated users can read all customer and financial records

RLS is enabled on all seven tables (`profiles`, `products`, `customers`, `invoices`, `invoice_items`, `payments`, and `stock_movements`; `schema.sql:276-282`). The read policies on products, customers, invoices, invoice items, and payments grant access to every `authenticated` identity with `using (true)` (`schema.sql:288, 294, 300, 302, 304`). The table-level SELECT grants also cover all authenticated users (`schema.sql:318-319`).

As a result, a sales user can read every customer's contact and balance data, all invoices and line items, and all payments. Inventory users can also read payments. The policies do not require an active `profiles` record, so an authenticated but inactive or unprofiled user can query these tables directly. The check in `supabase-client.js:9` is only a UI/client check; it is not an RLS boundary. Supabase documents RLS policies as the database enforcement layer: [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security).

**Recommended migration:** replace broad read policies with active-profile and role checks, then define which roles may see customer, invoice, and payment data.

### P1 — A public signup would create an active sales account

The profile schema defaults new profiles to `role = 'sales'` and `active = true` (`schema.sql:9-10`). The `handle_new_user` trigger inserts only the user's ID and display name, so those defaults apply to every new Auth user (`schema.sql:120-130`).

The repository cannot show whether public signup is disabled in the live Supabase project's Auth settings. Verify **Authentication → General Configuration → Allow new users to sign up** and turn it off if staff must be invited. Supabase documents that this setting controls whether new users can sign up: [Auth general configuration](https://supabase.com/docs/guides/auth/general-configuration).

**Recommended migration:** make newly created profiles inactive until an owner approves them, and make the relevant RLS read policies require an active profile. Disabling signup alone does not protect access for previously created or later deactivated accounts.

### P1 — Numeric NaN can evade quantity and stock checks

`create_sale` reads quantities from caller-supplied JSON as PostgreSQL `numeric` values and rejects only null or values `<= 0` (`schema.sql:213-222`). `adjust_stock` rejects zero deltas and negative resulting stock, but does not reject NaN (`schema.sql:156-164`). PostgreSQL treats numeric NaN as greater than ordinary numeric values, so these comparisons and the table checks such as `quantity > 0` and `stock_qty >= 0` do not reliably reject it. This could allow an invalid quantity to reach invoice totals and stock updates. PostgreSQL documents its numeric special values and NaN comparison behavior: [Numeric types](https://www.postgresql.org/docs/current/datatype-numeric.html).

**Recommended migration and test:** explicitly reject NaN for sale quantities and stock deltas, and add database tests proving NaN is rejected without changing stock or creating invoice/payment rows. Also test non-finite values on payment inputs.

### P2 — Sales can update customer opening balances directly

The customer write policy allows `owner`, `manager`, and `sales` (`schema.sql:296-298`). The SQL grants `INSERT, UPDATE` on every customer column to all authenticated users (`schema.sql:321`). Therefore, a sales user can change `opening_balance`, `active`, and customer contact fields through the Data API, even though the current UI does not expose those edit controls.

**Recommended migration:** restrict the role's writable columns or route balance changes through an audited owner/manager operation.

### P2 — SECURITY DEFINER functions use a broader pinned search path

The role helper, user trigger, and three business RPCs are `SECURITY DEFINER` and pin `search_path` to `public, pg_temp` (`schema.sql:111-124, 141-147, 171-180, 245-253`). The path is fixed rather than caller-controlled, and table references in these functions are schema-qualified, so this review did not establish an exploit. Supabase recommends an empty search path for definer functions with fully qualified references: [Database functions](https://supabase.com/docs/guides/database/functions).

**Recommended migration:** set these functions to an empty search path and keep every database object reference schema-qualified.

## RPC and role review

- `adjust_stock`: requires an active `owner`, `manager`, or `inventory` profile; rejects zero deltas and empty reasons; locks the product row; prevents ordinary negative stock; and writes a stock movement (`schema.sql:153-168`).
- `create_sale`: requires an active `owner`, `manager`, or `sales` profile; validates the customer, item array, duplicate products, positive quantities, payment method, and payment not exceeding the computed total. It locks product rows in product-ID order, checks available stock, and writes invoice lines, payments, and stock movements in one database function (`schema.sql:191-242`). The NaN case above remains an input-validation gap.
- `record_payment`: requires an active `owner`, `manager`, `sales`, or `accountant` profile; validates positive amounts and allowed methods; locks the invoice row; and checks the accumulated amount against the invoice total (`schema.sql:258-274`).
- The RPCs revoke execution from `public` and `anon`, then grant it to `authenticated` (`schema.sql:311-317`). Direct writes to invoices, invoice items, payments, and stock movements are not granted to authenticated clients.
- Product writes are restricted to owner/manager. Customer writes include sales as described above. Product deletion is not granted directly; the client archives products by updating `active` (`supabase-client.js:24`).

## Secret scan

A pattern-based scan of the 37 commits reachable from `main` and the one additional commit on the diverged `codex/fix-supabase-schema-review` branch found no `sb_secret_` key, service-role key assignment, JWT-shaped credential, or database URL containing credentials. The current `supabase-config.js:4` contains a Supabase publishable key, which is intended for browser clients; it is the only key configured in that file. Supabase states that publishable keys can be used in client code when RLS is correctly configured: [API keys](https://supabase.com/docs/guides/getting-started/api-keys).

This is a source-history pattern scan, not a guarantee from GitHub Secret Scanning, and it does not cover secrets stored only in the live Supabase dashboard. The diverged branch `codex/fix-supabase-schema-review` has one extra schema commit; this report's policy findings apply to `main`.

## Verification and next step

This phase was read-only. No database queries, tests, migrations, or app changes were run. The actual Auth signup setting could not be verified from repository files. Review these findings before starting Phase 1; any fixes should be delivered as a new migration and tested in a separate phase.
