#!/bin/bash
# scheduled-zfs-sync.sh
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

get_next_wake_epoch() {
  # Get next 1am (UTC) epoch time
  now=$(date +%s)
  next_wake=$(date -d "tomorrow ${WAKE_HOUR}:${WAKE_MIN}" +%s)
  echo "$next_wake"
}

main() {
  log "Starting ZFS backup."
  BACKUP_LOG=$(mktemp /tmp/scheduled-zfs-sync-backup.XXXXXX)
  sudo -u syncoid bash -c "$BACKUP_CMD" > "$BACKUP_LOG" 2>&1
  BACKUP_EXIT=$?
  while IFS= read -r line; do
    log "Backup output: $line"
  done < "$BACKUP_LOG"
  rm -f "$BACKUP_LOG"
  if [ $BACKUP_EXIT -eq 0 ]; then
    log "Backup completed successfully."
  else
    log "Backup failed!"
  fi

  next_wake=$(get_next_wake_epoch)
  log "Scheduling next RTC wakeup at epoch $next_wake."
  if ! rtcwake -m no -t "$next_wake"; then
    log "ERROR: rtcwake failed to schedule next wakeup."
  fi

  # Ensure system has been up at least 5 minutes past scheduled wake
  boot_time=$(date -d "$(uptime -s)" +%s)
  min_run_time=$((next_wake + MIN_UPTIME))
  now=$(date +%s)
  if [ "$now" -lt "$min_run_time" ]; then
    wait_time=$((min_run_time - now))
    log "Waiting $wait_time seconds to allow SSH access before halt."
    sleep "$wait_time"
  fi

  # Check for logged-in users (including root and syncoid)
  while true; do
    LOGGED_IN_USERS=$(who | awk '{print $1}' | sort | uniq)
    if [ -z "$LOGGED_IN_USERS" ]; then
      break
    fi
    log "Shutdown deferred: users are logged in: $LOGGED_IN_USERS"
    wall "[$LOG_TAG] Shutdown deferred: users are logged in: $LOGGED_IN_USERS. System will retry shutdown in 5 minutes."
    log "System uptime: $(uptime -p)"
    sleep 300
  done

  log "Halting system for low power (systemctl poweroff)."
  if ! systemctl poweroff; then
    log "ERROR: systemctl poweroff failed."
    exit 1
  fi
}

main "$@"
