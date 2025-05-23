#!/bin/bash
# Configuration file for Pi maintenance scripts
# Edit these values to match your setup

# Determine the directory of this config script itself
# This allows utility scripts to be sourced relative to config.sh
CONFIG_SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

# Source utility scripts
if [ -f "${CONFIG_SCRIPT_DIR}/email_utils.sh" ]; then
    source "${CONFIG_SCRIPT_DIR}/email_utils.sh"
else
    # This is a critical failure for scripts expecting email functions
    echo "CRITICAL ERROR in config.sh: email_utils.sh not found at ${CONFIG_SCRIPT_DIR}/email_utils.sh" >&2
    # Optionally, you could exit here, but that might break scripts that don't need email.
    # For now, just an error message. Scripts needing email functions should check for them.
fi


# Basic info
PI_EMAIL="david@davidmagnus.co.uk"  # Your email address
PI_SCRIPT_USER="dave"               # User whose home directory holds specific configs/logs
PI_SCRIPT_USER_HOME="/home/${PI_SCRIPT_USER}" # Should resolve to /home/dave
PI_HOSTNAME="$(hostname)"           # System hostname

# Paths
# PI_HOME is now PI_SCRIPT_USER_HOME for clarity for these specific paths
PI_LOGS_DIR="${PI_SCRIPT_USER_HOME}/vps_maintenance_logs" # Should be /home/dave/vps_maintenance_logs
PI_MSMTP_CONFIG="/etc/msmtprc"      # System-wide msmtp config for root
# User-specific msmtp config (if needed by scripts run as $PI_SCRIPT_USER)
PI_MSMTP_CONFIG_USER="${PI_SCRIPT_USER_HOME}/.msmtprc"
PI_MSMTP_LOG_USER="${PI_LOGS_DIR}/msmtp_user.log" # Log for user-run msmtp

PI_RCLONE_CONFIG="${PI_SCRIPT_USER_HOME}/.config/rclone/rclone.conf" # Should be /home/dave/.config/rclone/rclone.conf

# Backup configuration (keeps existing values if script is run on your-pi-hostname)
# This section is fine, uses PI_HOSTNAME which is correctly dave-vps-arm
if [[ "${PI_HOSTNAME}" == "gdrive" ]]; then # Note: "gdrive" is not your current hostname, so this block is skipped
    # Use existing values for this Pi
    PI_BACKUP_REMOTE="gdrive"           # Existing rclone remote name
    PI_CLOUD_FOLDER="pi_backups_khpi3"  # Existing cloud folder
else
# Default values for other systems (or for this VPS)
PI_BACKUP_REMOTE="hetz-vps-arm-backup" # YOUR ACTUAL RClone Remote Name for OneDrive
PI_CLOUD_FOLDER="pi_backups_${PI_HOSTNAME}"  # This part is fine
fi

# For Certbot status script (default, can be overridden by script)
CERT_EXPIRY_WARN_DAYS=14 # Warn if cert expires in X days or less
