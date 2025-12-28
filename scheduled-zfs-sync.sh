#!/bin/bash
# scheduled-zfs-sync.sh
# Runs ZFS backup, logs to syslog, schedules next RTC wakeup, and halts system.

set -euo pipefail

LOG_TAG="scheduled-zfs-sync"

# Backup parameters (edit these to match your environment)
REMOTE_USER="ubuntu"
REMOTE_HOST="nas"
SOURCE_DATASET="main-pool/time-machine"
TARGET_DATASET="backup-pool/time-machine"

BACKUP_USER="syncoid"
BACKUP_CMD=(syncoid --sendoptions=raw --no-privilege-elevation --no-sync-snap --no-rollback --use-hold "$REMOTE_USER@$REMOTE_HOST:$SOURCE_DATASET" "$TARGET_DATASET")

WAKE_TIMES=("02:00" "20:00")
MIN_UPTIME=300  # 5 minutes in seconds
USER_WAIT_SLEEP=300  # Wait time between user checks in seconds

log() {
  logger -t "$LOG_TAG" -- "$1"
}

get_next_wake_epoch() {
  now=$(date +%s)
  next_wake=""
  for t in "${WAKE_TIMES[@]}"; do
    candidate=$(date -d "$t" +%s)
    # If the time has already passed today, use tomorrow
    if [ "$candidate" -le "$now" ]; then
      candidate=$(date -d "tomorrow $t" +%s)
    fi
    if [ -z "$next_wake" ] || [ "$candidate" -lt "$next_wake" ]; then
      next_wake="$candidate"
    fi
  done
  echo "$next_wake"
}


wait_for_no_logged_in_users() {
  while true; do
    LOGGED_IN_USERS=$(who | awk '{print $1}' | sort | uniq)
    if [ -z "$LOGGED_IN_USERS" ]; then
      break
    fi
    log "Shutdown deferred: users are logged in: $LOGGED_IN_USERS"
    wall "[$LOG_TAG] Shutdown deferred: users are logged in. System will retry shutdown in $USER_WAIT_SLEEP seconds."
    sleep "$USER_WAIT_SLEEP"
  done
}

wait_for_minimum_uptime() {
  boot_time=$(date -d "$(uptime -s)" +%s)
  now=$(date +%s)
  min_run_time=$((boot_time + MIN_UPTIME))
  if [ "$now" -lt "$min_run_time" ]; then
    wait_time=$((min_run_time - now))
    log "Waiting $wait_time seconds to allow SSH access before halt."
    sleep "$wait_time"
  fi
}

run_zfs_backup() {
  log "Starting ZFS backup."
  BACKUP_LOG=$(mktemp /tmp/scheduled-zfs-sync-backup.XXXXXX)

  sudo -u "$BACKUP_USER" "${BACKUP_CMD[@]}" > "$BACKUP_LOG" 2>&1
  backup_status=$?

  while IFS= read -r line; do
    log "Backup output: $line"
  done < "$BACKUP_LOG"
  rm "$BACKUP_LOG"

  if [ "$backup_status" -eq 0 ]; then
    log "Backup completed successfully."
  else
    log "ERROR: Backup failed!"
  fi
}

schedule_next_wake() {
  next_wake=$(get_next_wake_epoch)
  log "Scheduling next RTC wakeup at epoch $next_wake."

  wakealarm_path="/sys/class/rtc/rtc0/wakealarm"
  if [ -w "$wakealarm_path" ]; then
    echo "$next_wake" | sudo tee "$wakealarm_path" > /dev/null
    log "Wakealarm set for $next_wake."
  else
    log "ERROR: Cannot write to $wakealarm_path. Wakeup not scheduled."
  fi
}

halt_system() {
  log "Halting system for low power (systemctl poweroff)."
  if ! systemctl poweroff; then
    log "ERROR: systemctl poweroff failed."
    exit 1
  fi
}

run_zfs_backup
wait_for_minimum_uptime
wait_for_no_logged_in_users
schedule_next_wake
halt_system
