#!/bin/bash
#
# startServer.sh -- starts the SWG cluster, and when the container is asked to
# stop, shuts the game down CLEANLY so the world is SAVED first.
#
# How this script is started
#   docker/entrypoint.sh (the image's entrypoint) changes into the working
#   copy (SWG_WORK_DIR, /swg-main in the container) and finishes with
#   `exec bash startServer.sh`. So this script runs from /swg-main, and it
#   REPLACES the entrypoint as PID 1 -- the first process in the container.
#
# Why the trap below matters
#   `docker stop`, `docker restart`, `docker compose stop/restart` and a host
#   shutdown all send SIGTERM to PID 1, wait, and then SIGKILL everything.
#   Without a handler, PID 1 ignores SIGTERM, nothing is saved, and the game
#   is killed after the timeout (exit code 137).
#
# How the clean stop works
#   CentralServer checks about every 30 seconds for a file called ".shutdown"
#   in its own folder (exe/linux). If the file holds a number of seconds, it
#   deletes the file and runs the same sequence as the in-game
#   "/server shutdown" command: warn players, disconnect them, run a final
#   database save, then tell TaskManager to stop every game process.
#   (Engine source: CentralServer.cpp, checkShutdownProcess.)
#   In testing this took 39-51 seconds from writing the file until all game
#   processes were gone.
#
# Settings (environment variables)
#   SWG_STOP_TIMEOUT  seconds to wait for the save before giving up and
#                     force-stopping everything (default 150). Keep Docker's
#                     stop timeout (compose stop_grace_period) LONGER than
#                     this, or Docker kills everything first.

# --- Settings and paths -----------------------------------------------------

# Work from the folder this script lives in (the working copy root), no matter
# what the current directory was when it was started.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}" || exit 1

# The file CentralServer watches. CentralServer's current directory is
# exe/linux (exec.sh does `cd exe/linux` before starting the servers).
SHUTDOWN_FILE="${SCRIPT_DIR}/exe/linux/.shutdown"

STOP_TIMEOUT="${SWG_STOP_TIMEOUT:-150}"
POLL_SECONDS=2
LEFTOVER_GRACE_SECONDS=10

# Process patterns for `pgrep -f` / `pkill -f`, which match against the whole
# command line (e.g. "./bin/CentralServer -- ..."). We can't use exact names
# (`pgrep -x`) because Linux cuts process names off at 15 characters.
# The [b] trick means the pattern text never matches itself.
CENTRAL_PATTERN='[b]in/CentralServer'

# The processes that hold game data. When all of these are gone, the game has
# finished stopping.
GAME_PATTERNS=(
    '[b]in/CentralServer'
    '[b]in/SwgDatabaseServer'
    '[b]in/SwgGameServer'
    '[b]in/PlanetServer'
)

# The processes that keep running after a clean game stop.
LEFTOVER_PATTERNS=(
    '[b]in/TaskManager'
    '[b]in/LoginServer'
    '[s]tationchat'
)

# Everything the old `ant stop` target killed, plus stationchat.
ALL_PATTERNS=(
    '[b]in/LoginServer'
    '[b]in/CentralServer'
    '[b]in/ChatServer'
    '[b]in/CommoditiesServer'
    '[b]in/ConnectionServer'
    '[b]in/CustomerServiceServer'
    '[b]in/LogServer'
    '[b]in/MetricsServer'
    '[b]in/PlanetServer'
    '[b]in/ServerConsole'
    '[b]in/SwgDatabaseServer'
    '[b]in/SwgGameServer'
    '[b]in/TransferServer'
    '[b]in/TaskManager'
    '[s]tationchat'
)

ANT_PID=""
STOP_IN_PROGRESS=0

# --- Small helpers ----------------------------------------------------------

# Print a log line with a UTC timestamp. It goes to stdout, so it shows up in
# `docker logs swg-server`.
log() {
    echo "[startServer $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

# True if at least one process matches ANY of the given patterns.
any_running() {
    local pattern
    for pattern in "$@"; do
        if pgrep -f "${pattern}" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# Send a signal (TERM or KILL) to every process matching the given patterns.
signal_all() {
    local signal="$1"
    shift
    local pattern
    for pattern in "$@"; do
        pkill "-${signal}" -f "${pattern}" >/dev/null 2>&1
    done
}

# Ask the given processes to stop (TERM), wait up to LEFTOVER_GRACE_SECONDS,
# then force (KILL) whatever is still there. The `ant start` process is
# included: it normally ends by itself once TaskManager is gone.
stop_processes() {
    # SECONDS is bash's built-in "seconds since the script started" counter.
    local started="${SECONDS}"
    signal_all TERM "$@"
    while [ $((SECONDS - started)) -lt "${LEFTOVER_GRACE_SECONDS}" ]; do
        if ! any_running "$@" && ! ant_running; then
            return 0
        fi
        sleep 1
    done
    log "Some processes did not stop within ${LEFTOVER_GRACE_SECONDS}s; forcing them."
    signal_all KILL "$@"
    if ant_running; then
        kill -KILL "${ANT_PID}" 2>/dev/null
    fi
}

ant_running() {
    [ -n "${ANT_PID}" ] && kill -0 "${ANT_PID}" 2>/dev/null
}

# --- The stop handler -------------------------------------------------------

graceful_stop() {
    # Guard: a second SIGTERM/SIGINT (e.g. someone runs `docker stop` twice)
    # must not start a second shutdown.
    if [ "${STOP_IN_PROGRESS}" -eq 1 ]; then
        log "Stop signal received again; a clean stop is already in progress."
        return
    fi
    STOP_IN_PROGRESS=1
    log "Stop signal received."

    # Case 1: CentralServer is not running (the cluster is still starting, or
    # it already died). There is nothing that can run a save, so stop
    # everything the way `ant stop` always did.
    if ! any_running "${CENTRAL_PATTERN}"; then
        log "CentralServer is not running (startup not finished?). No save is possible; stopping all processes."
        stop_processes "${ALL_PATTERNS[@]}"
        log "All processes stopped. Exiting."
        exit 0
    fi

    # Case 2: ask CentralServer for the in-game shutdown sequence, which
    # includes a final database save. "1" = start in 1 second.
    echo 1 > "${SHUTDOWN_FILE}"
    log "Save requested: wrote ${SHUTDOWN_FILE}. CentralServer checks for it about every 30s. Waiting up to ${STOP_TIMEOUT}s."

    # Wait until every game-data process is gone. CentralServer only asks
    # TaskManager to stop them after the final save has finished.
    local started="${SECONDS}"
    local elapsed=0
    while any_running "${GAME_PATTERNS[@]}"; do
        elapsed=$((SECONDS - started))
        if [ "${elapsed}" -ge "${STOP_TIMEOUT}" ]; then
            log "SAVE DID NOT COMPLETE: the game was still running after ${STOP_TIMEOUT}s. Force-stopping everything; changes since the last automatic save may be lost."
            # Remove the request file so it can't trigger a shutdown later.
            rm -f "${SHUTDOWN_FILE}"
            signal_all KILL "${ALL_PATTERNS[@]}"
            if ant_running; then
                kill -KILL "${ANT_PID}" 2>/dev/null
            fi
            exit 1
        fi
        sleep "${POLL_SECONDS}"
    done
    elapsed=$((SECONDS - started))
    log "Save complete: game stopped cleanly after ${elapsed}s."

    # TaskManager, LoginServer, stationchat and the `ant start` process keep
    # running after a clean game stop. Stop them now.
    log "Stopping the remaining processes (TaskManager, LoginServer, stationchat, ant)."
    stop_processes "${LEFTOVER_PATTERNS[@]}"
    log "Clean stop finished. Exiting."
    exit 0
}

# --- Start the cluster ------------------------------------------------------

# A .shutdown file left over from an earlier run would make the new cluster
# shut itself down about 30 seconds after it starts. Remove it first.
if [ -e "${SHUTDOWN_FILE}" ]; then
    rm -f "${SHUTDOWN_FILE}"
    log "Removed a stale ${SHUTDOWN_FILE} left over from an earlier run."
fi

trap graceful_stop TERM INT

log "Starting the cluster (ant start). Clean-stop timeout: ${STOP_TIMEOUT}s."

# Run `ant start` in the BACKGROUND and wait for it. Bash only runs a trap
# while it is waiting with the `wait` command, not while a command runs in
# the foreground. `<&0` keeps the container's normal input connected
# (background commands would otherwise get an empty input), because
# TaskManager reads console commands from it.
ant start <&0 &
ANT_PID=$!

# `wait` returns early whenever a signal arrives, so keep waiting until the
# ant process has really ended. (After a stop signal, graceful_stop exits the
# script itself, so this loop only ends here when ant stops on its own.)
ANT_STATUS=0
while true; do
    wait "${ANT_PID}"
    ANT_STATUS=$?
    if ! ant_running; then
        break
    fi
done

log "ant start ended by itself (exit code ${ANT_STATUS})."
exit "${ANT_STATUS}"
