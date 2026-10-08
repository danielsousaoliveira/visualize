#ifndef POSTGRES_READ_ONLY_ROLE_H
#define POSTGRES_READ_ONLY_ROLE_H

static const char *vd_read_only_role_query =
    "WITH reader AS (SELECT * FROM pg_catalog.pg_roles WHERE rolname = session_user) "
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM reader r WHERE "
    "r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls "
    "OR EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m WHERE m.member = r.oid) "
    "OR EXISTS (SELECT 1 FROM pg_catalog.pg_shdepend d "
    "WHERE d.refclassid = 'pg_catalog.pg_authid'::pg_catalog.regclass AND d.refobjid = r.oid AND d.deptype = 'o') "
    "OR pg_catalog.has_database_privilege(r.oid, pg_catalog.current_database(), 'CREATE,TEMP') "
    "OR EXISTS (SELECT 1 FROM pg_catalog.pg_namespace n "
    "WHERE pg_catalog.has_schema_privilege(r.oid, n.oid, 'CREATE')) "
    "OR EXISTS (SELECT 1 FROM pg_catalog.pg_class c WHERE CASE WHEN c.relkind IN ('r','p','v','m','f') "
    "AND c.oid <> 'pg_catalog.pg_settings'::pg_catalog.regclass THEN (pg_catalog.has_table_privilege(r.oid, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') "
    "OR pg_catalog.has_any_column_privilege(r.oid, c.oid, 'INSERT,UPDATE,REFERENCES')) ELSE false END) "
    "OR EXISTS (SELECT 1 FROM pg_catalog.pg_class c WHERE CASE WHEN c.relkind = 'S' "
    "THEN pg_catalog.has_sequence_privilege(r.oid, c.oid, 'USAGE,UPDATE') ELSE false END) "
    "OR EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.prosecdef "
    "AND pg_catalog.has_function_privilege(r.oid, p.oid, 'EXECUTE'))) "
    "OR NOT EXISTS (SELECT 1 FROM reader) THEN 'unsafe' ELSE 'safe' END";

static const char *vd_read_only_role_error =
    "Use a dedicated read-only Postgres role with direct SELECT grants and no role memberships, "
    "object ownership, administrative privileges, write or CREATE/TEMP grants, or access to SECURITY DEFINER functions. "
    "Update the connection user and password; visualize does not create roles or change grants.";

#endif
