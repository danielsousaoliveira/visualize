#ifndef DATABASE_DRIVER_H
#define DATABASE_DRIVER_H

typedef struct VDConnection VDConnection;
VDConnection *vd_sqlite_open(const char *path, char **error);
VDConnection *vd_postgres_open(const char *library, const char *port, const char *user, const char *password, const char *database, char **error);
char *vd_query(VDConnection *connection, const char *sql, char **error);
void vd_close(VDConnection *connection);
void vd_free(char *value);

#endif
