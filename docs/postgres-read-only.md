# Postgres reader credentials

Use a dedicated login with direct CONNECT, schema USAGE, and SELECT grants for the tables the viewer needs. The app rejects administrative roles, role memberships, object ownership, write grants (including column and sequence grants), CREATE/TEMP privileges, and executable SECURITY DEFINER functions. It rechecks these privileges before each query. PostgreSQL’s built-in `pg_settings` view remains usable for session settings; the transaction guard prevents it from enabling writes.

Credentials discovered in env or Compose may belong to an application owner or superuser. Replace the connection user and password with reader credentials before testing or connecting. visualize never provisions roles or changes grants.

A database owner can provision a reader manually. Adapt the database, schema, table selection, and password to the project. Review PUBLIC grants first: removing them affects other database users, so grant any required access explicitly to the application's role.

```sql
CREATE ROLE visualize_reader LOGIN PASSWORD 'choose-a-local-password'
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
REVOKE CREATE, TEMP ON DATABASE project_database FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE project_database TO visualize_reader;
GRANT USAGE ON SCHEMA public TO visualize_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO visualize_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE project_owner IN SCHEMA public
    GRANT SELECT ON TABLES TO visualize_reader;
```

Existing PUBLIC write grants or SECURITY DEFINER function grants must also be removed by the owner, or the app will reject the reader. The connection error names the policy; the app makes no automatic changes.

The connection retains `default_transaction_read_only=on`. Each query runs as one SQL command in a fresh `BEGIN READ ONLY` transaction, establishes a snapshot with the privilege check, and rolls back afterward. Changing the session default cannot enable writes, and multiple commands cannot end the transaction and append a write.

The integration fixture tests a reader login, rejects superuser/writer/member logins, tries changing both read-only settings, and tries `COMMIT; INSERT`. It also attempts a write directly through psql after disabling the session default, proving that the reader's grants independently reject the write.

```sh
VISUALIZE_STATIC_POSTGRES=1 VISUALIZE_TEST_KEYCHAIN=1 scripts/test-databases.sh
```

See PostgreSQL's [privilege inspection functions](https://www.postgresql.org/docs/16/functions-info.html) and [single-command query protocol](https://www.postgresql.org/docs/16/libpq-exec.html).
