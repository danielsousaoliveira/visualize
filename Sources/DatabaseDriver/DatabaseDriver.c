#include "DatabaseDriver.h"
#include <sqlite3.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#ifdef VD_STATIC_LIBPQ
#include <libpq-fe.h>
#endif

struct VDConnection {
    sqlite3 *sqlite;
    void *library;
    void *postgres;
    void *(*connect)(const char *const *, const char *const *, int);
    int (*status)(const void *);
    char *(*error)(const void *);
    void (*finish)(void *);
    void *(*exec)(void *, const char *);
    int (*result_status)(const void *);
    char *(*result_error)(const void *);
    char *(*value)(const void *, int, int);
    int (*rows)(const void *);
    int (*columns)(const void *);
    void (*clear)(void *);
};

void vd_free(char *value) { free(value); }

void vd_close(VDConnection *connection) {
    if (!connection) return;
    if (connection->sqlite) sqlite3_close(connection->sqlite);
    if (connection->postgres) connection->finish(connection->postgres);
    if (connection->library) dlclose(connection->library);
    free(connection);
}

VDConnection *vd_sqlite_open(const char *path, char **error) {
    VDConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) { *error = strdup("Out of memory"); return NULL; }
    if (sqlite3_open_v2(path, &connection->sqlite, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        *error = strdup(sqlite3_errmsg(connection->sqlite));
        vd_close(connection);
        return NULL;
    }
    sqlite3_busy_timeout(connection->sqlite, 5000);
    char *failure = NULL;
    char *result = vd_query(connection, "PRAGMA query_only = ON; PRAGMA schema_version", &failure);
    free(result);
    if (failure) { *error = failure; vd_close(connection); return NULL; }
    return connection;
}

VDConnection *vd_postgres_open(const char *library, const char *port, const char *user, const char *password, const char *database, char **error) {
    VDConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) { *error = strdup("Out of memory"); return NULL; }
#ifdef VD_STATIC_LIBPQ
#define LOAD(field, symbol) connection->field = (__typeof__(connection->field))symbol;
#else
    connection->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!connection->library) {
        *error = strdup("Postgres driver unavailable. Install Homebrew libpq or use the packaged app.");
        vd_close(connection);
        return NULL;
    }
#define LOAD(field, symbol) \
    *(void **)(&connection->field) = dlsym(connection->library, #symbol); \
    if (!connection->field) { *error = strdup("Incompatible Postgres driver"); vd_close(connection); return NULL; }
#endif
    LOAD(connect, PQconnectdbParams)
    LOAD(status, PQstatus)
    LOAD(error, PQerrorMessage)
    LOAD(finish, PQfinish)
    LOAD(exec, PQexec)
    LOAD(result_status, PQresultStatus)
    LOAD(result_error, PQresultErrorMessage)
    LOAD(value, PQgetvalue)
    LOAD(rows, PQntuples)
    LOAD(columns, PQnfields)
    LOAD(clear, PQclear)
#undef LOAD
    const char *keys[] = { "host", "hostaddr", "port", "user", "password", "dbname", "options", "connect_timeout", "sslmode", "gssencmode", "passfile", "application_name", NULL };
    const char *values[] = { "127.0.0.1", "127.0.0.1", port, user, password, database, "-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=5000", "5", "disable", "disable", "/dev/null", "visualize", NULL };
    connection->postgres = connection->connect(keys, values, 0);
    if (!connection->postgres || connection->status(connection->postgres) != 0) {
        *error = strdup(connection->postgres ? connection->error(connection->postgres) : "Could not allocate Postgres connection");
        vd_close(connection);
        return NULL;
    }
    char *failure = NULL;
    char *read_only = vd_query(connection, "SHOW default_transaction_read_only", &failure);
    if (failure || !read_only || strcmp(read_only, "on")) {
        *error = failure ? failure : strdup("Postgres did not enable read-only mode");
        free(read_only);
        vd_close(connection);
        return NULL;
    }
    free(read_only);
    return connection;
}

static int first_value(void *context, int count, char **values, char **names) {
    char **value = context;
    if (!*value && count > 0) *value = strdup(values[0] ? values[0] : "");
    return 0;
}

char *vd_query(VDConnection *connection, const char *sql, char **error) {
    if (connection->sqlite) {
        char *message = NULL;
        char *value = NULL;
        if (sqlite3_exec(connection->sqlite, sql, first_value, &value, &message) != SQLITE_OK) {
            *error = strdup(message ? message : sqlite3_errmsg(connection->sqlite));
            sqlite3_free(message);
            free(value);
            return NULL;
        }
        return value ? value : strdup("");
    }
    void *result = connection->exec(connection->postgres, sql);
    if (!result) { *error = strdup(connection->error(connection->postgres)); return NULL; }
    int status = connection->result_status(result);
    if (status != 1 && status != 2) {
        *error = strdup(connection->result_error(result));
        connection->clear(result);
        return NULL;
    }
    char *value = strdup(connection->rows(result) && connection->columns(result) ? connection->value(result, 0, 0) : "");
    connection->clear(result);
    return value;
}
