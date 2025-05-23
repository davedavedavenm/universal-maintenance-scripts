#!/bin/bash
#
# backup_system_tarball.sh - VPS Backup Script with Local Rotation and Rclone Offsite
# (Formerly backup_vps.sh)

set -euo pipefail # IMPORTANT: Exit on error, undefined variable, pipe failure

# --- Configuration (Sourced from config.sh) ---
CONFIG_FILE="$(dirname "$0")/config.sh"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Main configuration file $CONFIG_FILE not found. Exiting." >&2
    exit 1
fi

# --- Script Specific Configuration ---
VPS_NAME="${PI_HOSTNAME:-$(hostname)}"
EMAIL_TO="${PI_EMAIL}"
MSMTP_CONFIG_FILE="${PI_MSMTP_CONFIG}"
MSMTP_ACCOUNT="default"

SCRIPT_LOG_DIR="${PI_LOGS_DIR}"
SCRIPT_LOG_FILE="${SCRIPT_LOG_DIR}/${VPS_NAME}_backup_system_tarball.log"
MAX_SCRIPT_LOG_ARCHIVES=5

LOCAL_BACKUP_STAGING_DIR="/backup/vps_archives" # This is a dedicated FS or dir for backups
NUM_LOCAL_BACKUPS_TO_KEEP=4

RCLONE_REMOTE_NAME="hetz-vps-arm-backup" 
RCLONE_REMOTE_BASE_PATH="${PI_CLOUD_FOLDER}"
RCLONE_CONFIG_FILE="${PI_RCLONE_CONFIG}"

DIRECTORIES_TO_BACKUP=(
    "/etc/"
    "/home/dave/" # This will include /home/dave/scripts unless excluded
    "/root/"
    "/var/www/"
    "/opt/"
    "/usr/local/bin/"
    "/usr/local/sbin/"
    "/data/"
)

# Tar exclude options
# Paths here should be relative to the items in DIRECTORIES_TO_BACKUP after -C /
# Or absolute paths if they refer to system-wide locations not covered by sources.
TAR_EXCLUDE_OPTS=(
    # --- CRITICAL EXCLUDE FOR /home/dave/scripts ---
    "--exclude=home/dave/scripts" # Excludes the entire /home/dave/scripts directory

    # Excludes within home/dave (these are now more specific if home/dave/scripts is out)
    "--exclude=home/dave/.pm2/pub.sock"
    "--exclude=home/dave/.pm2/rpc.sock"
    "--exclude=home/dave/*/.cache" 
    "--exclude=home/dave/vps_maintenance_logs/*_backup_system_tarball.log.*.gz" # More specific log exclude

    # Excludes within root
    "--exclude=root/.local/share/pnpm/store"

    # General patterns (tar applies these anywhere)
    "--exclude=*.bak"
    "--exclude=*.tmp"
    # "--exclude=*.log.?" # Might be too broad, specific log excludes are better
    # "--exclude=*.log.*.gz" # Might be too broad
    "--exclude=*/.cache/*" # Good general cache exclude
    "--exclude=*/node_modules/*"
    "--exclude=*/vendor/*"

    # Important system-level or absolute path excludes
    "--exclude=${LOCAL_BACKUP_STAGING_DIR}" # Absolute path, e.g., /backup/vps_archives
    "--exclude=/proc" 
    "--exclude=/sys"
    "--exclude=/dev"
    "--exclude=/run"
    "--exclude=/mnt"
    "--exclude=/media"
    "--exclude=/tmp"  # Excludes /tmp directory itself when -C / is used
    "--exclude=/var/tmp" 
    "--exclude=/var/cache/apt/archives" 
    "--exclude=/lost+found" 
)

CONTAINERS_TO_MANAGE=(
    "watchtower"               
    "portainer"                
    "hbbs"                     
    "hbbr"                     
    "oauth2-proxy"             
    "pangolin"                 
    "authelia"                 
    "linkwarden-linkwarden-1"  
)
DOCKER_START_DELAY_SECONDS=5

POSTGRES_CONTAINER_NAME="linkwarden-postgres-1"
POSTGRES_USER="postgres"
DB_DUMP_SUBDIR="db_dumps" # This will be under /home/dave/ as PRE_BACKUP_FILES_DIR is /home/dave
DB_DUMP_BASENAME="postgres_linkwarden_all_$(date +%Y%m%d).sql"

LOCK_FILE="/tmp/${VPS_NAME}_backup_system_tarball.lock"
PREVIOUSLY_RUNNING_CONTAINERS=()

# --- Ensure Root Execution ---
if [[ $EUID -ne 0 ]]; then
   echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - This script must be run as root. Exiting." >&2
   exit 1
fi

# --- Lock File ---
if [ -f "$LOCK_FILE" ]; then
    LOCK_PID=$(head -n 1 "$LOCK_FILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && ps -p "$LOCK_PID" > /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Lock file $LOCK_FILE exists and process $LOCK_PID is running. Exiting." >&2
        exit 1
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARNING] - Stale lock file $LOCK_FILE found (PID: $LOCK_PID). Removing." >&2
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"

# --- Trap Handling ---
trap 'rm -f "$LOCK_FILE"; log_message "INFO" "Removed lock file on normal script exit."' EXIT
trap 'log_message "ERROR_TRAP" "Error trap triggered (Signal: $?, Line: $LINENO, Command: $BASH_COMMAND). Calling handle_error."; rm -f "$LOCK_FILE"; handle_error $? $LINENO "$BASH_COMMAND"' ERR SIGINT SIGTERM

# --- Setup and Helper Functions ---
mkdir -p "$SCRIPT_LOG_DIR" || { 
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to create script log dir $SCRIPT_LOG_DIR. Lock file $LOCK_FILE removed." >&2; 
    rm -f "$LOCK_FILE"; 
    exit 1; 
}
touch "$SCRIPT_LOG_FILE" || { 
    echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to touch script log $SCRIPT_LOG_FILE. Lock file $LOCK_FILE removed." >&2; 
    rm -f "$LOCK_FILE"; 
    exit 1; 
}

log_message() {
    local level="$1"; local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] - $message" >> "$SCRIPT_LOG_FILE"
}

rotate_script_logs() {
    log_message "DEBUG" "Rotating script operational logs for $SCRIPT_LOG_FILE..."
    local current_log_content_exists=false
    if [ -s "$SCRIPT_LOG_FILE" ]; then current_log_content_exists=true; fi
    local archive_suffix 
    
    find "$SCRIPT_LOG_DIR" -name "$(basename "$SCRIPT_LOG_FILE").*.gz" -type f -printf '%T@ %p\n' | \
        sort -nr | tail -n +$((MAX_SCRIPT_LOG_ARCHIVES + 1)) | cut -d' ' -f2- | xargs -I {} rm -f {}
    
    if $current_log_content_exists; then
        archive_suffix=$(date +%Y%m%d_%H%M%S_%N) 
        if gzip -c "$SCRIPT_LOG_FILE" > "${SCRIPT_LOG_FILE}.${archive_suffix}.tmp.gz"; then
            mv "${SCRIPT_LOG_FILE}.${archive_suffix}.tmp.gz" "${SCRIPT_LOG_FILE}.${archive_suffix}.gz"
            truncate -s 0 "$SCRIPT_LOG_FILE"
            log_message "INFO" "Previous script log content rotated to ${SCRIPT_LOG_FILE}.${archive_suffix}.gz."
        else
            log_message "ERROR" "Failed to gzip current script log ${SCRIPT_LOG_FILE}. Old log not truncated."
            rm -f "${SCRIPT_LOG_FILE}.${archive_suffix}.tmp.gz" 
        fi
    else 
        log_message "DEBUG" "Current script log $SCRIPT_LOG_FILE is empty, no rotation of content needed."
    fi
}
rotate_script_logs

generate_email_html() { 
    local title="$1"; local status_class="$2"; local status_message="$3"; local details_html="$4"
    local current_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    cat <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font-family:Arial,sans-serif;margin:0;padding:0;background-color:#f4f4f4}.container{max-width:750px;margin:20px auto;background-color:#fff;padding:20px;border-radius:8px;box-shadow:0 0 10px rgba(0,0,0,.1)}.header{background-color:#17a2b8;color:#fff;padding:10px 0;text-align:center;border-radius:8px 8px 0 0}.header h2{margin:0}.status{padding:15px;margin:15px 0;border-radius:4px;font-weight:700}.status-success{background-color:#d4edda;color:#155724;border-left:5px solid #155724}.status-failure{background-color:#f8d7da;color:#721c24;border-left:5px solid #721c24}.status-warning{background-color:#fff3cd;color:#856404;border-left:5px solid #856404}table{width:100%;border-collapse:collapse;margin-bottom:15px}th,td{border:1px solid #ddd;padding:8px;text-align:left;font-size:0.9em}th{background-color:#f2f2f2}pre{white-space:pre-wrap;word-wrap:break-word;background-color:#f5f5f5;border:1px solid #ccc;padding:10px;max-height:300px;overflow-y:auto;font-size:0.85em}.footer{font-size:.8em;text-align:center;color:#777;margin-top:20px}</style></head><body><div class="container"><div class="header"><h2>${title}</h2></div><div class="status ${status_class}">${status_message}</div><div>${details_html}</div><div class="footer"><p>Report generated on ${current_timestamp} by ${VPS_NAME}</p></div></div></body></html>
EOF
}

send_html_notification() { 
    local subject_base="$1"; local status_class="$2"; local status_message_text="$3"; local details_content_html="$4"
    local full_subject="[${VPS_NAME} Backup] ${subject_base}"
    local html_body
    html_body=$(generate_email_html "[${VPS_NAME}] Backup Report: ${subject_base}" "$status_class" "$status_message_text" "$details_content_html")
    if [ ! -f "$MSMTP_CONFIG_FILE" ]; then log_message "ERROR" "msmtp config: $MSMTP_CONFIG_FILE not found."; return 1; fi
    
    local msmtp_cmd_output
    local msmtp_exit_code
    msmtp_cmd_output=$(printf "To:%s\nSubject:%s\nContent-Type:text/html;charset=utf-8\nMIME-Version:1.0\n\n%s" "$EMAIL_TO" "$full_subject" "$html_body" | msmtp --file="$MSMTP_CONFIG_FILE" -a "$MSMTP_ACCOUNT" "$EMAIL_TO" 2>&1)
    msmtp_exit_code=$?
    
    if [ $msmtp_exit_code -ne 0 ]; then 
        log_message "ERROR" "msmtp failed (code $msmtp_exit_code): $full_subject. Output: $msmtp_cmd_output"
    else 
        log_message "INFO" "Email sent: $full_subject"
    fi
    return $msmtp_exit_code
}

handle_error() { 
    local exit_code="$1"
    local line_number="$2"
    local failed_command="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # OVERALL_SUCCESS might not be reliable if script exits early due to set -e
    # but we log the error that ERR trap caught.
    local error_message_log="Error caught by handle_error on line $line_number: Exit code $exit_code for command: [$failed_command]"
    log_message "FATAL_ERROR_HANDLER" "$error_message_log" 
    
    if [ ${#PREVIOUSLY_RUNNING_CONTAINERS[@]} -gt 0 ]; then
        log_message "ERROR_HANDLER" "Attempting emergency restart of previously running containers..."
        for container_name in "${PREVIOUSLY_RUNNING_CONTAINERS[@]}"; do
            log_message "INFO_HANDLER" "Emergency restarting $container_name"
            # Don't let failure here cause another ERR trap loop if docker start fails
            docker start "$container_name" >/dev/null 2>&1 || log_message "WARNING_HANDLER" "Failed to restart $container_name after script error (command failed or already running)."
            if docker ps --format "{{.Names}}" | grep -qw "$container_name"; then
                 log_message "INFO_HANDLER" "$container_name is now running after script error."
            else
                 log_message "WARNING_HANDLER" "$container_name still not running after attempt."
            fi
        done
    else
        log_message "INFO_HANDLER" "No containers in PREVIOUSLY_RUNNING_CONTAINERS list to attempt restart."
    fi
    
    local error_details_html="<p>Script failed on line ${line_number} with exit code ${exit_code} at ${timestamp}.</p><p>Failed command:</p><pre>$(echo "$failed_command" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre><h4>Log Snippet (Last 20 lines):</h4><pre>$(tail -n 20 "$SCRIPT_LOG_FILE" 2>/dev/null | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
    
    if [[ "$failed_command" != *"send_html_notification"* && "$failed_command" != *"msmtp"* ]]; then
        log_message "ERROR_HANDLER" "Attempting to send failure notification email."
        send_html_notification "FAILURE" "status-failure" "❌ Backup Script Failed" "$error_details_html" || log_message "ERROR_HANDLER" "Sending failure email itself failed."
    else 
        log_message "ERROR_HANDLER" "Error occurred within notification handler itself or msmtp. Suppressing recursive email."
    fi
    # ERR trap will cause exit after this function.
}

stop_docker_containers() { 
    log_message "INFO" "Stopping specified Docker containers if they are running..."
    PREVIOUSLY_RUNNING_CONTAINERS=() 
    for container_name in "${CONTAINERS_TO_MANAGE[@]}"; do
        if docker ps --format "{{.Names}}" | grep -qw "$container_name"; then
            log_message "INFO" "Container $container_name is running. Adding to list and stopping."
            PREVIOUSLY_RUNNING_CONTAINERS+=("$container_name")
            docker stop "$container_name" # If this fails, set -e will trigger ERR trap
            log_message "INFO" "Successfully stopped $container_name."
        else 
            log_message "INFO" "Container $container_name not running or does not exist, skipping stop."
        fi
    done
}

start_docker_containers() { 
    log_message "INFO" "Starting Docker containers that were previously running..."
    if [ ${#PREVIOUSLY_RUNNING_CONTAINERS[@]} -eq 0 ]; then
        log_message "INFO" "No managed containers were previously running to restart now."
        return
    fi
    for container_name in "${PREVIOUSLY_RUNNING_CONTAINERS[@]}"; do
        log_message "INFO" "Attempting to start container: $container_name"
        docker start "$container_name" # If this fails, set -e will trigger ERR trap
        log_message "INFO" "Successfully started $container_name."
        if [[ "$container_name" == "pangolin" || "$container_name" == "traefik" ]]; then
            log_message "INFO" "Waiting ${DOCKER_START_DELAY_SECONDS}s for $container_name to initialize..."
            sleep "$DOCKER_START_DELAY_SECONDS"
        fi
    done
}

# --- Main Backup Logic ---
log_message "INFO" "===== Starting VPS Backup Process for ${VPS_NAME} ====="
EMAIL_DETAILS_HTML="<h3>Backup Process Summary:</h3><ul>"
# OVERALL_SUCCESS is less critical with set -e as script exits on first error.
# It's useful if we have steps that can "fail" but are not critical enough to halt the script.

# 1. Pre-Backup Tasks
log_message "INFO" "Generating pre-backup files..."
PRE_BACKUP_FILES_DIR="/home/dave" 
mkdir -p "$PRE_BACKUP_FILES_DIR" 
if ! apt-mark showmanual > "${PRE_BACKUP_FILES_DIR}/vps_manual_packages.list"; then log_message "WARNING" "Failed to save manual package list. Continuing."; fi
if ! crontab -l -u dave > "${PRE_BACKUP_FILES_DIR}/crontab_dave.bak" 2>/dev/null; then log_message "INFO" "No crontab for dave or error saving. Continuing."; fi
if ! crontab -l -u root > "${PRE_BACKUP_FILES_DIR}/crontab_root.bak" 2>/dev/null; then log_message "INFO" "No crontab for root or error saving. Continuing."; fi
if [ -f "${PRE_BACKUP_FILES_DIR}/vps_manual_packages.list" ]; then chown dave:dave "${PRE_BACKUP_FILES_DIR}/vps_manual_packages.list"; fi
if [ -f "${PRE_BACKUP_FILES_DIR}/crontab_dave.bak" ]; then chown dave:dave "${PRE_BACKUP_FILES_DIR}/crontab_dave.bak"; fi
if [ -f "${PRE_BACKUP_FILES_DIR}/crontab_root.bak" ]; then chown dave:dave "${PRE_BACKUP_FILES_DIR}/crontab_root.bak"; fi
EMAIL_DETAILS_HTML+="<li>✅ Pre-backup files generated (warnings if any are logged).</li>"

# 2. PostgreSQL Dump
DB_DUMP_TARGET_DIR="${PRE_BACKUP_FILES_DIR}/${DB_DUMP_SUBDIR}"
mkdir -p "$DB_DUMP_TARGET_DIR"; chown dave:dave "$DB_DUMP_TARGET_DIR"
DB_DUMP_SQL_FILE="${DB_DUMP_TARGET_DIR}/${DB_DUMP_BASENAME}"; DB_DUMP_GZ_FILE="${DB_DUMP_SQL_FILE}.gz"
DB_DUMP_SQL_FILE_TMP="${DB_DUMP_SQL_FILE}.tmpdump"
log_message "INFO" "Starting PostgreSQL dump for container ${POSTGRES_CONTAINER_NAME}..."
if ! docker ps --format "{{.Names}}" | grep -qw "$POSTGRES_CONTAINER_NAME"; then
    log_message "ERROR" "PostgreSQL container ${POSTGRES_CONTAINER_NAME} not running. Skipping dump."
    EMAIL_DETAILS_HTML+="<li>❌ PostgreSQL dump: Container ${POSTGRES_CONTAINER_NAME} not running.</li>"; # OVERALL_SUCCESS=false (less relevant with set -e)
else
    log_message "INFO" "Dumping to $DB_DUMP_SQL_FILE_TMP via docker exec..."
    # If docker exec or pg_dumpall fails, set -e will trigger ERR trap
    docker exec -t "$POSTGRES_CONTAINER_NAME" pg_dumpall -U "$POSTGRES_USER" > "$DB_DUMP_SQL_FILE_TMP"
    mv "$DB_DUMP_SQL_FILE_TMP" "$DB_DUMP_SQL_FILE"
    gzip -f "$DB_DUMP_SQL_FILE" # If gzip fails, set -e triggers ERR trap
    log_message "INFO" "PostgreSQL dump compressed to ${DB_DUMP_GZ_FILE}"; chown dave:dave "$DB_DUMP_GZ_FILE"; chmod 600 "$DB_DUMP_GZ_FILE"
    EMAIL_DETAILS_HTML+="<li>✅ PostgreSQL dump successful: $(basename "$DB_DUMP_GZ_FILE")</li>"
fi

# 3. Stop Docker Containers
stop_docker_containers 
EMAIL_DETAILS_HTML+="<li>✅ Docker containers stopped (those that were running).</li>"; log_message "INFO" "Waiting 5s after stopping containers..."; sleep 5

# 4. Rotate & Create Tarball
log_message "INFO" "Rotating local archives in ${LOCAL_BACKUP_STAGING_DIR}..."
mkdir -p "$LOCAL_BACKUP_STAGING_DIR" 
OLDEST_BACKUP_NUM=$((NUM_LOCAL_BACKUPS_TO_KEEP - 1))
if [ -f "${LOCAL_BACKUP_STAGING_DIR}/backup.${OLDEST_BACKUP_NUM}.tar.gz" ]; then
    log_message "INFO" "Deleting oldest: backup.${OLDEST_BACKUP_NUM}.tar.gz and manifest."
    rm -f "${LOCAL_BACKUP_STAGING_DIR}/backup.${OLDEST_BACKUP_NUM}.tar.gz" "${LOCAL_BACKUP_STAGING_DIR}/backup.${OLDEST_BACKUP_NUM}.manifest.txt"
fi
for i in $(seq $OLDEST_BACKUP_NUM -1 1); do
    if [ -f "${LOCAL_BACKUP_STAGING_DIR}/backup.$((i-1)).tar.gz" ]; then
        log_message "INFO" "Shifting backup.$((i-1)) to backup.$i"
        mv "${LOCAL_BACKUP_STAGING_DIR}/backup.$((i-1)).tar.gz" "${LOCAL_BACKUP_STAGING_DIR}/backup.$i.tar.gz"
        if [ -f "${LOCAL_BACKUP_STAGING_DIR}/backup.$((i-1)).manifest.txt" ]; then
             mv "${LOCAL_BACKUP_STAGING_DIR}/backup.$((i-1)).manifest.txt" "${LOCAL_BACKUP_STAGING_DIR}/backup.$i.manifest.txt"
        fi
    fi
done
CURRENT_BACKUP_TAR_FILE="${LOCAL_BACKUP_STAGING_DIR}/backup.0.tar.gz"; CURRENT_BACKUP_MANIFEST_FILE="${LOCAL_BACKUP_STAGING_DIR}/backup.0.manifest.txt"
log_message "INFO" "Creating new archive: $CURRENT_BACKUP_TAR_FILE"
TAR_START_TIME=$(date +%s); EXCLUDES_STRING=""; for opt in "${TAR_EXCLUDE_OPTS[@]}"; do EXCLUDES_STRING+=" $opt"; done
RELATIVE_TAR_SOURCES_STRING=""; for src_dir in "${DIRECTORIES_TO_BACKUP[@]}"; do RELATIVE_TAR_SOURCES_STRING+=" $(echo "$src_dir" | sed 's|^/||') "; done
log_message "DEBUG" "Tar command: tar -czf \"$CURRENT_BACKUP_TAR_FILE\" -C / $EXCLUDES_STRING $RELATIVE_TAR_SOURCES_STRING"

tar_exit_code=0
tar_stderr_output=""
# Execute tar and capture its stderr; stdout (file list for -v) goes to /dev/null for -c
tar_stderr_output=$(tar -czf "$CURRENT_BACKUP_TAR_FILE" -C / $EXCLUDES_STRING $RELATIVE_TAR_SOURCES_STRING 2>&1 >/dev/null)
tar_exit_code=$?
filtered_tar_stderr=$(echo "$tar_stderr_output" | grep -v "socket ignored" | grep -v "tar: Option --exclude is obsolete" | grep -v "tar: Ignoring unknown extended header keyword" | grep -v "Removing leading \`/' from member names" || true)

if [ $tar_exit_code -eq 0 ] || { [ $tar_exit_code -eq 1 ] && echo "$tar_stderr_output" | grep -q "some files differ"; }; then
    if [ $tar_exit_code -eq 1 ]; then
        log_message "WARNING" "tar command exited with 1 (some files may have changed during backup). Archive still created."
        log_message "DEBUG" "Raw tar stderr for exit code 1: $tar_stderr_output"
    fi
    if [ -n "$filtered_tar_stderr" ]; then 
        log_message "WARNING" "tar generated other stderr messages (beyond common warnings): $filtered_tar_stderr"
    fi

    TAR_END_TIME=$(date +%s); TAR_DURATION=$((TAR_END_TIME - TAR_START_TIME))
    TAR_SIZE_HUMAN=$(du -sh "$CURRENT_BACKUP_TAR_FILE" 2>/dev/null || echo "N/A") 
    log_message "INFO" "Archive created: $CURRENT_BACKUP_TAR_FILE (Size: $TAR_SIZE_HUMAN, Duration: ${TAR_DURATION}s)."
    EMAIL_DETAILS_HTML+="<li>✅ New archive created: backup.0.tar.gz (Size: $TAR_SIZE_HUMAN)</li>"
    
    log_message "INFO" "Creating manifest: $CURRENT_BACKUP_MANIFEST_FILE"
    { echo "Backup Job: ${VPS_NAME} Full Backup"; echo "Timestamp: $(date --iso-8601=seconds)"; echo "Hostname: ${VPS_NAME}"
      echo "Archive File: backup.0.tar.gz"; echo "Archive Size: $TAR_SIZE_HUMAN"
      echo "MD5Sum: $(md5sum "$CURRENT_BACKUP_TAR_FILE" | awk '{print $1}')"; echo "SHA256Sum: $(sha256sum "$CURRENT_BACKUP_TAR_FILE" | awk '{print $1}')"; echo ""
      echo "Included Sources:"; for src_dir in "${DIRECTORIES_TO_BACKUP[@]}"; do echo "  - $src_dir"; done; echo ""
      echo "Excludes:"; for opt in "${TAR_EXCLUDE_OPTS[@]}"; do echo "  - $opt"; done;
    } > "$CURRENT_BACKUP_MANIFEST_FILE" 
    log_message "INFO" "Manifest created."; EMAIL_DETAILS_HTML+="<li>✅ Manifest created.</li>"
else
    log_message "ERROR" "Failed to create archive $CURRENT_BACKUP_TAR_FILE. tar actual exit: $tar_exit_code"
    log_message "ERROR" "tar stderr output was: $tar_stderr_output"
    EMAIL_DETAILS_HTML+="<li>❌ Failed: Create local archive. Tar command failed with exit code $tar_exit_code.</li>"
    # set -e will trigger ERR trap and call handle_error, which will exit.
    # No need for explicit exit here if set -e is active.
fi

# 5. Start Docker Containers
start_docker_containers 
EMAIL_DETAILS_HTML+="<li>✅ Docker containers restarted (those previously running).</li>"

# 6. Rclone Sync
# Check OVERALL_SUCCESS becomes less critical with set -e, but good for gating optional steps
# For this, we must have a successful tarball.
if [ -f "$CURRENT_BACKUP_TAR_FILE" ]; then # Check if tarball was actually created
    log_message "INFO" "Rclone: Syncing $LOCAL_BACKUP_STAGING_DIR/ to ${RCLONE_REMOTE_NAME}:${RCLONE_REMOTE_BASE_PATH}/"
    RCLONE_LOG_OUTPUT_FILE="${SCRIPT_LOG_DIR}/rclone_sync_output.log"; truncate -s 0 "$RCLONE_LOG_OUTPUT_FILE"
    if [ ! -f "$RCLONE_CONFIG_FILE" ]; then
        log_message "ERROR" "Rclone config $RCLONE_CONFIG_FILE not found. Cannot sync."
        EMAIL_DETAILS_HTML+="<li>❌ Rclone: Config $RCLONE_CONFIG_FILE not found.</li>"
        # This error will cause script exit due to set -e
    else
        # If rclone sync fails, set -e will trigger ERR trap.
        rclone sync "$LOCAL_BACKUP_STAGING_DIR/" "${RCLONE_REMOTE_NAME}:${RCLONE_REMOTE_BASE_PATH}/" \
            --config "$RCLONE_CONFIG_FILE" --verbose --log-file="$RCLONE_LOG_OUTPUT_FILE" \
            --stats-one-line --stats=10s --retries 3 --low-level-retries 10 --delete-during
        log_message "INFO" "Rclone sync completed (check log for actual success/failure from rclone)."
        EMAIL_DETAILS_HTML+="<li>✅ Rclone sync initiated (see rclone log for details).</li>"
        EMAIL_DETAILS_HTML+="<li>Rclone Log: <pre>$(cat "$RCLONE_LOG_OUTPUT_FILE" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre></li>"
    fi
else 
    log_message "WARNING" "Skipping rclone: Backup tarball $CURRENT_BACKUP_TAR_FILE was not found (likely due to tar failure)."
    EMAIL_DETAILS_HTML+="<li>⚠️ Rclone sync skipped (tarball not found).</li>"
fi

# 7. Final Email
EMAIL_DETAILS_HTML+="</ul>" 
# With set -e, if we reach here, all previous critical commands succeeded.
# OVERALL_SUCCESS is mostly redundant but can catch non-critical warnings.
log_message "INFO" "===== VPS Backup Process Completed Successfully (all critical steps passed) ====="
send_html_notification "SUCCESS" "status-success" "✅ Backup Completed Successfully" "$EMAIL_DETAILS_HTML"


log_message "INFO" "Backup script finished."
exit 0
