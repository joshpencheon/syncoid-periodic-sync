#!/bin/bash
# scheduled_zfs_sync.sh
# Runs ZFS backup after Tailscale is connected, logs to syslog, schedules next RTC wakeup, and halts system.

set -euo pipefail

LOG_TAG="scheduled-zfs-sync"
BACKUP_CMD="syncoid --sendoptions=raw --no-privilege-elevation --no-sync-snap --no-rollback --use-hold ubuntu@nas:main-pool/time-machine backup-pool/time-machine"
WAKE_HOUR=1
WAKE_MIN=0
MIN_UPTIME=300  # 5 minutes in seconds

log() {
  logger -t "$LOG_TAG" "$1"
}

wait_for_tailscale() {
  log "Waiting for Tailscale connection..."
  while ! tailscale status --json | grep -q '"Self":.*"Online":true'; do
    sleep 5
  done
  log "Tailscale connected."
}

get_next_wake_epoch() {
  # Get next 1am (UTC) epoch time
  now=$(date +%s)
  next_wake=$(date -d "tomorrow ${WAKE_HOUR}:${WAKE_MIN}" +%s)
  echo "$next_wake"
}

main() {
  wait_for_tailscale

  log "Starting ZFS backup."
  BACKUP_OUTPUT=$(sudo -u syncoid bash -c "$BACKUP_CMD" 2>&1)
  BACKUP_EXIT=$?
  log "Backup output: $BACKUP_OUTPUT"
  if [ $BACKUP_EXIT -eq 0 ]; then
    log "Backup completed successfully."
  else
    log "Backup failed!"
  fi


  next_wake=$(get_next_wake_epoch)
  log "Scheduling next RTC wakeup at epoch $next_wake."
  rtcwake -m no -t "$next_wake"

  # Ensure system has been up at least 5 minutes past scheduled wake
  boot_time=$(date -d "$(uptime -s)" +%s)
  min_run_time=$((next_wake + MIN_UPTIME))
  now=$(date +%s)
  if [ "$now" -lt "$min_run_time" ]; then
    wait_time=$((min_run_time - now))
    log "Waiting $wait_time seconds to allow SSH access before halt."
    sleep "$wait_time"
  fi

  # Check for logged-in users (excluding root and syncoid)
  LOGGED_IN_USERS=$(who | awk '{print $1}' | grep -vE '^(root|syncoid)$' | sort | uniq)
  if [ -n "$LOGGED_IN_USERS" ]; then
    log "Shutdown deferred: users are logged in: $LOGGED_IN_USERS"
    exit 0
  fi

  log "Halting system for low power."
  halt

}

main "$@"
