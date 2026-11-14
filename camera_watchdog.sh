#!/bin/bash
# ---------------------------------------------------------------------------
# camera_watchdog.sh -- restart crowsnest when the MJPEG stream wedges
#
# Background (BERTHA, 2026-11-11):
#   camera-streamer stayed running but /webcam/?action=stream started
#   answering HTTP 500 for hours until crowsnest was restarted. This script
#   polls the snapshot endpoint once a minute and asks Moonraker to restart
#   crowsnest after two consecutive failures.
#
# Usage:  camera_watchdog.sh start | stop | status
# ---------------------------------------------------------------------------

SNAPSHOT_URL="http://127.0.0.1/webcam/?action=snapshot"
RESTART_URL="http://127.0.0.1:7125/machine/services/restart?service=crowsnest"
LOG_FILE="/home/theberrymancan/printer_data/logs/camera_watchdog.log"
PID_FILE="/tmp/camera_watchdog.pid"
INTERVAL=60           # seconds between checks
MAX_FAILS=2           # consecutive failures before restarting crowsnest
RESTART_COOLDOWN=300  # never restart more often than this (seconds)

# Fall back to /tmp when printer_data/logs is not writable by the caller.
if ! : >>"$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/camera_watchdog.log"
fi

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null
}

# Echo the pid of a live watchdog loop, or return 1.
running_pid() {
    local pid
    [ -r "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q "camera_watchdog.sh" || return 1
    echo "$pid"
}

stop_loop() {
    local pid
    if pid=$(running_pid); then
        kill "$pid" 2>/dev/null
        log "watchdog stopped (pid $pid)"
    fi
    rm -f "$PID_FILE"
}

loop() {
    echo $$ >"$PID_FILE"
    log "watchdog started (pid $$): interval ${INTERVAL}s, max_fails $MAX_FAILS, log $LOG_FILE"
    local fails=0 last_restart=0 now code resp checks=0
    while true; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SNAPSHOT_URL")
        now=$(date +%s)
        checks=$((checks + 1))
        # heartbeat every 30 checks (~30 min) so the log proves the loop is alive
        [ $((checks % 30)) -eq 0 ] && log "heartbeat: HTTP $code (checks: $checks)"
        if [ "$code" = "200" ]; then
            [ "$fails" -ge "$MAX_FAILS" ] && log "camera healthy again (HTTP 200)"
            fails=0
        else
            fails=$((fails + 1))
            log "camera check failed (HTTP ${code:-000}), consecutive failures: $fails"
            if [ "$fails" -ge "$MAX_FAILS" ]; then
                if [ $((now - last_restart)) -lt "$RESTART_COOLDOWN" ]; then
                    log "skipping restart: last restart was $((now - last_restart))s ago"
                else
                    resp=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
                        -X POST -H 'Content-Type: application/json' -d '{}' "$RESTART_URL")
                    last_restart=$(date +%s)
                    log "crowsnest restart requested, Moonraker returned HTTP $resp"
                fi
                fails=0
            fi
        fi
        sleep "$INTERVAL"
    done
}

case "$1" in
    start)
        if pid=$(running_pid); then
            exit 0                       # already running
        fi
        loop
        ;;
    stop)
        stop_loop
        ;;
    restart)
        stop_loop
        sleep 1
        loop
        ;;
    status)
        if pid=$(running_pid); then
            echo "running (pid $pid), log: $LOG_FILE"
            tail -n 5 "$LOG_FILE" 2>/dev/null
            exit 0
        fi
        echo "not running, log: $LOG_FILE"
        exit 1
        ;;
    check)
        # one-shot health check, useful from the console
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SNAPSHOT_URL")
        echo "snapshot HTTP $code"
        [ "$code" = "200" ]
        ;;
    *)
        echo "usage: $0 {start|stop|restart|status|check}" >&2
        exit 2
        ;;
esac
