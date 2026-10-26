# Firebase SQL Connect setup

This replaces the Supabase database scaffold with Firebase SQL Connect, backed by Cloud SQL for PostgreSQL. The current HTML interface still uses localStorage; this migration prepares the data model and typed connector, but does not yet connect the UI or move existing sample data.

## Before deployment

1. Create or select a Firebase project and add a Web app.
2. Configure Firebase Authentication for the sign-in methods the store will use.
3. Set up Firebase SQL Connect and its Cloud SQL PostgreSQL instance in a region you choose.
4. Copy `.firebaserc.example` to `.firebaserc`, then set the Firebase project ID.
5. Update `dataconnect/dataconnect.yaml` with the selected SQL Connect region and Cloud SQL instance ID.
6. Review the billing plan before provisioning Cloud SQL. SQL Connect and its Cloud SQL database have separate billing components; free trial or quota eligibility depends on the project and current Google Cloud account.

## Schema and access

- The GraphQL schema in `dataconnect/schema/schema.gql` defines users, products, customers, invoices, invoice items, payments, and stock movements.
- Client access is through the declared SQL Connect operations and generated JavaScript SDK. The browser should not connect directly to PostgreSQL.
- Connector operations require Firebase Authentication. Staff role checks read the caller's `StoreUser` record, and product creation excludes stock quantity so stock starts at zero.
- Create the first user through Firebase Authentication and call `BootstrapStoreUser` once. Promote the first store user to `owner` using a privileged Cloud SQL administration session. Do not expose database credentials or an Admin SDK service account in browser code.

## Deployment

Use the Firebase CLI and follow its SQL Connect migration prompts. Review schema changes before applying them; do not use strict mode against a database containing unrelated tables. SQL Connect deploys the schema, connectors, and generated SDK from this directory.

The data model is ready for a fresh Firebase project. The sales, payment, and audited stock-adjustment mutations and the HTML client integration are the next implementation step. Existing localStorage data is not migrated automatically.
