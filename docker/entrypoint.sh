#!/usr/bin/env bash
set -euo pipefail

SWG_SOURCE_DIR="${SWG_SOURCE_DIR:-/swg-main-source}"
SWG_WORK_DIR="${SWG_WORK_DIR:-/swg-main}"
SWG_SYNC_SOURCE="${SWG_SYNC_SOURCE:-auto}"

sync_source_tree() {
    local command="${1:-run}"
    local should_sync="false"

    case "${SWG_SYNC_SOURCE}" in
        true)
            should_sync="true"
            ;;
        false)
            ;;
        auto)
            if [ "${command}" != "run" ] || [ ! -f "${SWG_WORK_DIR}/.swg-source-synced" ]; then
                should_sync="true"
            fi
            ;;
        *)
            echo "Invalid SWG_SYNC_SOURCE='${SWG_SYNC_SOURCE}'; expected auto, true, or false." >&2
            exit 1
            ;;
    esac

    if [ "${should_sync}" != "true" ]; then
        echo "Reusing the synchronized Linux build volume for '${command}'."
        mkdir -p "${SWG_WORK_DIR}"
        cd "${SWG_WORK_DIR}"
        return 0
    fi

    if [ ! -d "${SWG_SOURCE_DIR}" ] || [ "${SWG_SOURCE_DIR}" = "${SWG_WORK_DIR}" ]; then
        mkdir -p "${SWG_WORK_DIR}"
        cd "${SWG_WORK_DIR}"
        return 0
    fi

    echo "Syncing SWG source from ${SWG_SOURCE_DIR} to ${SWG_WORK_DIR}..."
    mkdir -p "${SWG_WORK_DIR}"
    if [ ! -f "${SWG_WORK_DIR}/.swg-source-synced" ]; then
        if [ -z "${SWG_WORK_DIR}" ] || [ "${SWG_WORK_DIR}" = "/" ]; then
            echo "Refusing to clear unsafe SWG_WORK_DIR='${SWG_WORK_DIR}'." >&2
            exit 1
        fi

        echo "Populating first-time Linux build volume..."
        find "${SWG_WORK_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        # GNU tar exclusions are --no-anchored by default, and these options
        # are positional: --anchored applies only to the patterns that follow,
        # so .git/*/.git above still match at any depth while the build-product
        # patterns below match only at the top level.
        tar -C "${SWG_SOURCE_DIR}" \
            --exclude='.git' \
            --exclude='*/.git' \
            --anchored \
            --exclude='./.swg-source-synced' \
            --exclude='./build' \
            --exclude='./chat' \
            --exclude='./client-assets' \
            --exclude='./data' \
            --exclude='./dependencies' \
            --exclude='./exe/linux/bin' \
            --exclude='./exe/linux/logs' \
            --exclude='./miff' \
            --exclude='./*.log' \
            --exclude='./local.properties' \
            --exclude='./webcfg.properties' \
            -cf - . | tar -C "${SWG_WORK_DIR}" -xf -
        touch "${SWG_WORK_DIR}/.swg-source-synced"
    else
        # Build-product exclusions must be anchored with a leading '/'. An
        # unanchored rsync pattern matches at every depth, so 'chat/' also
        # stripped dsrc/sku.0/sys.shared/compiled/game/chat (spatial chat
        # types), and 'build/' and 'data/' would strip
        # src/game/server/database/{build,data}. Only .git and *.log are
        # meant to match at any depth.
        rsync -a --delete \
            --exclude='.git' \
            --exclude='*/.git' \
            --exclude='/.swg-source-synced' \
            --exclude='/build/' \
            --exclude='/chat/' \
            --exclude='/client-assets/' \
            --exclude='/data/' \
            --exclude='/dependencies/' \
            --exclude='/exe/linux/bin' \
            --exclude='/exe/linux/logs/' \
            --exclude='/miff/' \
            --exclude='*.log' \
            --exclude='/local.properties' \
            --exclude='/webcfg.properties' \
            "${SWG_SOURCE_DIR}/" "${SWG_WORK_DIR}/"
    fi

    cd "${SWG_WORK_DIR}"
}

sync_source_tree "${1:-run}"

normalize_executable_text() {
    find . -maxdepth 1 -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
    find exe/linux exe/shared -maxdepth 1 -type f \( -name '*.cfg' -o -name '*.rc' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    find utils -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' -o -name '*.pl' \) -exec sed -i 's/\r$//' {} +
    find tools -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' -o -name '*.pl' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    find . -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} +
    find utils -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' -o -name '*.pl' \) -exec chmod +x {} +
    find tools -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' -o -name '*.pl' \) -exec chmod +x {} + 2>/dev/null || true
}

normalize_executable_text

SWG_SERVER_BITS="${SWG_SERVER_BITS:-64}"
case "${SWG_SERVER_BITS}" in
    32|64)
        ;;
    *)
        echo "Invalid SWG_SERVER_BITS='${SWG_SERVER_BITS}'; expected 32 or 64." >&2
        exit 2
        ;;
esac

export ORACLE_HOME="${ORACLE_HOME:-/opt/oracle/instantclient_19_31}"
if [ -z "${JAVA_HOME:-}" ]; then
    if [ "${SWG_SERVER_BITS}" = "64" ]; then
        export JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
    else
        export JAVA_HOME="/usr/lib/jvm/java-11-openjdk-i386"
    fi
fi
export PATH="${ORACLE_HOME}:${JAVA_HOME}/bin:${PATH}"
export LD_LIBRARY_PATH="${ORACLE_HOME}:${JAVA_HOME}/lib:${JAVA_HOME}/lib/server:${LD_LIBRARY_PATH:-}"
export NLS_LANG="${NLS_LANG:-american_america.utf8}"

SWG_DB_HOST="${SWG_DB_HOST:-oracle}"
SWG_DB_PORT="${SWG_DB_PORT:-1521}"
SWG_DB_SERVICE="${SWG_DB_SERVICE:-XEPDB1}"
SWG_DB_USER="${SWG_DB_USER:-swg}"
SWG_DB_PASSWORD="${SWG_DB_PASSWORD:-swg}"
SWG_DB_ADMIN_USER="${SWG_DB_ADMIN_USER:-system}"
SWG_DB_ADMIN_PASSWORD="${SWG_DB_ADMIN_PASSWORD:-swg}"
SWG_DB_DATAFILE_DIR="${SWG_DB_DATAFILE_DIR:-/opt/oracle/oradata/XE/XEPDB1}"
SWG_CLUSTER_NAME="${SWG_CLUSTER_NAME:-swg}"
SWG_PUBLIC_ADDRESS="${SWG_PUBLIC_ADDRESS:-127.0.0.1}"

# The container's own eth0 address. Several services bind to eth0 rather than to all interfaces, so
# anything connecting to them from inside this container has to use this rather than loopback.
SWG_CONTAINER_ADDRESS="$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{split($2, a, "/"); print a[1]; exit}')"
if [ -z "${SWG_CONTAINER_ADDRESS}" ]; then
    SWG_CONTAINER_ADDRESS="$(hostname -i 2>/dev/null | awk '{print $1}')"
fi
if [ -z "${SWG_CONTAINER_ADDRESS}" ]; then
    echo "WARNING: could not determine the container's eth0 address; falling back to 127.0.0.1." >&2
    SWG_CONTAINER_ADDRESS="127.0.0.1"
fi
echo "Container address for eth0-bound services: ${SWG_CONTAINER_ADDRESS}"
SWG_CLIENT_ASSETS_TRE="${SWG_CLIENT_ASSETS_TRE:-/client-assets/swgsource_3.0.tre}"
SWG_START_CHAT="${SWG_START_CHAT:-true}"
SWG_ANT_INIT_TARGETS="${SWG_ANT_INIT_TARGETS:-clean update_configs create_database compile}"
SWG_ANT_BUILD_TARGETS="${SWG_ANT_BUILD_TARGETS:-compile}"
SWG_STAGED_CLIENT_ASSETS_TRE=""

connect_string="//${SWG_DB_HOST}:${SWG_DB_PORT}/${SWG_DB_SERVICE}"

mark_git_safe() {
    git config --global --add safe.directory /swg-main || true
    for dir in dsrc exe serverdata src stationapi; do
        git config --global --add safe.directory "/swg-main/${dir}" || true
    done
}

write_local_properties() {
    local firstrun="$1"

    cat > local.properties <<EOF
# Generated by docker/entrypoint.sh. Do not commit.
firstrun = ${firstrun}
cluster_name = ${SWG_CLUSTER_NAME}
db_username = ${SWG_DB_USER}
db_password = ${SWG_DB_PASSWORD}
db_service = ${SWG_DB_SERVICE}
dbip = ${SWG_DB_HOST}
compiler = gcc
bits = ${SWG_SERVER_BITS}
oracle_home.32 = ${ORACLE_HOME}
oracle_home.64 = ${ORACLE_HOME}
oracle_include.32 = ${ORACLE_HOME}/sdk/include
oracle_include.64 = ${ORACLE_HOME}/sdk/include
java_home.32 = ${JAVA_HOME}
java_home.64 = ${JAVA_HOME}
src_build_type = Release
EOF
}

sqlplus_app() {
    sqlplus -L -S "${SWG_DB_USER}/${SWG_DB_PASSWORD}@${connect_string}" "$@"
}

sqlplus_admin() {
    sqlplus -L -S "${SWG_DB_ADMIN_USER}/${SWG_DB_ADMIN_PASSWORD}@${connect_string}" "$@"
}

wait_for_oracle() {
    local attempts="${SWG_DB_WAIT_ATTEMPTS:-120}"

    echo "Waiting for Oracle at ${connect_string}..."
    for attempt in $(seq 1 "${attempts}"); do
        if echo "select 1 from dual;" | sqlplus_app >/dev/null 2>&1; then
            echo "Oracle is ready."
            return 0
        fi

        if [ "${attempt}" -eq "${attempts}" ]; then
            echo "Oracle did not become ready after ${attempts} attempts." >&2
            return 1
        fi

        sleep 5
    done
}

ensure_oracle_prereqs() {
    echo "Ensuring Oracle tablespaces and SWG grants..."

    sqlplus_admin <<SQL
whenever sqlerror exit sql.sqlcode
declare
    table_count number;
begin
    select count(*) into table_count from dba_tablespaces where tablespace_name = 'DATA';
    if table_count = 0 then
        execute immediate 'create tablespace DATA datafile ''${SWG_DB_DATAFILE_DIR}/data01.dbf'' size 512M autoextend on next 128M maxsize unlimited';
    end if;

    select count(*) into table_count from dba_tablespaces where tablespace_name = 'INDEXES';
    if table_count = 0 then
        execute immediate 'create tablespace INDEXES datafile ''${SWG_DB_DATAFILE_DIR}/indexes01.dbf'' size 256M autoextend on next 64M maxsize unlimited';
    end if;
end;
/
grant create session to ${SWG_DB_USER};
grant create table to ${SWG_DB_USER};
grant create view to ${SWG_DB_USER};
grant create sequence to ${SWG_DB_USER};
grant create procedure to ${SWG_DB_USER};
grant create trigger to ${SWG_DB_USER};
grant create type to ${SWG_DB_USER};
grant create synonym to ${SWG_DB_USER};
grant unlimited tablespace to ${SWG_DB_USER};
alter user ${SWG_DB_USER} default tablespace DATA temporary tablespace TEMP quota unlimited on DATA quota unlimited on INDEXES;
exit
SQL
}

set_cluster_public_address() {
    echo "Setting cluster '${SWG_CLUSTER_NAME}' public address to ${SWG_PUBLIC_ADDRESS}..."

    sqlplus_app <<SQL
whenever sqlerror exit sql.sqlcode
update cluster_list set address = '${SWG_PUBLIC_ADDRESS}' where name = '${SWG_CLUSTER_NAME}';
commit;
exit
SQL
}

write_runtime_network_config() {
    local node_host

    node_host="$(hostname)"
    echo "Setting TaskManager node0 to ${node_host}..."
    cat > exe/linux/nodes.cfg <<EOF
[TaskManager]
node0=${node_host}
EOF
}

ensure_runtime_symlinks() {
    mkdir -p exe/linux/logs

    if [ -d "${SWG_WORK_DIR}/serverdata" ]; then
        mkdir -p data/sku.0/sys.client/compiled
        ln -sfn "${SWG_WORK_DIR}/serverdata" data/sku.0/sys.client/compiled/clientdata
    fi

    if [ -d "${SWG_WORK_DIR}/build/bin" ]; then
        mkdir -p exe/linux
        ln -sfn "${SWG_WORK_DIR}/build/bin" exe/linux/bin
    fi
}

sync_runtime_config_files() {
    if [ -d "${SWG_SOURCE_DIR}/exe/linux" ] && [ "${SWG_SOURCE_DIR}" != "${SWG_WORK_DIR}" ]; then
        mkdir -p exe/linux
        for config_file in logServerTargets.cfg taskmanager.rc; do
            cp -f "${SWG_SOURCE_DIR}/exe/linux/${config_file}" "exe/linux/${config_file}"
            sed -i 's/\r$//' "exe/linux/${config_file}"
        done
    fi
}

# Fill in the external-auth shared secret at start, so the real value is never
# stored in git. The configs repo only holds the token EXTERNALAUTHSECRET on the
# "externalAuthSecretKey=" line of servercommon.cfg. The real value comes from
# the SWG_EXTERNAL_AUTH_SECRET environment variable (set from the .env key
# SWG_AUTH_EXTERNAL_AUTH_SECRET in the compose override file).
#
# The whole line is rewritten on every start (not only the token), so a changed
# secret in .env takes effect after a container restart. The value is never
# printed. If external auth is turned on but the secret is missing, stop with an
# error instead of starting a server nobody can log in to.
write_external_auth_secret() {
    local cfg="exe/linux/servercommon.cfg"
    local local_cfg="exe/linux/localOptions.cfg"
    local tmp="${cfg}.docker-tmp"
    local external_auth=""

    if [ ! -f "${cfg}" ]; then
        echo "External auth: ${cfg} not found." >&2
        exit 1
    fi

    # Is external auth on? localOptions.cfg is read after servercommon.cfg, so
    # the last active (not commented) useExternalAuth= line of the two wins.
    external_auth="$(cat "${cfg}" "${local_cfg}" 2>/dev/null \
        | tr -d '\r' \
        | grep -E '^[[:space:]]*useExternalAuth[[:space:]]*=' \
        | tail -n 1 \
        | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//' \
        | tr '[:upper:]' '[:lower:]' || true)"

    if [ -z "${SWG_EXTERNAL_AUTH_SECRET:-}" ]; then
        if [ "${external_auth}" = "true" ] || [ "${external_auth}" = "1" ]; then
            echo "ERROR: useExternalAuth is on, but SWG_EXTERNAL_AUTH_SECRET is empty." >&2
            echo "Set SWG_AUTH_EXTERNAL_AUTH_SECRET in .env and pass it to swg-server as" >&2
            echo "SWG_EXTERNAL_AUTH_SECRET (docker-compose.override.yml), then start again." >&2
            exit 1
        fi
        echo "External auth is off and no secret is set; leaving ${cfg} as it is."
        return 0
    fi

    if ! tr -d '\r' < "${cfg}" | grep -qE '^externalAuthSecretKey='; then
        echo "ERROR: SWG_EXTERNAL_AUTH_SECRET is set, but ${cfg} has no externalAuthSecretKey= line." >&2
        echo "The exe (configs) checkout is probably not the VoraGaming/configs version." >&2
        exit 1
    fi

    # awk reads the secret from the environment (ENVIRON), so characters such
    # as / & \ in the secret are copied as-is (sed would treat them specially).
    awk '
        { sub(/\r$/, "") }
        /^externalAuthSecretKey=/ { print "externalAuthSecretKey=" ENVIRON["SWG_EXTERNAL_AUTH_SECRET"]; next }
        { print }
    ' "${cfg}" > "${tmp}"
    # "cat >" keeps the original file's owner and permissions (mv would not).
    cat "${tmp}" > "${cfg}"
    rm -f "${tmp}"
    echo "External auth: secret written to ${cfg} (value not shown)."
}

stage_client_asset_tree() {
    local source="${SWG_CLIENT_ASSETS_TRE}"
    local target_dir="${SWG_WORK_DIR}/client-assets"
    local target="${target_dir}/$(basename "${source}")"
    local source_size
    local target_size
    local source_real
    local target_real

    if [ ! -f "${source}" ]; then
        echo "Client assets TRE not found at ${source}." >&2
        echo "Mount the client-assets repo or set SWG_CLIENT_ASSETS_TRE." >&2
        exit 1
    fi

    mkdir -p "${target_dir}"
    source_real="$(readlink -f "${source}")"
    target_real="$(readlink -f "${target}" 2>/dev/null || true)"
    source_size="$(stat -c '%s' "${source}")"
    target_size="$(stat -c '%s' "${target}" 2>/dev/null || echo -1)"

    if [ "${source_real}" != "${target_real}" ] && [ "${source_size}" != "${target_size}" ]; then
        echo "Staging client asset tree ${source} to ${target}..."
        cp -f "${source}" "${target}"
    fi

    SWG_STAGED_CLIENT_ASSETS_TRE="${target}"
}

write_client_asset_tree_config() {
    local cfg="exe/linux/localOptions.cfg"
    local tmp="${cfg}.docker-tmp"

    stage_client_asset_tree

    echo "Writing Docker runtime overrides..."
    touch "${cfg}"
    awk '
        $0 == "### BEGIN Docker client asset tree" { skip = 1; next }
        $0 == "### END Docker client asset tree" { skip = 0; next }
        $0 == "### BEGIN Docker runtime overrides" { skip = 1; next }
        $0 == "### END Docker runtime overrides" { skip = 0; next }
        !skip { print }
    ' "${cfg}" > "${tmp}"

    cat >> "${tmp}" <<EOF

### BEGIN Docker runtime overrides
[SharedFile]
searchTree0=${SWG_STAGED_CLIENT_ASSETS_TRE}

[SharedNetwork]
# The database server legitimately backs up its send queue while streaming the
# preload to the game servers. Each of those warnings walks the call stack, and
# at ~1000 warnings that cost slows the frame enough to grow the backlog
# further. The condition is reported by the queue size itself; the per-frame
# warning only amplifies it.
logSendingTooMuchData=false

[CentralServer]
gameServiceBindInterface=eth0
connectionServiceBindInterface=eth0
planetServiceBindInterface=eth0
commodityServerServiceBindInterface=eth0
customerServicePort=61242

[dbProcess]
gameServiceBindInterface=eth0
commoditiesServerAddress=127.0.0.1

[PlanetServer]
gameServiceBindInterface=eth0
watcherServiceBindInterface=eth0

[ChatServer]
gameServiceBindInterface=eth0
planetServiceBindInterface=eth0

[ConnectionServer]
clientServiceBindInterface=eth0
gameServiceBindInterface=eth0
chatServiceBindInterface=eth0
customerServiceBindInterface=eth0
altPublicBindAddress=${SWG_PUBLIC_ADDRESS}

[CommodityServer]
# Bind the game-server listening service to loopback, not eth0. The game servers reach it through
# ConfigServerGame's commoditiesServerServiceBindInterface, which defaults to "localhost", so a
# service bound only to eth0 refuses them and every bazaar terminal reports "market is unavailable".
# Everything in this cluster shares one container, so loopback is sufficient and it means the game
# servers need no override of their own -- which matters because they only read config at startup.
cmServerServiceBindInterface=127.0.0.1
databaseServerAddress=127.0.0.1
# CentralServer binds its commodities service to eth0 (commodityServerServiceBindInterface above),
# so it is not reachable on loopback. ConfigCommodityServer defaults centralServerAddress to
# "localhost", and CentralServerConnection::onConnectionClosed calls exit(0) -- a clean exit, no
# core, nothing on stdout. TaskManager then respawns it, so the only visible symptom was its load
# sequence repeating in the log (1748 times when this was found) while ps never showed the process
# and every bazaar terminal reported "market is unavailable".
centralServerAddress=${SWG_CONTAINER_ADDRESS}

[LoginServer]
easyExternalAccess=true

[CustomerServiceServer]
gameServiceBindInterface=eth0
chatServiceBindInterface=eth0
useCsAssist=false
### END Docker runtime overrides
EOF

    mv "${tmp}" "${cfg}"
}

start_station_chat() {
    if [ "${SWG_START_CHAT}" != "true" ]; then
        return 0
    fi

    if [ -x chat/stationchat ]; then
        echo "Starting stationchat..."
        mkdir -p chat/var/log
        (cd chat && ./stationchat -c etc/stationapi/swgchat.cfg >> ../stationchat.log 2>&1) &
    else
        echo "stationchat binary not found; run init or build first." >&2
    fi
}

run_ant() {
    echo "Running ant $*"
    ant "$@"
}

verify_server_architecture() {
    local expected
    local binary
    local description
    local checked=0

    if [ "${SWG_SERVER_BITS}" = "64" ]; then
        expected="ELF 64-bit"
    else
        expected="ELF 32-bit"
    fi

    for binary in \
        build/bin/LoginServer \
        build/bin/TaskManager \
        build/bin/CentralServer \
        build/bin/ConnectionServer \
        build/bin/SwgDatabaseServer \
        build/bin/SwgGameServer; do
        if [ ! -f "${binary}" ]; then
            continue
        fi

        description="$(file -L "${binary}")"
        echo "${description}"
        case "${description}" in
            *"${expected}"*)
                ;;
            *)
                echo "Architecture verification failed: expected ${expected}: ${binary}" >&2
                return 1
                ;;
        esac
        checked=$((checked + 1))
    done

    if [ "${checked}" -eq 0 ]; then
        echo "Architecture verification failed: no core server binaries were found." >&2
        return 1
    fi

    echo "Verified ${checked} core server binaries as ${SWG_SERVER_BITS}-bit."
}

init_server() {
    write_local_properties true
    wait_for_oracle
    ensure_oracle_prereqs
    # Avoid ant swg here; it checks out submodule branches and dirties pointers.
    run_ant ${SWG_ANT_INIT_TARGETS}
    verify_server_architecture
    ensure_runtime_symlinks
    write_runtime_network_config
    sync_runtime_config_files
    write_client_asset_tree_config
    write_local_properties false
    set_cluster_public_address
}

build_server() {
    write_local_properties false
    wait_for_oracle
    ensure_oracle_prereqs
    run_ant ${SWG_ANT_BUILD_TARGETS}
    verify_server_architecture
    ensure_runtime_symlinks
}

run_server() {
    write_local_properties false
    wait_for_oracle
    ensure_oracle_prereqs
    ensure_runtime_symlinks

    if [ ! -x exe/linux/bin/LoginServer ] || [ ! -x exe/linux/bin/TaskManager ]; then
        echo "Server binaries are missing; running first-time init."
        init_server
    else
        run_ant update_configs
        write_runtime_network_config
        sync_runtime_config_files
        write_client_asset_tree_config
        set_cluster_public_address
    fi

    write_external_auth_secret
    start_station_chat
    exec bash startServer.sh
}

mark_git_safe

case "${1:-run}" in
    init)
        shift
        init_server "$@"
        ;;
    build)
        shift
        build_server "$@"
        ;;
    run)
        shift
        run_server "$@"
        ;;
    ant)
        shift
        write_local_properties false
        wait_for_oracle
        run_ant "$@"
        ;;
    verify-arch)
        shift
        verify_server_architecture
        ;;
    shell)
        shift
        exec bash "$@"
        ;;
    *)
        exec "$@"
        ;;
esac
