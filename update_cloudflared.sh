	#!/bin/bash

# update_cloudflared.sh
# Updates a Cloudflared instance running via Docker Compose.

# --- Universal Configuration Sourcing ---
SCRIPT_DIR_UFC=$(dirname "$(readlink -f "$0")") # UFC for UpdateCloudFlared
CONFIG_FILE_UFC="${SCRIPT_DIR_UFC}/config.sh"

if [ -f "$CONFIG_FILE_UFC" ]; then
    source "$CONFIG_FILE_UFC"
else
    # Critical: config.sh not found. Define absolute minimums for emergency logging.
    echo "CRITICAL: Main config file $CONFIG_FILE_UFC not found. update_cloudflared.sh cannot function properly. Exiting." >&2
    # Try to log to a fallback path if PI_LOGS_DIR isn't even available
    fallback_log_dir="/tmp/maintenance_script_errors"
    mkdir -p "$fallback_log_dir"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - update_cloudflared.sh: config.sh not found at $CONFIG_FILE_UFC. Exiting." >> "${fallback_log_dir}/update_cloudflared_critical.log"
    exit 1
fi

# --- Script-Specific Configuration & Variables from Universal Config ---
# This path is highly specific to the Cloudflared instance setup.
# If you run this script on multiple machines for different cloudflared instances,
# this might need to be a variable in config.sh or passed as an argument.
DOCKER_COMPOSE_FILE="/home/dave/cloudflared/docker-compose.yml" # KEEPING THIS, as it's instance-specific

LOG_DIR="${PI_LOGS_DIR}" # Use universal log directory
LOG_FILE="${LOG_DIR}/update_cloudflared.log" # Specific log file for this script
MAX_LOG_ARCHIVES=5 # Local override, or could be from config.sh if you add PI_MAX_LOG_ARCHIVES

# Email settings from universal config
RECIPIENT_EMAIL="${PI_EMAIL}"
# Use HOSTNAME_LABEL if defined in config.sh, otherwise use PI_HOSTNAME
EFFECTIVE_HOSTNAME_LABEL="${HOSTNAME_LABEL:-${PI_HOSTNAME}}"
# MSMTP settings for root execution
MSMTP_CONFIG_TO_USE="${PI_MSMTP_CONFIG}" # System-wide /etc/msmtprc
MSMTP_ACCOUNT_TO_USE="default" # msmtp account to use from the config file
MSMTP_LOG_TO_USE="${PI_LOGS_DIR}/msmtp_root.log" # Central msmtp log for root actions

# --- Helper Functions (Kept Local to this script for now) ---

log_message() {
    local level="$1"
    local message="$2"
    # LOG_DIR should be set by now from config.sh
    if [ ! -d "$LOG_DIR" ]; then
        # This case should ideally be caught by config sourcing check, but as a fallback:
        mkdir -p "$LOG_DIR" || { echo "CRITICAL: Failed to create log directory $LOG_DIR. Cannot log. Exiting." >&2; exit 1; }
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] - $message" >> "$LOG_FILE"
}

rotate_log_file() {
    # LOG_DIR and LOG_FILE should be set
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" || { echo "CRITICAL: Failed to create log directory $LOG_DIR for rotation. Exiting." >&2; exit 1; }
    fi
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" || { echo "CRITICAL: Failed to touch log file $LOG_FILE for rotation. Exiting." >&2; exit 1; }
        log_message "INFO" "Log file $LOG_FILE created." # Log creation
        return
    fi

    # More robust log rotation similar to other scripts
    if [ -s "$LOG_FILE" ]; then # Only rotate if log has content
        local archive_timestamp
        archive_timestamp=$(date +%Y%m%d_%H%M%S_%N)
        local temp_archive_name="${LOG_FILE}.${archive_timestamp}.tmp.gz"
        local final_archive_name="${LOG_FILE}.${archive_timestamp}.gz"

        if gzip -c "$LOG_FILE" > "$temp_archive_name"; then
            mv "$temp_archive_name" "$final_archive_name"
            truncate -s 0 "$LOG_FILE"
            log_message "INFO" "Main log rotated to ${final_archive_name}"
        else
            log_message "ERROR" "Failed to gzip log file $LOG_FILE to $temp_archive_name. Log not truncated."
            rm -f "$temp_archive_name" # Clean up temp file on failure
            return 1;
        fi
        # Cleanup old archives
        find "$LOG_DIR" -maxdepth 1 -name "$(basename "$LOG_FILE").*.gz" -type f -printf '%T@ %p\n' | \
            sort -nr | tail -n +$((MAX_LOG_ARCHIVES + 1)) | cut -d' ' -f2- | xargs -I {} rm -f {} && \
            log_message "INFO" "Old log archives cleaned up, kept latest $MAX_LOG_ARCHIVES."
    fi
}

generate_html_email_body() {
    local title="$1"
    local status_class_arg="$2" 
    local status_message_arg="$3" 
    local details_html="$4"    
    local script_start_time="$5" 
    local script_end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    local duration_msg="N/A"
    if [[ -n "$script_start_time" ]]; then
        local s_start s_end diff_seconds
        s_start=$(date -d "$script_start_time" +%s 2>/dev/null) || s_start=$(date +%s) # Fallback for invalid date
        s_end=$(date -d "$script_end_time" +%s 2>/dev/null) || s_end=$(date +%s)     # Fallback
        if [[ "$s_start" =~ ^[0-9]+$ && "$s_end" =~ ^[0-9]+$ && "$s_end" -ge "$s_start" ]]; then
            diff_seconds=$((s_end - s_start))
            duration_msg="$((diff_seconds / 60))m $((diff_seconds % 60))s"
        fi
    fi

    local log_snippet_html="<h4>Log Snippet (Last 10 lines):</h4><pre style='background-color:#f5f5f5; border:1px solid #ccc; padding:5px; overflow-x:auto;'>$(tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"

    # Using the CSS from email_utils.sh for consistency (slightly adapted)
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>${title}</title>
    <style>
        body { font-family: Verdana, Geneva, sans-serif; margin: 0; padding: 10px; background-color: #f8f9fa; color: #333; font-size: 14px; }
        .container { max-width: 800px; margin: 20px auto; background-color: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 0 15px rgba(0,0,0,.1); }
        .header h2 { color: #004085; margin-top: 0; text-align: center; }
        .status { padding: 15px; margin: 15px 0; border-radius: 4px; font-weight: bold; text-align: center; font-size: 1.1em; }
        .status-success { background-color: #d4edda; color: #155724; border-left: 5px solid #155724; }
        .status-failure { background-color: #f8d7da; color: #721c24; border-left: 5px solid #721c24; }
        .details-table { width: 100%; border-collapse: collapse; margin-bottom: 15px; }
        .details-table th, .details-table td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        .details-table th { background-color: #f2f2f2; }
        h3, h4 { color: #004085; }
        pre { white-space: pre-wrap; word-wrap: break-word; background-color:#f1f1f1; border:1px solid #ddd; padding:10px; border-radius:4px; font-size:0.9em; max-height:300px; overflow-y:auto;}
        .footer { font-size: .85em; text-align: center; color: #6c757d; margin-top: 20px; padding-top: 10px; border-top:1px solid #ccc; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header"><h2>${title}</h2></div>
        <div class="status ${status_class_arg}">${status_message_arg}</div>
        <h3>Details:</h3>
        ${details_html}
        ${log_snippet_html}
        <div class="footer">
            <p>Report generated on ${script_end_time} by ${EFFECTIVE_HOSTNAME_LABEL}<br>
            Script duration: ${duration_msg}</p>
        </div>
    </div>
</body>
</html>
EOF
}

send_html_email() {
    local subject_base="$1"
    local status_class="$2" 
    local status_message="$3" 
    local details_html="$4"
    local script_start_time="$5"

    local full_subject="${EFFECTIVE_HOSTNAME_LABEL}: ${subject_base}"
    
    local html_body
    html_body=$(generate_html_email_body "${EFFECTIVE_HOSTNAME_LABEL} - ${subject_base}" "$status_class" "$status_message" "$details_html" "$script_start_time")

    if [ ! -f "$MSMTP_CONFIG_TO_USE" ]; then
        log_message "ERROR" "msmtp configuration file not found: $MSMTP_CONFIG_TO_USE. Cannot send email."
        return 1 
    fi
    
    # Ensure msmtp log directory exists
    mkdir -p "$(dirname "$MSMTP_LOG_TO_USE")"

    printf "To: %s\nSubject: %s\nContent-Type: text/html; charset=utf-8\nMIME-Version: 1.0\n\n%s" \
           "$RECIPIENT_EMAIL" "$full_subject" "$html_body" | \
    msmtp --file="$MSMTP_CONFIG_TO_USE" --logfile="$MSMTP_LOG_TO_USE" -a "$MSMTP_ACCOUNT_TO_USE" "$RECIPIENT_EMAIL"
    
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to send email: $full_subject"
    else
        log_message "INFO" "Email sent successfully: $full_subject"
    fi
}

# --- Main Script ---
SCRIPT_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# Ensure log directory from config.sh is usable
mkdir -p "$LOG_DIR" || { 
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to create universal log directory $LOG_DIR. Exiting." >&2; 
    # Attempt to send critical email if basic email vars are available
    if [ -n "$RECIPIENT_EMAIL" ] && [ -n "$EFFECTIVE_HOSTNAME_LABEL" ]; then
      send_html_email "Cloudflared Update CRITICAL Failure" "status-failure" "❌ Critical Error: Log Directory Creation Failed" "<p>Failed to create log directory: ${LOG_DIR}. Script cannot continue.</p>" "$SCRIPT_START_TIME"
    fi
    exit 1; 
}

rotate_log_file 

log_message "INFO" "Starting Cloudflared Docker update check for compose file: $DOCKER_COMPOSE_FILE"

for cmd_check in docker msmtp; do # msmtp is checked by send_html_email, but good to pre-check
    if ! command -v "$cmd_check" &> /dev/null; then
        log_message "ERROR" "$cmd_check is not installed. Please install $cmd_check and try again."
        send_html_email "Cloudflared Update Failure" "status-failure" "❌ Critical Error: $cmd_check not found" "<p>$cmd_check is not installed. Script cannot continue.</p>" "$SCRIPT_START_TIME"
        exit 1
    fi
done

# Check for 'docker compose' (v2) specifically
if ! docker compose version &> /dev/null; then
     log_message "ERROR" "docker compose (v2) is not installed or not working. Please install/configure docker compose v2 and try again."
     send_html_email "Cloudflared Update Failure" "status-failure" "❌ Critical Error: docker compose not found/working" "<p>docker compose (v2) is not installed or not working. Script cannot continue.</p>" "$SCRIPT_START_TIME"
     exit 1
fi

if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    log_message "ERROR" "Docker Compose file not found: $DOCKER_COMPOSE_FILE"
    send_html_email "Cloudflared Update Failure" "status-failure" "❌ Configuration Error" "<p>Docker Compose file not found at: ${DOCKER_COMPOSE_FILE}</p>" "$SCRIPT_START_TIME"
    exit 1
fi

log_message "INFO" "Pulling the latest Docker image(s) defined in $DOCKER_COMPOSE_FILE..."
docker_pull_output=$(docker compose -f "$DOCKER_COMPOSE_FILE" pull 2>&1)
pull_exit_code=$?

details_html="<table class='details-table'><tr><th>Step</th><th>Status</th></tr>"
details_html+="<tr><td>Docker Image Pull</td>"

if [ $pull_exit_code -ne 0 ]; then
    log_message "ERROR" "Failed to pull the latest Docker image(s)."
    log_message "ERROR" "Docker Pull Output: $docker_pull_output" 
    details_html+="<td style='color:red;'>Failed</td></tr></table>"
    details_html+="<h4>Docker Pull Output:</h4><pre>$(echo "$docker_pull_output" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
    send_html_email "Cloudflared Update Failure" "status-failure" "❌ Docker Image Pull Failed" "$details_html" "$SCRIPT_START_TIME"
    exit 1
fi
log_message "INFO" "Successfully pulled Docker image(s)."
details_html+="<td style='color:green;'>Success</td></tr>"
details_html+="<tr><td colspan='2'><h4>Docker Pull Output (Last 20 lines):</h4><pre>$(echo "$docker_pull_output" | tail -n 20 | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre></td></tr>"

log_message "INFO" "Recreating and restarting the container(s) defined in $DOCKER_COMPOSE_FILE..."
docker_up_output=$(docker compose -f "$DOCKER_COMPOSE_FILE" up -d --remove-orphans 2>&1) # Added --remove-orphans
up_exit_code=$?

details_html+="<tr><td>Container Restart</td>"
if [ $up_exit_code -ne 0 ]; then
    log_message "ERROR" "Failed to recreate and restart the container(s)."
    log_message "ERROR" "Docker Up Output: $docker_up_output" 
    details_html+="<td style='color:red;'>Failed</td></tr></table>" 
    details_html+="<h4>Docker Up Output:</h4><pre>$(echo "$docker_up_output" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
    send_html_email "Cloudflared Update Failure" "status-failure" "❌ Container Restart Failed" "$details_html" "$SCRIPT_START_TIME"
    exit 1
fi

log_message "INFO" "Successfully recreated and restarted container(s)."
details_html+="<td style='color:green;'>Success</td></tr></table>" 
details_html+="<h4>Docker Up Output (Last 20 lines):</h4><pre>$(echo "$docker_up_output" | tail -n 20 | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"

log_message "INFO" "Cloudflared Docker container(s) have been updated and restarted successfully."
send_html_email "Cloudflared Update Success" "status-success" "✅ Cloudflared Update Successful" "$details_html" "$SCRIPT_START_TIME"

exit 0
