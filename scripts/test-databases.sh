#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
postgres_bin="${VISUALIZE_POSTGRES_BIN:-}"
if [[ -z "$postgres_bin" ]]; then
    for candidate in /opt/homebrew/opt/postgresql/bin /usr/local/opt/postgresql/bin /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin; do
        if [[ -x "$candidate/postgres" ]]; then postgres_bin="$candidate"; break; fi
    done
fi
if [[ ! -x "$postgres_bin/postgres" ]]; then
    echo "Install PostgreSQL or set VISUALIZE_POSTGRES_BIN to its bin directory" >&2
    exit 1
fi
cluster="$(mktemp -d "${TMPDIR:-/tmp}/visualize-postgres.XXXXXX")"
started=false
cleanup() {
    if [[ "$started" == true ]]; then
        "$postgres_bin/pg_ctl" -D "$cluster/data" -m immediate -w stop >/dev/null
    fi
    rm -rf "$cluster"
}
trap cleanup EXIT
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
printf '%s\n' 'fixture-secret' > "$cluster/password"
chmod 600 "$cluster/password"
"$postgres_bin/initdb" -D "$cluster/data" --auth-local=trust --auth-host=scram-sha-256 --pwfile="$cluster/password" --no-locale >/dev/null
"$postgres_bin/pg_ctl" -D "$cluster/data" -l "$cluster/server.log" -o "-h 127.0.0.1 -p $port -k $cluster" -w start >/dev/null
started=true
PGPASSWORD=fixture-secret "$postgres_bin/psql" -h 127.0.0.1 -p "$port" -d postgres -c 'CREATE TABLE visualize_read_only_fixture (id INTEGER); INSERT INTO visualize_read_only_fixture VALUES (1);' >/dev/null
cd "$repo_root"
developer_dir="$(xcode-select -p)"
testing_flags=()
if [[ "$developer_dir" == */CommandLineTools ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libraries="$developer_dir/Library/Developer/usr/lib"
    testing_flags=(-Xswiftc "-F$frameworks" -Xlinker "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libraries")
fi
postgres_flags=()
configuration=debug
if [[ "${VISUALIZE_STATIC_POSTGRES:-0}" == 1 ]]; then
    source "$repo_root/scripts/postgres-build-flags.sh"
    configuration=release
fi
VISUALIZE_TEST_POSTGRES_PORT="$port" VISUALIZE_TEST_POSTGRES_PASSWORD=fixture-secret swift test -c "$configuration" "${testing_flags[@]}" "${postgres_flags[@]}" --filter DatabaseConnectionTests
