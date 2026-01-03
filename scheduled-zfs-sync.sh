#!/bin/bash
# scheduled-zfs-sync.sh
# Runs ZFS backup, logs to syslog, schedules next RTC wakeup, and halts system.

set -euo pipefail

# Backup parameters (edit these to match your environment)
REMOTE_USER="ubuntu"
REMOTE_HOST="nas"
SOURCE_DATASET="main-pool/time-machine"
TARGET_DATASET="backup-pool/time-machine"
BACKUP_USER="syncoid"

SSH_REMOTE="$REMOTE_USER@$REMOTE_HOST"
BACKUP_CMD=(syncoid --debug --sendoptions=raw --no-privilege-elevation --no-sync-snap --no-rollback --use-hold "$SSH_REMOTE:$SOURCE_DATASET" "$TARGET_DATASET")

WAKE_TIMES=("02:00" "20:00")
MIN_UPTIME=300  # 5 minutes in seconds
USER_WAIT_SLEEP=300  # Wait time between user checks in seconds

log() {
  # Usage: log LEVEL MESSAGE
  # Example: log 3 "An error occurred"
  local level="$1"
  shift
  echo "<$level>$*"
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

run_zfs_backup() {
  log 6 "Starting ZFS backup."
  BACKUP_LOG=$(mktemp /tmp/scheduled-zfs-sync-backup.XXXXXX)

  if sudo -u "$BACKUP_USER" "${BACKUP_CMD[@]}" > "$BACKUP_LOG" 2>&1; then
    backup_status=0
  else
    backup_status=$?
  fi

  while IFS= read -r line; do
    log 6 "Backup output: $line"
  done < "$BACKUP_LOG"
  rm "$BACKUP_LOG"

  if [ "$backup_status" -eq 0 ]; then
    log 6 "Backup completed successfully."
  else
    log 3 "ERROR: Backup failed!"
  fi
}

schedule_next_wake() {
  next_wake=$(get_next_wake_epoch)
  log 6 "Scheduling next RTC wakeup at epoch $next_wake."

  wakealarm_path="/sys/class/rtc/rtc0/wakealarm"
  if [ -w "$wakealarm_path" ]; then
    echo "0"          | sudo tee "$wakealarm_path" > /dev/null
    echo "$next_wake" | sudo tee "$wakealarm_path" > /dev/null
    log 6 "Wakealarm set for $next_wake."
  else
    log 3 "ERROR: Cannot write to $wakealarm_path. Wakeup not scheduled."
  fi
}

should_shutdown_when_done() {
  if sudo -u "$BACKUP_USER" ssh "$SSH_REMOTE" [ -f offsite-stay-online ]; then
    log 3 "Not scheduling shutdown; 'stay online' file found on source system"
    false
  else
    true
  fi
}

wait_for_minimum_uptime() {
  boot_time=$(date -d "$(uptime -s)" +%s)
  now=$(date +%s)
  min_run_time=$((boot_time + MIN_UPTIME))
  if [ "$now" -lt "$min_run_time" ]; then
    wait_time=$((min_run_time - now))
    log 6 "Waiting $wait_time seconds to allow SSH access before halt."
    sleep "$wait_time"
  fi
}

shutdown_unless_users_logged_in() {
  LOGGED_IN_USERS=$(who | awk '{print $1}' | sort | uniq)

  if [ -n "$LOGGED_IN_USERS" ]; then
    log 3 "Skipping shutdown as users are logged in: $LOGGED_IN_USERS"
  else
    log 6 "Halting system for low power (systemctl poweroff)."
    if ! systemctl poweroff; then
      log 3 "ERROR: systemctl poweroff failed."
      exit 1
    fi
  fi
}

main() {
  run_zfs_backup
  schedule_next_wake

  if should_shutdown_when_done; then
    wait_for_minimum_uptime
    shutdown_unless_users_logged_in
  fi
}

main
