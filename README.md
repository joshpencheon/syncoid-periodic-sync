# Scheduled ZFS sync over Tailscale

This project provides a systemd service and shell script to automate ZFS backups over Tailscale.

It is intended to be used between Raspberry Pi 5 devices, which support RTC-scheduled wake; this means the offsite device can power on, pull the latest updates, and then power off again.

## Usage
1. **Copy files:**
   - Place `scheduled-zfs-sync.sh` in `/usr/local/bin/` and make it executable:
     ```sh
     chmod +x /usr/local/bin/scheduled-zfs-sync.sh
     ```
   - Place `scheduled-zfs-sync.service` in `/etc/systemd/system/`.
2. **Enable and start the service:**
   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now scheduled-zfs-sync.service
   ```

