#!/bin/bash
echo "DEBUG: Script started. UID: $(id -u)" >&2
echo "DEBUG: Script path (\$0) is: $0" >&2
echo "DEBUG: Resolved script directory is: $(dirname "$0")" >&2
echo "DEBUG: Present Working Directory (PWD) is: $(pwd)" >&2

# VPS System Update and Restart Script (run as root)

# --- Configuration (Sourced from config.sh) ---
CONFIG_FILE="$(dirname "$0")/config.sh" # Absolute path
echo "DEBUG: Attempting to source CONFIG_FILE: ${CONFIG_FILE}" >&2

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "DEBUG: Successfully sourced ${CONFIG_FILE}." >&2
    echo "DEBUG: Value of PI_EMAIL after sourcing: ${PI_EMAIL:-Not Set}" >&2
    echo "DEBUG: Value of PI_HOSTNAME after sourcing: ${PI_HOSTNAME:-Not Set}" >&2
    echo "DEBUG: Value of PI_LOGS_DIR after sourcing: ${PI_LOGS_DIR:-Not Set}" >&2
    echo "DEBUG: Value of PI_MSMTP_CONFIG after sourcing: ${PI_MSMTP_CONFIG:-Not Set}" >&2
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Configuration file $CONFIG_FILE not found. Exiting." >&2
    exit 1
fi

# Use variables from config.sh, provide fallbacks if somehow they weren't set
RECIPIENT_EMAIL="${PI_EMAIL:-your-default-email@example.com}"
HOSTNAME_LABEL="${PI_HOSTNAME:-$(hostname)}"
LOG_BASE_DIR="${PI_LOGS_DIR:-/home/$(whoami)/logs}" # Should come from config.sh
MSMTP_CONFIG="${PI_MSMTP_CONFIG:-/home/$(whoami)/.msmtprc}" # Should come from config.sh
MSMTP_ACCOUNT="default" # Assuming 'default' account in msmtprc

LOG_FILE_BASENAME="${HOSTNAME_LABEL}_system_update.log"
LOG_FILE="${LOG_BASE_DIR}/${LOG_FILE_BASENAME}"

echo "DEBUG: RECIPIENT_EMAIL set to: ${RECIPIENT_EMAIL}" >&2
echo "DEBUG: HOSTNAME_LABEL set to: ${HOSTNAME_LABEL}" >&2
echo "DEBUG: LOG_BASE_DIR set to: ${LOG_BASE_DIR}" >&2
echo "DEBUG: MSMTP_CONFIG set to: ${MSMTP_CONFIG}" >&2
echo "DEBUG: LOG_FILE_BASENAME set to: ${LOG_FILE_BASENAME}" >&2
echo "DEBUG: LOG_FILE path set to: ${LOG_FILE}" >&2


DISK_WARN_THRESHOLD=90 # Percentage
MAX_APT_RETRIES=3
RETRY_DELAY_SECONDS=10 # Increased delay slightly
MAX_LOG_ARCHIVES=5 # Number of .gz archives to keep (e.g. log.1.gz to log.5.gz)

# --- Error Handling & Setup ---
set -euo pipefail # Exit on error, undefined variable, or pipe failure
# Define trap AFTER LOG_FILE is confirmed, or make handle_error robust to LOG_FILE not existing
# For now, if it fails before log_message works, we rely on stderr from set -e
trap 'echo "DEBUG: Error trap triggered for command: [$BASH_COMMAND] on line $LINENO with exit code $?" >&2; handle_error $? $LINENO "$BASH_COMMAND"' ERR

echo "DEBUG: Attempting to create log directory: ${LOG_BASE_DIR}" >&2
mkdir -p "$LOG_BASE_DIR" || { echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to create log directory $LOG_BASE_DIR. Exiting with code 3." >&2; exit 3; }
echo "DEBUG: Log directory $LOG_BASE_DIR should now exist. Attempting to touch log file: $LOG_FILE" >&2
touch "$LOG_FILE" || { echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to touch log file $LOG_FILE. Exiting with code 4." >&2; exit 4; }
echo "DEBUG: Successfully touched log file $LOG_FILE. Logging should now work." >&2


# --- Helper Functions ---
log_message() {
    local level="$1"
    local message="$2"
    # Append to LOG_FILE. If this function is called before LOG_FILE is writable, it might fail silently or error depending on permissions.
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] - $message" >> "$LOG_FILE"
}

generate_email_html() {
    local title="$1"; local status_class="$2"; local status_message="$3"; local details_html="$4"
    local current_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Using the same HTML structure as the original script
    cat <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font-family:Arial,sans-serif;margin:0;padding:0;background-color:#f4f4f4}.container{max-width:600px;margin:20px auto;background-color:#fff;padding:20px;border-radius:8px;box-shadow:0 0 10px rgba(0,0,0,.1)}.header{background-color:#007bff;color:#fff;padding:10px 0;text-align:center;border-radius:8px 8px 0 0}.header h2{margin:0}.status{padding:15px;margin:15px 0;border-radius:4px;font-weight:700}.status-success{background-color:#d4edda;color:#155724;border-left:5px solid #155724}.status-failure{background-color:#f8d7da;color:#721c24;border-left:5px solid #721c24}.status-warning{background-color:#fff3cd;color:#856404;border-left:5px solid #856404}.status-reboot{background-color:#cfe2ff;color:#084298;border-left:5px solid #084298}.details-table table{width:100%;border-collapse:collapse;margin-bottom:15px}.details-table th,.details-table td{border:1px solid #ddd;padding:8px;text-align:left}.details-table th{background-color:#f2f2f2}pre{white-space:pre-wrap;word-wrap:break-word;background-color:#f5f5f5;border:1px solid #ccc;padding:5px;max-height:200px;overflow-y:auto}.footer{font-size:.8em;text-align:center;color:#777;margin-top:20px}</style></head><body><div class="container"><div class="header"><h2>${title}</h2></div><div class="status ${status_class}">${status_message}</div><div class="details-table">${details_html}</div><div class="footer"><p>Report generated on ${current_timestamp} by $(hostname)</p></div></div></body></html>
EOF
}

send_html_notification() {
    local subject_base="$1"; local status_class="$2"; local status_message_text="$3"; local details_content_html="$4"
    local full_subject="${HOSTNAME_LABEL} System Update: ${subject_base}"
    local html_body
    html_body=$(generate_email_html "${HOSTNAME_LABEL} - ${subject_base}" "$status_class" "$status_message_text" "$details_content_html")

    log_message "DEBUG" "Preparing to send email. Subject: $full_subject. MSMTP_CONFIG: $MSMTP_CONFIG"
    if [ ! -f "$MSMTP_CONFIG" ]; then
        log_message "ERROR" "msmtp configuration file not found: $MSMTP_CONFIG. Cannot send email."
        echo "DEBUG: MSMTP config $MSMTP_CONFIG not found in send_html_notification" >&2
        return 1
    fi

    printf "To: %s\nSubject: %s\nContent-Type: text/html; charset=utf-8\nMIME-Version: 1.0\n\n%s" \
           "$RECIPIENT_EMAIL" "$full_subject" "$html_body" | \
    msmtp --file="$MSMTP_CONFIG" -a "$MSMTP_ACCOUNT" "$RECIPIENT_EMAIL"

    local msmtp_exit_code=$?
    if [ $msmtp_exit_code -ne 0 ]; then
        log_message "ERROR" "Failed to send email: $full_subject (msmtp exit code: $msmtp_exit_code)"
        echo "DEBUG: msmtp command failed with exit code $msmtp_exit_code" >&2
    else
        log_message "INFO" "Email sent successfully: $full_subject"
        echo "DEBUG: msmtp command successful for subject: $full_subject" >&2
    fi
    return $msmtp_exit_code
}

handle_error() {
    local exit_code="$1"; local line_number="$2"; local failed_command="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Try to log to file, but also echo to stderr as a fallback if logging isn't working
    local error_message_log="Error on line $line_number: Exit code $exit_code. Command: $failed_command"
    local error_message_stderr="[SCRIPT ERROR] Line $line_number: '$failed_command' exited with code $exit_code."
    
    echo "$error_message_stderr" >&2
    if [ -n "${LOG_FILE:-}" ] && [ -w "$(dirname "$LOG_FILE")" ] ; then # Check if LOG_FILE variable is set and dir is writable
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] - $error_message_log" >> "$LOG_FILE"
        local log_snippet
        log_snippet=$(tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
    else
        log_snippet="Log file not available or not writable."
    fi

    local error_details_html="<p>Script failed on line ${line_number} with exit code ${exit_code} at ${timestamp}.</p>"
    error_details_html+="<p>Failed command:</p><pre>$(echo "$failed_command" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
    error_details_html+="<h4>Log Snippet (Last 10 lines from log file, if available):</h4><pre>${log_snippet}</pre>"
    
    # Try to send email, but be careful about loops if send_html_notification itself fails
    if [[ "${BASH_COMMAND}" != *"send_html_notification"* ]]; then
        send_html_notification "FAILURE" "status-failure" "❌ Script Execution Failed" "$error_details_html"
    else
        echo "DEBUG: Error occurred within send_html_notification or handle_error itself. Suppressing recursive email." >&2
    fi
}

check_network() {
    local retry_count=0; local max_retries=5
    log_message "INFO" "Checking network connectivity..."
    while [ $retry_count -lt $max_retries ]; do
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            log_message "INFO" "Network connectivity is OK."
            return 0
        fi
        retry_count=$((retry_count + 1))
        log_message "WARNING" "Network check failed, attempt $retry_count of $max_retries. Retrying in ${RETRY_DELAY_SECONDS}s..."
        sleep "$RETRY_DELAY_SECONDS"
    done
    log_message "ERROR" "Network connectivity check failed after $max_retries attempts."
    return 1
}

initial_log_rotation() {
    log_message "INFO" "initial_log_rotation called for $LOG_FILE"
    if [ ! -f "$LOG_FILE" ]; then # If log file doesn't exist (e.g. first run after mkdir, or if touch failed)
        log_message "INFO" "Log file $LOG_FILE does not exist, attempting to create via touch for rotation logic."
        touch "$LOG_FILE" || { log_message "ERROR" "Failed to touch log file $LOG_FILE in initial_log_rotation."; return 1; }
    fi

    # Ensures MAX_LOG_ARCHIVES is the number of .gz files
    if [ -f "$LOG_FILE" ]; then # Re-check if touch succeeded
      for i in $(seq $MAX_LOG_ARCHIVES -1 1); do
        if [ -f "${LOG_FILE}.${i}.gz" ]; then
          if [ $i -eq $MAX_LOG_ARCHIVES ]; then # If it's the oldest allowed archive, remove it
            rm -f "${LOG_FILE}.${i}.gz"
            log_message "INFO" "Rotated out oldest archive: ${LOG_FILE}.${i}.gz"
          else # Otherwise, shift it
            mv "${LOG_FILE}.${i}.gz" "${LOG_FILE}.$((i+1)).gz"
            log_message "DEBUG" "Shifted ${LOG_FILE}.${i}.gz to ${LOG_FILE}.$((i+1)).gz"
          fi
        fi
      done
      if [ -s "$LOG_FILE" ]; then # If current log file has content
        gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz"
        truncate -s 0 "$LOG_FILE"
        log_message "INFO" "Main log content rotated to ${LOG_FILE}.1.gz. Current log truncated."
      else
        log_message "INFO" "Main log $LOG_FILE is empty or just created, no content to rotate to .1.gz."
      fi
    else
      log_message "ERROR" "Log file $LOG_FILE still does not exist after touch attempt in initial_log_rotation."
    fi
}

# --- Main Script Execution ---
# initial_log_rotation must happen AFTER LOG_FILE is defined and directory is confirmed.
# And after log_message function is defined.
initial_log_rotation # Call it here now that logging should be safe.

SCRIPT_MAIN_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
log_message "INFO" "System update script started for $HOSTNAME_LABEL at: $SCRIPT_MAIN_START_TIME"

if [[ $EUID -ne 0 ]]; then
   log_message "ERROR" "This script must be run as root. Exiting."
   # Error trap will handle email if possible
   exit 1 
fi

if ! command -v msmtp &> /dev/null; then
    log_message "WARNING" "msmtp is not installed. Attempting to install..."
    if DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y msmtp; then
        log_message "INFO" "msmtp installed successfully."
    else
        log_message "ERROR" "Failed to install msmtp. Email notifications may not work as expected."
    fi
fi

disk_warn_details=""
CURRENT_DISK_USAGE_PERCENT=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$CURRENT_DISK_USAGE_PERCENT" -gt "$DISK_WARN_THRESHOLD" ]; then
    log_message "WARNING" "Disk space is at ${CURRENT_DISK_USAGE_PERCENT}%."
    part1="<p>Current disk space usage is ${CURRENT_DISK_USAGE_PERCENT}%, which exceeds the warning threshold of ${DISK_WARN_THRESHOLD}%.</p>"
    part2="<table><tr><th>Filesystem</th><th>Size</th><th>Used</th><th>Avail</th><th>Use%</th><th>Mounted on</th></tr>"
    df_table_rows=$(df -h / | awk "NR==1 {print \"<tr><th>\" \$1 \"</th><th>\" \$2 \"</th><th>\" \$3 \"</th><th>\" \$4 \"</th><th>\" \$5 \"</th><th>\" \$6 \"</th></tr>\"} NR==2 {print \"<tr><td>\" \$1 \"</td><td>\" \$2 \"</td><td>\" \$3 \"</td><td>\" \$4 \"</td><td>\" \$5 \"</td><td>\" \$6 \"</td></tr>\"}")
    part3="</table>"
    disk_warn_details="${part1}${part2}${df_table_rows}${part3}"
    send_html_notification "Disk Space Warning" "status-warning" "⚠️ Disk Space High" "$disk_warn_details"
fi

if ! check_network; then
    net_fail_details="<p>Failed to establish network connectivity after several retries.</p><p>System updates cannot proceed without a working internet connection.</p>"
    send_html_notification "FAILURE - Network Down" "status-failure" "❌ Network Connectivity Failed" "$net_fail_details"
    exit 1
fi

AVAILABLE_SPACE_KB=$(df / | awk 'NR==2 {print $4}')
MIN_SPACE_KB=500000 # 500MB
if [ "$AVAILABLE_SPACE_KB" -lt "$MIN_SPACE_KB" ]; then
    log_message "ERROR" "Insufficient disk space for updates. Only ${AVAILABLE_SPACE_KB}KB available."
    space_crit_details="<p>Insufficient disk space for updates. Only ${AVAILABLE_SPACE_KB}KB available, requires at least ${MIN_SPACE_KB}KB (500MB).</p>"
    send_html_notification "FAILURE - Disk Space Critical" "status-failure" "❌ Insufficient Disk Space" "$space_crit_details"
    exit 1
fi
log_message "INFO" "Sufficient disk space available ($(numfmt --to=iec --suffix=B ${AVAILABLE_SPACE_KB}000))."

log_message "INFO" "Updating package lists (apt update)..."
retries=0; update_success=false; last_apt_error=0
while [ $retries -lt $MAX_APT_RETRIES ] && [ $update_success = false ]; do
    # Script is run as root, so sudo here is redundant but harmless
    if DEBIAN_FRONTEND=noninteractive apt update -o APT::Update::Error-Modes=any; then 
        update_success=true
        log_message "INFO" "Package list updated successfully."
    else
        last_apt_error=$?
        retries=$((retries + 1))
        log_message "WARNING" "apt update failed (exit code: $last_apt_error). Attempt $retries of $MAX_APT_RETRIES."
        if [ $retries -lt $MAX_APT_RETRIES ]; then
            log_message "INFO" "Retrying in $RETRY_DELAY_SECONDS seconds..."
            sleep "$RETRY_DELAY_SECONDS"
            log_message "INFO" "Clearing apt lists before retry..."
            rm -rf /var/lib/apt/lists/* 
            apt clean 
        fi
    fi
done

if [ $update_success = false ]; then
    log_message "ERROR" "Failed to update package list after $MAX_APT_RETRIES attempts."
    apt_fail_details="<p>Failed to update package lists (apt update) after $MAX_APT_RETRIES attempts.</p><p>Last exit code: $last_apt_error</p>"
    send_html_notification "FAILURE - APT Update" "status-failure" "❌ APT Update Failed" "$apt_fail_details"
    exit 1
fi

log_message "INFO" "Starting full system upgrade (apt full-upgrade)..."
if ! DEBIAN_FRONTEND=noninteractive apt -o Dpkg::Options::="--force-confold" -y full-upgrade; then
    log_message "ERROR" "apt full-upgrade failed."
    apt_upgrade_fail_details="<p>apt full-upgrade failed. Please check system logs for details.</p>"
    send_html_notification "FAILURE - APT Full-Upgrade" "status-failure" "❌ APT Full-Upgrade Failed" "$apt_upgrade_fail_details"
    exit 1
fi
log_message "INFO" "apt full-upgrade completed."

log_message "INFO" "Cleaning up old packages (autoremove, autoclean)..."
DEBIAN_FRONTEND=noninteractive apt -y autoremove
DEBIAN_FRONTEND=noninteractive apt -y autoclean
log_message "INFO" "Cleanup completed."

sys_info_html="<h4>System Information Post-Update:</h4>"
sys_info_html+="<p><strong>Disk Space:</strong></p><pre>$(df -h /)</pre>"
sys_info_html+="<p><strong>Memory Usage:</strong></p><pre>$(free -h)</pre>"
sys_info_html+="<p><strong>System Uptime:</strong></p><pre>$(uptime -p)</pre>"
sys_info_html+="<p><strong>Last 10 Package Changes (dpkg.log):</strong></p><pre>$(grep -E 'install |upgrade |remove ' /var/log/dpkg.log | tail -n 10 | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"

REBOOT_REQUIRED=false
if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=true
    log_message "INFO" "System requires a reboot."
    reboot_msg_details="${sys_info_html}<p>System will reboot automatically in 1 minute.</p>"
    send_html_notification "SUCCESS - Reboot Required" "status-reboot" "🔄 System Update Successful - Reboot Scheduled" "$reboot_msg_details"
else
    log_message "INFO" "No reboot required."
    send_html_notification "SUCCESS" "status-success" "✅ System Update Successful" "$sys_info_html"
fi

log_message "INFO" "Update process finished successfully at $(date '+%Y-%m-%d %H:%M:%S')."
log_message "INFO" "==================================" 

if [ "$REBOOT_REQUIRED" = true ]; then
    log_message "INFO" "Rebooting system in 1 minute..."
    shutdown -r +1 "System is rebooting after software update"
fi

log_message "INFO" "Performing final log archive cleanup for $LOG_FILE_BASENAME..."
find "$LOG_BASE_DIR" -name "${LOG_FILE_BASENAME}.*.gz" -type f -printf '%T@ %p\n' | sort -nr | tail -n +$((MAX_LOG_ARCHIVES + 1)) | cut -d' ' -f2- | xargs -I {} rm -f {}
log_message "INFO" "Old operational logs for $LOG_FILE_BASENAME cleaned up, kept latest $MAX_LOG_ARCHIVES archives."

exit 0
