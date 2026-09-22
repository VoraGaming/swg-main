#!/bin/bash
# swg-log-cleanup.sh - weekly size check for the SWG game server's log files.
#
# What it does:
#   Looks at the log files INSIDE the running swg-server container and empties
#   (truncates to 0 bytes) any file that is bigger than the limit. It never
#   deletes a file and never touches anything else.
#
#   Files checked:
#     - every regular file directly in /swg-main/exe/linux/logs/
#       (written by the LogServer: customerService.log, startupLog.log,
#        taskProcessDied.txt, persistence.log, ...)
#     - /swg-main/stationchat.log          (chat server output), if it exists
#     - /swg-main/chat/var/log/swgchat.log (chat server log),    if it exists
#
# Limit: SWG_LOG_MAX_MB megabytes per file (default 200).
#   Example, one-off run with a 50 MB limit:  SWG_LOG_MAX_MB=50 ~/bin/swg-log-cleanup.sh
#
# Runs on the LXC host as the normal "swg" user (it is in the docker group, so
# no sudo is needed). Meant to be run by cron once a week. Install steps are in
# README.md in this folder ("Weekly log cleanup").
#
# Is emptying a file safe while the server is running?
#   - LogServer files (logs/): yes. The LogServer opens them in append mode
#     (FileLogObserver.cpp, fopen mode "a"), so after emptying, the next line
#     is written at the new end of the file (the start).
#   - stationchat.log: yes. The entrypoint starts stationchat with
#     ">> ../stationchat.log", which is also append mode.
#   - swgchat.log: NOT CONFIRMED. It is written by the chat server itself, and
#     its source code was not available to check. If it is not opened in
#     append mode, the chat server keeps writing at its old position after the
#     file is emptied. The file then shows the old size again, with a block of
#     empty (zero) bytes at the start, and uses less disk space than it shows.
#     Worst case is an odd-looking log file. No game data, characters or saves
#     are affected: this is only a text log.
#
# Output: one line per emptied file (UTC time, file name, old size) and a
# summary line. With the cron line from README.md this goes to
# ~/swg-log-cleanup.log.

set -u

# cron runs with a very short PATH. Make sure docker (/usr/bin/docker) is found.
PATH="${PATH}:/usr/local/bin:/usr/bin:/bin"

CONTAINER="swg-server"
LOG_DIR="/swg-main/exe/linux/logs"
CHAT_LOG_1="/swg-main/stationchat.log"
CHAT_LOG_2="/swg-main/chat/var/log/swgchat.log"

# Limit in MB. Use the SWG_LOG_MAX_MB environment variable if set, else 200.
MAX_MB="${SWG_LOG_MAX_MB:-200}"

# Current time in UTC, for the start of every output line.
now() {
    date -u '+%Y-%m-%d %H:%M:%S UTC'
}

# The limit must be a whole number above 0 (e.g. 200). Anything else: stop.
case "${MAX_MB}" in
    ''|*[!0-9]*|0)
        echo "$(now) ERROR: SWG_LOG_MAX_MB must be a whole number above 0, got '${MAX_MB}'. Nothing done."
        exit 1
        ;;
esac
MAX_BYTES=$(( MAX_MB * 1024 * 1024 ))

# 1. Is the game server container running? If not, there is nothing to do.
#    "docker inspect" prints "true" only for a running container. For a
#    missing container it fails; the error text is hidden and we just skip.
running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)"
if [ "${running}" != "true" ]; then
    echo "$(now) ${CONTAINER} is not running. Nothing to do."
    exit 0
fi

# 2. Inside the container: check each file and empty it if it is too big.
#    The small sh program below runs in the container. It gets its values as
#    arguments ($1 = limit in bytes, $2 = log folder, the rest = chat log files),
#    so no file names are pasted into the program text.
#    For each emptied file it prints one line: "EMPTIED <size in bytes> <file>".
#    Files that do not exist, folders and symlinks are skipped.
inner_program='
limit="$1"
logdir="$2"
shift 2
for f in "$logdir"/* "$@"; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    size=$(stat -c %s "$f") || continue
    if [ "$size" -gt "$limit" ]; then
        if truncate -s 0 "$f"; then
            echo "EMPTIED $size $f"
        else
            echo "FAILED $size $f"
        fi
    fi
done
'

result="$(docker exec "${CONTAINER}" sh -c "${inner_program}" sh \
    "${MAX_BYTES}" "${LOG_DIR}" "${CHAT_LOG_1}" "${CHAT_LOG_2}")"
exec_status=$?

# 3. Print the results in a readable form.
emptied=0
failed=0
while read -r word size file; do
    [ -n "${word}" ] || continue
    size_mb=$(( size / 1024 / 1024 ))
    if [ "${word}" = "EMPTIED" ]; then
        echo "$(now) emptied ${file} (was ${size_mb} MB, ${size} bytes)"
        emptied=$(( emptied + 1 ))
    else
        echo "$(now) FAILED to empty ${file} (${size_mb} MB, ${size} bytes)"
        failed=$(( failed + 1 ))
    fi
done <<EOF
${result}
EOF

if [ "${exec_status}" -ne 0 ]; then
    echo "$(now) ERROR: docker exec into ${CONTAINER} failed (exit ${exec_status})."
    exit 1
fi

echo "$(now) done: limit ${MAX_MB} MB, ${emptied} file(s) emptied, ${failed} failed."
if [ "${failed}" -ne 0 ]; then
    exit 1
fi
exit 0
