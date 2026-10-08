postgres_version=18.4
postgres_root="$repo_root/build/postgresql-$postgres_version"
postgres_archive="$repo_root/build/postgresql-$postgres_version.tar.bz2"
if [[ ! -f "$postgres_root/src/interfaces/libpq/libpq.a" ]]; then
    mkdir -p "$repo_root/build"
    if [[ ! -f "$postgres_archive" ]]; then
        curl --fail --location --proto '=https' --tlsv1.2 \
            "https://ftp.postgresql.org/pub/source/v$postgres_version/postgresql-$postgres_version.tar.bz2" \
            --output "$postgres_archive"
    fi
    actual_hash="$(shasum -a 256 "$postgres_archive")"
    if [[ "${actual_hash%% *}" != 81a81ec695fb0c7901407defaa1d2f7973617154cf27ba74e3a7ab8e64436094 ]]; then
        echo "PostgreSQL source checksum does not match" >&2
        exit 1
    fi
    tar -xjf "$postgres_archive" -C "$repo_root/build"
    (
        cd "$postgres_root"
        MACOSX_DEPLOYMENT_TARGET=14.0 CFLAGS='-O2 -mmacosx-version-min=14.0' \
            ./configure --without-gssapi --without-ldap --without-libcurl \
            --without-icu --without-readline --without-zlib --without-lz4 --without-zstd
        make -j "$(sysctl -n hw.ncpu)" -C src/interfaces/libpq
    )
fi
postgres_flags=(
    -Xcc -DVD_STATIC_LIBPQ
    -Xcc "-I$postgres_root/src/interfaces/libpq"
    -Xcc "-I$postgres_root/src/include"
    -Xlinker "$postgres_root/src/interfaces/libpq/libpq.a"
    -Xlinker "$postgres_root/src/common/libpgcommon_shlib.a"
    -Xlinker "$postgres_root/src/port/libpgport_shlib.a"
)
