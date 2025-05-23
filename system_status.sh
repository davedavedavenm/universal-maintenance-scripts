#!/bin/bash
#
# VPS System Status Script (Adapted Version)
# Provides system status reports via HTML email
#

# --- Configuration ---
CONFIG_FILE="$(dirname "$0")/config.sh"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file $CONFIG_FILE not found. Exiting." >&2
    exit 1
fi

EMAIL_TO="${PI_EMAIL:-your-email@example.com}"
VPS_USER="${PI_USER:-$(whoami)}"
VPS_HOSTNAME="${PI_HOSTNAME:-$(hostname)}"
# If run by root cron, it should use PI_MSMTP_CONFIG which is /etc/msmtprc
MSMTP_CONFIG_TO_USE="$PI_MSMTP_CONFIG"

PI_EMAIL_FROM="${PI_EMAIL_FROM:-}"

LOG_DIR_STATUS_SCRIPT="${PI_LOGS_DIR}"
LOG_FILE="${LOG_DIR_STATUS_SCRIPT}/system_status_generation.log"
MAX_LOG_ARCHIVES=5

SUBJECT_PREFIX="${VPS_HOSTNAME} Status Report"

UPDATE_LOG_DIR="${PI_LOGS_DIR}"
BACKUP_LOG_DIR="${PI_LOGS_DIR}"
UPDATE_LOG_FILE_PATTERN="${UPDATE_LOG_DIR}/${VPS_HOSTNAME}_system_update.log*"
BACKUP_LOG_FILE_PATTERN="${BACKUP_LOG_DIR}/${VPS_HOSTNAME}_backup_system_tarball.log"


# --- Error Handling & Setup ---
set -uo pipefail
mkdir -p "$LOG_DIR_STATUS_SCRIPT" || { echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] - Failed to create log directory $LOG_DIR_STATUS_SCRIPT. Exiting." >&2; exit 1; }

# --- Helper Functions ---
log_message() {
    local level="$1"; local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] - $message" >> "$LOG_FILE"
}

initial_log_rotation() {
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" || { log_message "ERROR" "Failed to touch log file $LOG_FILE"; exit 1; }
        log_message "INFO" "Log file $LOG_FILE created."
        return
    fi
    if [ -s "$LOG_FILE" ]; then
      local archive_timestamp; archive_timestamp=$(date +%Y%m%d_%H%M%S_%N)
      local temp_archive_name="${LOG_FILE}.${archive_timestamp}.tmp.gz"
      local final_archive_name="${LOG_FILE}.${archive_timestamp}.gz"
      if gzip -c "$LOG_FILE" > "$temp_archive_name"; then
        mv "$temp_archive_name" "$final_archive_name"
        truncate -s 0 "$LOG_FILE"
        log_message "INFO" "Main log rotated to ${final_archive_name}"
      else
        log_message "ERROR" "Failed to gzip log file $LOG_FILE to $temp_archive_name. Log not truncated."
        rm -f "$temp_archive_name"; return 1;
      fi
      find "$LOG_DIR_STATUS_SCRIPT" -maxdepth 1 -name "$(basename "$LOG_FILE").*.gz" -type f -printf '%T@ %p\n' | \
          sort -nr | tail -n +$((MAX_LOG_ARCHIVES + 1)) | cut -d' ' -f2- | xargs -I {} rm -f {} && \
          log_message "INFO" "Old log archives cleaned up, kept latest $MAX_LOG_ARCHIVES."
    fi
}

get_cmd_output() {
    local cmd_string="$1"; local output; local exit_code
    output=$(eval "$cmd_string" 2>&1); exit_code=$?
    if [ $exit_code -ne 0 ]; then
        local short_raw_output; short_raw_output=$(echo "$output" | head -c 500)
        log_message "WARNING" "Command failed (exit $exit_code): [$cmd_string] - Raw Output (partial): $short_raw_output"
        echo "Error executing command"; return 1
    else
        echo "$output"
    fi
}

check_service_html() {
    local service_name="$1"; local display_name="$2"; local status_text; local status_class; local detail_info
    if systemctl is-active --quiet "$service_name"; then
        status_text="✅ Active"; status_class="status-ok"
    else
        status_text="❌ Inactive"; status_class="status-error"
        detail_info=$(systemctl status "$service_name" 2>&1 || true)
        detail_info=$(echo "$detail_info" | grep -E 'Active:|Loaded:' | head -n 2 | sed 's/&/\&/g; s/</\</g; s/>/\>/g' | tr '\n' ' ')
        if [ -n "$detail_info" ]; then status_text+=" <small>($detail_info)</small>"; fi
        page_issues+=("Service $display_name is Inactive: $detail_info")
    fi
    echo "<tr><td>${display_name}</td><td><span class='${status_class}'>${status_text}</span></td></tr>"
}

generate_report_html() {
    local title="$1"; local overall_status_html="$2"; local sections_html_ref="$3"
    declare -n sections_html_arr="$sections_html_ref"; local current_timestamp; current_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local all_sections=""; for section in "${sections_html_arr[@]}"; do all_sections+="$section"; done
    cat <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><title>${title}</title><style>body{font-family:Verdana,Geneva,sans-serif;margin:0;padding:10px;background-color:#f8f9fa;color:#333;font-size:14px}h1,h3{color:#004085;margin-top:0}h3{margin-bottom:5px;border-bottom:1px solid #ccc;padding-bottom:3px}h4{margin-top:10px; margin-bottom:3px; color:#005095; font-size:1.1em;} .container{max-width:900px;margin:20px auto;background-color:#fff;padding:20px;border-radius:8px;box-shadow:0 0 15px rgba(0,0,0,.1)}.overall-status{padding:15px;margin-bottom:20px;border-radius:4px;font-weight:700;font-size:1.2em;text-align:center}.status-ok-bg{background-color:#d4edda;color:#155724;border:1px solid #c3e6cb}.status-warn-bg{background-color:#fff3cd;color:#856404;border:1px solid #ffeeba}.status-error-bg{background-color:#f8d7da;color:#721c24;border:1px solid #f5c6cb}.section{margin-bottom:20px;padding:15px;border:1px solid #e9ecef;border-radius:4px}table{width:100%;border-collapse:collapse;margin-top:10px}th,td{border:1px solid #dee2e6;padding:8px;text-align:left;vertical-align:top}th{background-color:#e9ecef;font-weight:700}td .status-ok{color:green;font-weight:700}td .status-warn{color:orange;font-weight:700}td .status-error{color:red;font-weight:700}pre{white-space:pre-wrap;word-wrap:break-word;background-color:#f1f1f1;border:1px solid #ddd;padding:10px;border-radius:4px;font-family:monospace;font-size:0.9em;max-height:300px;overflow-y:auto}ul{padding-left:20px}li{margin-bottom:5px}.footer{font-size:.85em;text-align:center;color:#6c757d;margin-top:20px;padding-top:10px;border-top:1px solid #ccc}</style></head><body><div class="container"><h1>${title}</h1>${overall_status_html}${all_sections}<div class="footer"><p>Report generated at ${current_timestamp} by ${VPS_HOSTNAME}</p></div></div></body></html>
EOF
}

send_report_email() {
    local subject="$1"; local html_body="$2"; local from_address_header=""
    if [ -n "${PI_EMAIL_FROM}" ]; then from_address_header="From: ${PI_EMAIL_FROM}\n"; fi
    if [ ! -f "$MSMTP_CONFIG_TO_USE" ]; then log_message "ERROR" "msmtp config not found: $MSMTP_CONFIG_TO_USE"; return 1; fi
    if command -v msmtp &>/dev/null; then
        printf "${from_address_header}To:%s\nSubject:%s\nContent-Type:text/html;charset=utf-8\nMIME-Version:1.0\n\n%s" "$EMAIL_TO" "$subject" "$html_body" | msmtp --file="$MSMTP_CONFIG_TO_USE" -a default "$EMAIL_TO"
        if [ $? -ne 0 ]; then log_message "ERROR" "msmtp send failed: $subject"; else log_message "INFO" "Email sent via msmtp: $subject"; fi
    elif command -v mail &>/dev/null; then
        printf "${from_address_header}To:%s\nSubject:%s\nContent-Type:text/html;charset=utf-8\nMIME-Version:1.0\n\n%s" "$EMAIL_TO" "$subject" "$html_body" | mail -s "$subject" "$EMAIL_TO"
        if [ $? -ne 0 ]; then log_message "ERROR" "mail send failed: $subject"; else log_message "INFO" "Email sent via mail: $subject"; fi
    else log_message "ERROR" "No suitable mail client found."; return 1; fi
}

# --- Main Script ---
initial_log_rotation
log_message "INFO" "System status report generation started for $VPS_HOSTNAME."
page_issues=()

# --- Section: System Health ---
html_sys_health="<div class='section'><h3>📊 System Health</h3><table>"
OS_INFO_TEXT_STATUS="<span class='status-warn'>N/A</span>"
if command -v lsb_release &> /dev/null; then
    OS_INFO_TEXT_STATUS_RAW=$(get_cmd_output "lsb_release -ds")
    if [[ "$OS_INFO_TEXT_STATUS_RAW" != "Error executing command" && -n "$OS_INFO_TEXT_STATUS_RAW" ]]; then
        OS_INFO_TEXT_STATUS=$(echo "$OS_INFO_TEXT_STATUS_RAW" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
    else
        log_message "WARNING" "OS Info: Error getting lsb_release -ds"
        page_issues+=("OS Info: Error getting lsb_release -ds")
        OS_INFO_TEXT_STATUS="<span class='status-error'>Error</span>"
    fi
elif [ -f /etc/os-release ]; then
    OS_INFO_TEXT_STATUS_RAW=$(get_cmd_output "grep PRETTY_NAME /etc/os-release | cut -d'=' -f2 | tr -d '\"'")
     if [[ "$OS_INFO_TEXT_STATUS_RAW" != "Error executing command" && -n "$OS_INFO_TEXT_STATUS_RAW" ]]; then
        OS_INFO_TEXT_STATUS=$(echo "$OS_INFO_TEXT_STATUS_RAW" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
    else
        log_message "WARNING" "OS Info: Error parsing /etc/os-release"
        page_issues+=("OS Info: Error parsing /etc/os-release")
        OS_INFO_TEXT_STATUS="<span class='status-error'>Error</span>"
    fi
else
    log_message "WARNING" "OS Info: Could not determine OS version"
    page_issues+=("OS Info: Could not determine OS version")
    OS_INFO_TEXT_STATUS="<span class='status-error'>Unknown</span>"
fi
html_sys_health+="<tr><td>OS Version</td><td>${OS_INFO_TEXT_STATUS}</td></tr>"

KERNEL_INFO_STATUS="<span class='status-warn'>N/A</span>"
KERNEL_INFO_RAW=$(get_cmd_output "uname -r")
if [[ "$KERNEL_INFO_RAW" != "Error executing command" && -n "$KERNEL_INFO_RAW" ]]; then
    KERNEL_INFO_STATUS=$(echo "$KERNEL_INFO_RAW" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
else
    log_message "WARNING" "Kernel Info: Error getting uname -r"
    page_issues+=("Kernel Info: Error getting uname -r")
    KERNEL_INFO_STATUS="<span class='status-error'>Error</span>"
fi
html_sys_health+="<tr><td>Kernel Version</td><td>${KERNEL_INFO_STATUS}</td></tr>"

disk_usage_root_full=$(get_cmd_output "df -h /")
disk_usage_root_main_line=$(echo "$disk_usage_root_full" | awk 'NR==2')
disk_percent=$(echo "$disk_usage_root_main_line" | awk '{print $5}' | sed 's/%//')
disk_free=$(echo "$disk_usage_root_main_line" | awk '{print $4}')
disk_status_class="status-ok"
if [[ "$disk_percent" =~ ^[0-9]+$ ]]; then
    if [ "$disk_percent" -gt 80 ] && [ "$disk_percent" -le 90 ]; then disk_status_class="status-warn"; page_issues+=("Disk usage at ${disk_percent}% (Warning)");
    elif [ "$disk_percent" -gt 90 ]; then disk_status_class="status-error"; page_issues+=("Disk usage at ${disk_percent}% (Critical)"); fi
    html_sys_health+="<tr><td>Disk Usage (/)</td><td><span class='${disk_status_class}'>${disk_percent}%</span> (Free: ${disk_free})</td></tr>"
else
    log_message "ERROR" "Could not parse disk usage percentage: $disk_percent"; html_sys_health+="<tr><td>Disk Usage (/)</td><td><span class='status-error'>Error parsing</span></td></tr>"; page_issues+=("Error parsing disk usage")
fi
mem_info_full=$(get_cmd_output "free -h")
mem_line=$(echo "$mem_info_full" | grep '^Mem:')
if [ -n "$mem_line" ]; then
    mem_total=$(echo "$mem_line" | awk '{print $2}'); mem_used=$(echo "$mem_line" | awk '{print $3}'); mem_available=$(echo "$mem_line" | awk '{print $7}')
    mem_used_val=$(echo "$mem_used" | sed 's/[A-Za-z]//g'); mem_total_val=$(echo "$mem_total" | sed 's/[A-Za-z]//g')
    mem_used_unit=$(echo "$mem_used" | sed 's/[0-9.]//g'); mem_total_unit=$(echo "$mem_total" | sed 's/[0-9.]//g')
    mem_used_mb=0; mem_total_mb=0
    if [[ "$mem_used_unit" == "Gi" || "$mem_used_unit" == "G" ]]; then mem_used_mb=$(awk -v val="$mem_used_val" 'BEGIN{print val * 1024}'); elif [[ "$mem_used_unit" == "Mi" || "$mem_used_unit" == "M" ]]; then mem_used_mb="$mem_used_val"; elif [[ "$mem_used_unit" == "Ki" || "$mem_used_unit" == "K" ]]; then mem_used_mb=$(awk -v val="$mem_used_val" 'BEGIN{print val / 1024}'); fi
    if [[ "$mem_total_unit" == "Gi" || "$mem_total_unit" == "G" ]]; then mem_total_mb=$(awk -v val="$mem_total_val" 'BEGIN{print val * 1024}'); elif [[ "$mem_total_unit" == "Mi" || "$mem_total_unit" == "M" ]]; then mem_total_mb="$mem_total_val"; elif [[ "$mem_total_unit" == "Ki" || "$mem_total_unit" == "K" ]]; then mem_total_mb=$(awk -v val="$mem_total_val" 'BEGIN{print val / 1024}'); fi
    mem_status_class="status-ok"
    if [[ "$mem_total_mb" =~ ^[0-9]+(\.[0-9]+)?$ && "$mem_used_mb" =~ ^[0-9]+(\.[0-9]+)?$ && $(echo "$mem_total_mb > 0" | bc -l 2>/dev/null) -eq 1 ]]; then
        mem_used_percent=$(awk -v used="$mem_used_mb" -v total="$mem_total_mb" 'BEGIN { printf "%.0f", (used/total)*100 }')
        if [ "$mem_used_percent" -gt 85 ] && [ "$mem_used_percent" -le 95 ]; then mem_status_class="status-warn"; page_issues+=("Memory usage at ${mem_used_percent}% (Warning)");
        elif [ "$mem_used_percent" -gt 95 ]; then mem_status_class="status-error"; page_issues+=("Memory usage at ${mem_used_percent}% (Critical)"); fi
        html_sys_health+="<tr><td>Memory Usage</td><td><span class='${mem_status_class}'>${mem_used_percent}%</span> (${mem_used} / ${mem_total}, Available: ${mem_available})</td></tr>"
    else
        log_message "ERROR" "Could not parse memory values. Used: $mem_used_mb MB, Total: $mem_total_mb MB. Original: $mem_used ($mem_used_unit) / $mem_total ($mem_total_unit)"; html_sys_health+="<tr><td>Memory Usage</td><td><span class='status-error'>Error parsing</span></td></tr>"; page_issues+=("Error parsing memory usage")
    fi
else
    log_message "WARNING" "Could not get Mem: line from free -h: $mem_info_full"; html_sys_health+="<tr><td>Memory Usage</td><td><span class='status-error'>Error fetching</span></td></tr>"; page_issues+=("Error fetching memory usage")
fi

cpu_temp_text="N/A"; temp_status_class="status-ok" # Default to N/A and OK
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    # File exists, now try to read it
    temp_raw=$(get_cmd_output "cat /sys/class/thermal/thermal_zone0/temp")
    if [[ "$temp_raw" =~ ^[0-9]+$ ]]; then
        cpu_temp=$(echo "scale=1; $temp_raw / 1000" | bc)
        cpu_temp_text_val="${cpu_temp}°C"
        if (( $(echo "$cpu_temp > 75" | bc -l 2>/dev/null) )); then # Critical threshold
            temp_status_class="status-error"
            page_issues+=("CPU Temp at ${cpu_temp_text_val} (High)")
            cpu_temp_text="<span class='${temp_status_class}'>${cpu_temp_text_val}</span>"
        elif (( $(echo "$cpu_temp > 65" | bc -l 2>/dev/null) )); then # Warning threshold
            temp_status_class="status-warn"
            page_issues+=("CPU Temp at ${cpu_temp_text_val} (Warning)")
            cpu_temp_text="<span class='${temp_status_class}'>${cpu_temp_text_val}</span>"
        else # Normal temp
            cpu_temp_text="<span class='${temp_status_class}'>${cpu_temp_text_val}</span>"
        fi
    elif [[ "$temp_raw" == "Error executing command" ]]; then
        cpu_temp_text="<span class='status-error'>Error reading temp</span>"
        page_issues+=("CPU Temp: Error reading /sys/class/thermal/thermal_zone0/temp")
        log_message "ERROR" "CPU Temp: Failed to read /sys/class/thermal/thermal_zone0/temp"
    else
        cpu_temp_text="<span class='status-warn'>Invalid data</span>"
        page_issues+=("CPU Temp: Invalid data from /sys/class/thermal/thermal_zone0/temp")
        log_message "WARNING" "Unexpected CPU temp value: $temp_raw"
    fi
else
    # File does not exist, this is normal for many VPS/VMs
    log_message "INFO" "/sys/class/thermal/thermal_zone0/temp not found. CPU Temp reported as N/A."
    cpu_temp_text="N/A" # Already set as default, but explicit here for clarity
fi
html_sys_health+="<tr><td>CPU Temperature</td><td>${cpu_temp_text}</td></tr>"
html_sys_health+="<tr><td>System Uptime</td><td>$(get_cmd_output "uptime -p" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</td></tr></table></div>"

# --- Section: Maintenance Status ---
html_maintenance="<div class='section'><h3>🔄 Maintenance Status</h3><table>"
backup_status_text="<span class='status-warn'>Log not found or no recent entry</span>"; add_backup_issue=true
last_backup_log=$(ls -t $BACKUP_LOG_FILE_PATTERN 2>/dev/null | head -n 1)
if [ -n "$last_backup_log" ] && [ -f "$last_backup_log" ]; then
    last_backup_line=$(grep -aiE "backup process finished|backup completed successfully|vps backup report|VPS Backup Process Completed Successfully|===== VPS Backup Process Completed Successfully =====" "$last_backup_log" | tail -1)
    if [ -n "$last_backup_line" ]; then
        backup_date=$(echo "$last_backup_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1); if [ -z "$backup_date" ]; then backup_date=$(echo "$last_backup_line" | grep -oE '[0-9]{2}/[0-9]{2}/[0-9]{4}' | head -1); fi
        backup_time=$(echo "$last_backup_line" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
        backup_status_text="<span class='status-ok'>✅ Last backup: ${backup_date} ${backup_time}</span>"; add_backup_issue=false
        if [[ -n "$backup_date" ]]; then
            backup_epoch=""
            if echo "$backup_date" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then backup_epoch=$(date -d "$backup_date $backup_time" +%s 2>/dev/null);
            elif echo "$backup_date" | grep -qE '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'; then backup_epoch=$(date -d "$(echo $backup_date | awk -F'/' '{print $3"-"$2"-"$1}') $backup_time" +%s 2>/dev/null); fi
            if [[ -n "$backup_epoch" ]] && [ $(( $(date +%s) - backup_epoch )) -gt $((8 * 24 * 60 * 60)) ]; then
                backup_status_text="<span class='status-warn'>⚠️ Last backup ${backup_date} ${backup_time} (Older than 7 days)</span>"; add_backup_issue=true; page_issues+=("System Backup: Last system backup is older than 7 days")
            fi; fi
    else backup_status_text="<span class='status-error'>❌ No success entry in backup log ($last_backup_log)</span>"; add_backup_issue=true; fi
else backup_status_text="<span class='status-error'>❌ Backup log not found (Pattern: ${BACKUP_LOG_FILE_PATTERN})</span>"; add_backup_issue=true; fi
if $add_backup_issue; then page_issues+=("System Backup: ${backup_status_text//<[^>]*/}"); fi
html_maintenance+="<tr><td>System Backup</td><td>${backup_status_text}</td></tr>"

update_status_text="<span class='status-warn'>Log not found or no recent entry</span>"; add_update_issue=true
last_update_log=$(ls -t $UPDATE_LOG_FILE_PATTERN 2>/dev/null | head -n 1)
if [ -n "$last_update_log" ] && [ -f "$last_update_log" ]; then
    last_update_line=$(grep -aiE "update process finished|update completed successfully|system update report|System Update: SUCCESS|Update process finished successfully" "$last_update_log" | tail -1)
     if [ -n "$last_update_line" ]; then
        update_date=$(echo "$last_update_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1); update_time=$(echo "$last_update_line" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
        update_status_text="<span class='status-ok'>✅ Last update: ${update_date} ${update_time}</span>"; add_update_issue=false
        if [[ -n "$update_date" ]]; then
            update_epoch=$(date -d "$update_date $update_time" +%s 2>/dev/null)
             if [[ -n "$update_epoch" ]] && [ $(( $(date +%s) - update_epoch )) -gt $((8 * 24 * 60 * 60)) ]; then
                update_status_text="<span class='status-warn'>⚠️ Last update ${update_date} ${update_time} (Older than 7 days)</span>"; add_update_issue=true; page_issues+=("System Updates: Last system update is older than 7 days")
            fi; fi
    else update_status_text="<span class='status-error'>❌ No success entry in update log ($last_update_log)</span>"; add_update_issue=true; fi
else update_status_text="<span class='status-error'>❌ Update log not found (Pattern: ${UPDATE_LOG_FILE_PATTERN})</span>"; add_update_issue=true; fi
if $add_update_issue; then page_issues+=("System Updates: ${update_status_text//<[^>]*/}"); fi
html_maintenance+="<tr><td>System Updates</td><td>${update_status_text}</td></tr></table></div>"

# --- Section: Top Processes ---
html_top_processes="<div class='section'><h3>📈 Top Processes</h3>"
# Top CPU
TOP_CPU_HEAD_RAW="PID   %CPU %MEM COMMAND"
TOP_CPU_PROCESSES_DATA_RAW=$(get_cmd_output "ps -eo pid,%cpu,%mem,comm --sort=-%cpu | head -n 6 | tail -n +2")
if [[ "$TOP_CPU_PROCESSES_DATA_RAW" == "Error executing command" ]]; then
    html_top_processes+="<p><strong>Top CPU:</strong> <span class='status-error'>Error fetching</span></p>"
    page_issues+=("Top Processes: Error fetching CPU stats")
else
    TOP_CPU_PROCESSES_DATA_ESCAPED=$(echo "$TOP_CPU_PROCESSES_DATA_RAW" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
    PRE_CONTENT_CPU="${TOP_CPU_HEAD_RAW}
${TOP_CPU_PROCESSES_DATA_ESCAPED}"
    html_top_processes+="<h4>Top 5 by CPU</h4><pre>${PRE_CONTENT_CPU}</pre>"
fi

# Top Memory
TOP_MEM_HEAD_RAW="PID   %MEM %CPU COMMAND"
TOP_MEM_PROCESSES_DATA_RAW=$(get_cmd_output "ps -eo pid,%mem,%cpu,comm --sort=-%mem | head -n 6 | tail -n +2")
if [[ "$TOP_MEM_PROCESSES_DATA_RAW" == "Error executing command" ]]; then
    html_top_processes+="<p><strong>Top Memory:</strong> <span class='status-error'>Error fetching</span></p>"
    page_issues+=("Top Processes: Error fetching Memory stats")
else
    TOP_MEM_PROCESSES_DATA_ESCAPED=$(echo "$TOP_MEM_PROCESSES_DATA_RAW" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
    PRE_CONTENT_MEM="${TOP_MEM_HEAD_RAW}
${TOP_MEM_PROCESSES_DATA_ESCAPED}"
    html_top_processes+="<h4>Top 5 by Memory</h4><pre>${PRE_CONTENT_MEM}</pre>"
fi
html_top_processes+="</div>"

# --- Section: Security Status ---
html_security="<div class='section'><h3>🛡️ Security Status</h3><table>"
failed_ssh_logins_text="<span class='status-warn'>N/A</span>"
auth_log_path="/var/log/auth.log"; journal_auth_log_path="/var/log/journal"
if [ -r "$auth_log_path" ]; then
    failed_ssh_logins_cmd_output=$(get_cmd_output "grep -ac \"Failed password\" $auth_log_path")
    if [[ "$failed_ssh_logins_cmd_output" == "Error executing command" ]]; then failed_ssh_logins_text="<span class='status-error'>Error reading $auth_log_path</span>"; page_issues+=("Error reading failed SSH logins from $auth_log_path (check permissions)");
    elif [[ "$failed_ssh_logins_cmd_output" =~ ^[0-9]+$ ]]; then failed_ssh_logins_text="$failed_ssh_logins_cmd_output";
    else log_message "WARNING" "Unexpected output for failed SSH: $failed_ssh_logins_cmd_output"; failed_ssh_logins_text="<span class='status-warn'>Parse Err</span>"; page_issues+=("Error parsing failed SSH login count from $auth_log_path"); fi
elif [ -d "$journal_auth_log_path" ] && command -v journalctl &>/dev/null; then
    journal_output=$(get_cmd_output "sudo journalctl _SYSTEMD_UNIT=sshd.service")
    if [[ "$journal_output" == "Error executing command" ]]; then failed_ssh_logins_text="<span class='status-error'>Error reading journal (sudo)</span>"; page_issues+=("Error reading SSH logs from journal via sudo");
    else failed_count=$(echo "$journal_output" | grep -ac 'Failed password'); if [[ "$failed_count" =~ ^[0-9]+$ ]]; then failed_ssh_logins_text="$failed_count"; else failed_ssh_logins_text="<span class='status-warn'>Parse Err (grep)</span>"; page_issues+=("Error parsing 'Failed password' count from journal"); fi; fi
else failed_ssh_logins_text="<span class='status-ok'>Log not found</span>"; log_message "INFO" "$auth_log_path or journal not found/readable, cannot check failed SSH logins."; fi
html_security+="<tr><td>Failed SSH Logins (today in auth.log or all in journal for sshd)</td><td>${failed_ssh_logins_text}</td></tr>"
banned_ips_text="N/A"
if command -v fail2ban-client &> /dev/null; then
    banned_ips_raw=$(get_cmd_output "sudo fail2ban-client status sshd" | grep "Total banned" | grep -oE "[0-9]+")
    if [[ "$banned_ips_raw" == "Error executing command" ]]; then banned_ips_text="<span class='status-error'>Error (sudo?)</span>"; page_issues+=("Fail2Ban: Error running command");
    elif [[ "$banned_ips_raw" =~ ^[0-9]+$ ]]; then banned_ips_text="$banned_ips_raw";
    else banned_ips_text="<span class='status-warn'>Error/None</span>"; log_message "WARNING" "Could not parse banned IPs from fail2ban: $banned_ips_raw"; fi
else banned_ips_text="<span class='status-ok'>Not installed</span>"; fi
html_security+="<tr><td>Currently Banned IPs (fail2ban sshd)</td><td>${banned_ips_text}</td></tr></table></div>"

# --- Section: SSH Authorized Keys ---
html_auth_keys="<div class='section'><h3>🔑 SSH Authorized Keys Files</h3>"
AUTH_KEYS_FILES_HEADER="User         File                                Last Modified         Size   Keys"
AUTH_KEYS_FILES_DETAILS_RAW=""

AUTH_KEYS_FILES_DETAILS_RAW=$( (
    getent passwd | awk -F: '$6 ~ /^\/home\// && $1 != "nobody" {print $1 ":" $6}' | while IFS=: read -r user dir; do
        key_file="$dir/.ssh/authorized_keys"
        if [ -f "$key_file" ] && [ -r "$key_file" ]; then
            mtime_raw=$(stat -c %y "$key_file" 2>/dev/null | cut -d'.' -f1)
            size_raw=$(stat -c %s "$key_file" 2>/dev/null)
            count_raw=$(grep -cvE '^(#|$)' "$key_file" 2>/dev/null)
            if [ -n "$mtime_raw" ] && [ -n "$size_raw" ] && [ -n "$count_raw" ]; then
                printf "%-12s %-35s %-20s %-6s %s\\n" "$user" "$key_file" "$mtime_raw" "$size_raw" "$count_raw"
            else
                log_message "WARNING" "AuthKeys: Partial/No info for $key_file (user $user). MTime: '$mtime_raw', Size: '$size_raw', Count: '$count_raw'"
                printf "%-12s %-35s %-20s %-6s %s\\n" "$user" "$key_file" "Error" "Error" "Error"
            fi
        fi
    done
    if [ -f "/root/.ssh/authorized_keys" ] && [ -r "/root/.ssh/authorized_keys" ]; then
        mtime_raw=$(stat -c %y "/root/.ssh/authorized_keys" 2>/dev/null | cut -d'.' -f1)
        size_raw=$(stat -c %s "/root/.ssh/authorized_keys" 2>/dev/null)
        count_raw=$(grep -cvE '^(#|$)' "/root/.ssh/authorized_keys" 2>/dev/null)
        if [ -n "$mtime_raw" ] && [ -n "$size_raw" ] && [ -n "$count_raw" ]; then
            printf "%-12s %-35s %-20s %-6s %s\\n" "root" "/root/.ssh/authorized_keys" "$mtime_raw" "$size_raw" "$count_raw"
        else
            log_message "WARNING" "AuthKeys: Partial/No info for /root/.ssh/authorized_keys. MTime: '$mtime_raw', Size: '$size_raw', Count: '$count_raw'"
            printf "%-12s %-35s %-20s %-6s %s\\n" "root" "/root/.ssh/authorized_keys" "Error" "Error" "Error"
        fi
    fi
) )

if [ -n "$AUTH_KEYS_FILES_DETAILS_RAW" ]; then
    AUTH_KEYS_FILES_DETAILS_ESCAPED=$(echo -e "$AUTH_KEYS_FILES_DETAILS_RAW" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
    html_auth_keys+="<pre>${AUTH_KEYS_FILES_HEADER}\n${AUTH_KEYS_FILES_DETAILS_ESCAPED}</pre>"
else
    html_auth_keys+="<p>No standard authorized_keys files found or accessible in /home/*/.ssh/ or /root/.ssh/.</p>"
    log_message "INFO" "AuthKeys: No standard authorized_keys files found or they were unreadable."
fi
html_auth_keys+="</div>"

# --- Section: Service Status ---
html_services="<div class='section'><h3>🚦 Service Status</h3><table>"
html_services+=$(check_service_html "ssh" "SSH Server (sshd)")
if systemctl list-unit-files --no-pager | grep -q -E 'nginx.service|apache2.service|httpd.service'; then
    if systemctl list-unit-files --no-pager | grep -q nginx.service; then html_services+=$(check_service_html "nginx" "Nginx Web Server"); fi
    if systemctl list-unit-files --no-pager | grep -q apache2.service; then html_services+=$(check_service_html "apache2" "Apache2 Web Server"); fi
    if systemctl list-unit-files --no-pager | grep -q httpd.service; then html_services+=$(check_service_html "httpd" "HTTPD (Apache) Web Server"); fi
else html_services+="<tr><td>Common Web Servers</td><td><span class='status-ok'>None detected</span></td></tr>"; fi
if systemctl list-unit-files --no-pager | grep -q cloudflared.service; then html_services+=$(check_service_html "cloudflared" "Cloudflared Tunnel"); else html_services+="<tr><td>Cloudflared Tunnel</td><td><span class='status-ok'>Not installed</span></td></tr>"; fi
if command -v docker &> /dev/null; then html_services+=$(check_service_html "docker" "Docker Service"); else html_services+="<tr><td>Docker Service</td><td><span class='status-ok'>Not installed</span></td></tr>"; fi
html_services+="</table></div>"

# --- Section: Docker Containers ---
html_docker=""
if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
    html_docker="<div class='section'><h3>🐳 Docker Containers</h3>"
    container_list_raw=$(get_cmd_output "docker ps --format '{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}'")
    if [[ "$container_list_raw" == "Error executing command" ]]; then html_docker+="<p>Error fetching Docker container list.</p>"; page_issues+=("Error fetching Docker container list");
    elif [ -z "$container_list_raw" ]; then html_docker+="<p>No containers running or list is empty.</p>";
    else
        html_docker+="<table><tr><th>Name</th><th>Image</th><th>State</th><th>Status</th></tr>"
        echo "$container_list_raw" | sed '/^\s*$/d' | while IFS=$'\t' read -r name image state status_text; do
            status_html=$(echo "$status_text" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
            state_html=$(echo "$state" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
            if [[ "$state" != "running" ]]; then
                status_html="<span class='status-error'>${status_html}</span>";
                page_issues+=("Docker container $name state: $state, status: $status_text");
            elif [[ "$status_text" == *"(unhealthy)"* ]]; then
                status_html="<span class='status-warn'>${status_html}</span>";
                page_issues+=("Docker container $name status: $status_text (Warning)");
            elif [[ "$status_text" == *"(health: starting)"* ]]; then
                status_html="<span class='status-ok'>${status_html}</span>";
            else
                status_html="<span class='status-ok'>${status_html}</span>";
            fi
            html_docker+="<tr><td>$name</td><td>$image</td><td>$state_html</td><td>$status_html</td></tr>"; done
        html_docker+="</table>"; fi; html_docker+="</div>"
fi

# --- Section: Network Services & Listening Ports ---
html_network_ports="<div class='section'><h3>🌐 Network Services & Listening Ports</h3>"
listening_ports_raw=$(get_cmd_output "sudo ss -tulnpH")
if [[ "$listening_ports_raw" == "Error executing command" ]]; then
    html_network_ports+="<p><span class='status-error'>Error fetching listening ports.</span></p>"
    page_issues+=("Error fetching listening ports via ss command.")
elif [ -z "$listening_ports_raw" ]; then
    html_network_ports+="<p>No listening TCP/UDP ports found (or ss command returned empty).</p>"
else
    html_network_ports+="<table><tr><th>Proto</th><th>State</th><th>Local Address:Port</th><th>Process</th></tr>"
    temp_ports_table=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        proto=$(echo "$line" | awk '{print $1}')
        state=$(echo "$line" | awk '{print $2}')
        local_addr_port=$(echo "$line" | awk '{print $5}')
        
        process_info_raw_field=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | xargs)
        process_info="N/A" 

        if [[ "$process_info_raw_field" == *"users:"* ]]; then
            extracted_name=$(echo "$process_info_raw_field" | sed -n -E 's/.*users:\(\("([^"]+)".*/\1/p')
            if [ -n "$extracted_name" ]; then
                process_info="$extracted_name"
                pid_part=$(echo "$process_info_raw_field" | sed -n -E 's/.*pid=([0-9]+).*/,pid=\1/p')
                process_info+="$pid_part"
            else
                process_info="$process_info_raw_field" 
                log_message "DEBUG" "Network Port Process: Complex users: format for '$local_addr_port': $process_info_raw_field"
            fi
        elif [ -n "$process_info_raw_field" ]; then
             process_info="$process_info_raw_field"
        fi
        
        process_info_escaped=$(echo "$process_info" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')
        temp_ports_table+="<tr><td>$proto</td><td>$state</td><td>$local_addr_port</td><td>${process_info_escaped}</td></tr>"
    done <<< "$(echo "$listening_ports_raw")"

    if [ -z "$temp_ports_table" ]; then
        html_network_ports+="<p>No active ports found from ss output processing (check log for raw output if needed).</p>"
        log_message "DEBUG" "Raw ss output for network ports was: $listening_ports_raw"
    else
        html_network_ports+="$temp_ports_table"
    fi
    html_network_ports+="</table>"
fi
html_network_ports+="</div>"

# --- Section: Firewall Status ---
html_firewall_status="<div class='section'><h3>🛡️ Firewall Status</h3>"
firewall_output=""
firewall_type="Unknown"
if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
    firewall_type="UFW (Active)"
    firewall_output=$(get_cmd_output "sudo ufw status verbose")
elif command -v iptables &>/dev/null; then
    iptables_rules_count=$(get_cmd_output "sudo iptables -S" | grep -cEv '^-P INPUT ACCEPT$|^-P FORWARD ACCEPT$|^-P OUTPUT ACCEPT$|^:INPUT ACCEPT \[[0-9]+:[0-9]+\]$|^:FORWARD ACCEPT \[[0-9]+:[0-9]+\]$|^:OUTPUT ACCEPT \[[0-9]+:[0-9]+\]$' || echo "0")
    if [[ "$iptables_rules_count" == "Error executing command" ]]; then
         firewall_type="IPTables (Error checking rules)"
         firewall_output="Error executing iptables -S to check rules."
         page_issues+=("Firewall: Error checking IPTables rules.")
    elif [[ "$iptables_rules_count" -gt 0 ]]; then
        firewall_type="IPTables (Custom Rules Present)"
        firewall_output=$(get_cmd_output "sudo iptables -S | head -n 20")
    else
        firewall_type="IPTables (Default Policies, No Custom Rules Detected)"
        firewall_output="IPTables is present but using default accept policies with no custom rules detected in the filter table."
    fi
else
    firewall_type="Not Detected"
    firewall_output="No common firewall tool (UFW/iptables) detected or UFW is inactive."
    page_issues+=("Firewall: No active firewall (UFW/iptables) detected or UFW inactive.")
fi
html_firewall_status+="<p><strong>Type:</strong> ${firewall_type}</p>"
if [[ "$firewall_output" == "Error executing command" && "$firewall_type" != "IPTables (Error checking rules)" ]]; then
    html_firewall_status+="<pre class='status-error'>Error fetching firewall status.</pre>"
    page_issues+=("Error fetching firewall status for ${firewall_type}.")
elif [ -n "$firewall_output" ]; then
    html_firewall_status+="<pre>$(echo "$firewall_output" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
fi
html_firewall_status+="</div>"

# --- Section: Recent User Activity ---
html_recent_logins="<div class='section'><h3>👤 Recent User Activity</h3>"
recent_logins_raw=$(get_cmd_output "last -n 7 -aFw")
if [[ "$recent_logins_raw" == "Error executing command" ]]; then
    html_recent_logins+="<p><span class='status-error'>Error fetching recent login data.</span></p>"
    page_issues+=("Error fetching recent login data.")
elif [ -z "$recent_logins_raw" ]; then
    html_recent_logins+="<p>No recent login data found (or 'last' command returned empty).</p>"
else
    html_recent_logins+="<pre>$(echo "$recent_logins_raw" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
fi
html_recent_logins+="</div>"

# --- Section: SSL Certificate Status (Certbot) ---
html_cert_status="<div class='section'><h3>🔒 SSL Certificate Status (Certbot)</h3>"
if command -v certbot &>/dev/null; then
    cert_output=$(get_cmd_output "sudo certbot certificates")
    if [[ "$cert_output" == "Error executing command" ]]; then
        html_cert_status+="<p><span class='status-error'>Error fetching Certbot certificate status.</span></p>"
        page_issues+=("Error fetching Certbot certificate status.")
    elif echo "$cert_output" | grep -q "No certificates found."; then
        html_cert_status+="<p>No certificates managed by Certbot found on this system.</p>"
    elif echo "$cert_output" | grep -q "Found the following certs:"; then
        html_cert_status+="<pre>$(echo "$cert_output" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
        if echo "$cert_output" | grep -qiE "invalid|error|problem|could not be renewed|failed|skipping"; then 
             page_issues+=("Certbot: Potential certificate issue detected (see details in Certbot section).")
             log_message "WARNING" "Potential Certbot issue detected in 'certbot certificates' output."
        fi
    elif [ -z "$cert_output" ]; then
        html_cert_status+="<p>Certbot command returned empty output (may indicate no certs or an issue).</p>"
        log_message "INFO" "Certbot certificates command returned empty."
    else
        html_cert_status+="<p>Certbot status:</p><pre>$(echo "$cert_output" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
    fi
else
    html_cert_status+="<p>Certbot command not found. SSL certificate status not checked.</p>"
fi
html_cert_status+="</div>"


# --- Section: Pi-hole Stats (Conditional) ---
html_pihole=""
if command -v pihole &> /dev/null && systemctl is-active --quiet pihole-FTL 2>/dev/null ; then
    html_pihole="<div class='section'><h3><img src='https://pi-hole.net/wp-content/uploads/2016/12/Vortex-R-WO-Words-NoBG-225x225.png' alt='Pi-hole' style='height:20px; vertical-align:middle;'> Pi-hole Stats (Today)</h3>"
    pihole_stats_json_raw=$(get_cmd_output "pihole -c -j")
    if [[ "$pihole_stats_json_raw" == "Error executing command" ]]; then html_pihole+="<p>Error fetching Pi-hole stats.</p>"; page_issues+=("Error fetching Pi-hole stats");
    else
        dns_queries="N/A"; ads_blocked="N/A"; percent_blocked="N/A"
        if command -v jq &> /dev/null; then
            dns_queries=$(echo "$pihole_stats_json_raw" | jq -r .dns_queries_today // "\"N/A\""); ads_blocked=$(echo "$pihole_stats_json_raw" | jq -r .ads_blocked_today // "\"N/A\""); percent_blocked=$(echo "$pihole_stats_json_raw" | jq -r .ads_percentage_today // "\"N/A\"")
        else
            dns_queries=$(echo "$pihole_stats_json_raw" | grep -oP '"dns_queries_today":\s*\K[0-9]+' || echo "N/A"); ads_blocked=$(echo "$pihole_stats_json_raw" | grep -oP '"ads_blocked_today":\s*\K[0-9]+' || echo "N/A"); percent_blocked=$(echo "$pihole_stats_json_raw" | grep -oP '"ads_percentage_today":\s*\K[0-9.]+' || echo "N/A"); fi
        html_pihole+="<table><tr><td>Total DNS Queries</td><td>${dns_queries}</td></tr><tr><td>Ads Blocked</td><td>${ads_blocked}</td></tr><tr><td>Percentage Blocked</td><td>${percent_blocked}%</td></tr></table>"; fi
    html_pihole+="</div>"
fi

# --- Assemble and Send Report ---
sections_array=()
sections_array+=("$html_sys_health")
sections_array+=("$html_maintenance")
sections_array+=("$html_top_processes")
sections_array+=("$html_security")
sections_array+=("$html_auth_keys")
sections_array+=("$html_services")
if [ -n "$html_docker" ]; then sections_array+=("$html_docker"); fi
if [ -n "$html_network_ports" ]; then sections_array+=("$html_network_ports"); fi
if [ -n "$html_firewall_status" ]; then sections_array+=("$html_firewall_status"); fi
if [ -n "$html_recent_logins" ]; then sections_array+=("$html_recent_logins"); fi
if [ -n "$html_cert_status" ]; then sections_array+=("$html_cert_status"); fi
if [ -n "$html_pihole" ]; then sections_array+=("$html_pihole"); fi

overall_status_class="status-ok-bg"; overall_status_message="✅ System Status: All Clear"; report_subject_suffix="SUCCESS"
if [ ${#page_issues[@]} -gt 0 ]; then
    issue_summary="<ul>"; for issue in "${page_issues[@]}"; do issue_summary+="<li>$(echo "$issue" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</li>"; done; issue_summary+="</ul>"
    critical_issue_found=false
    for issue in "${page_issues[@]}"; do
        if echo "$issue" | grep -qE "Critical|High|Failed|Error|Inactive|No success entry|Disk usage at [9-9][1-9]%"; then
            critical_issue_found=true; break
        fi
    done
    if $critical_issue_found; then
        overall_status_class="status-error-bg"; overall_status_message="❌ System Status: Issues Found!"; report_subject_suffix="ISSUES DETECTED"
    else
        overall_status_class="status-warn-bg"; overall_status_message="⚠️ System Status: Warnings"; report_subject_suffix="WARNINGS"
    fi
    sections_array+=("<div class='section'><h3>🚩 Detected Issues</h3>${issue_summary}</div>")
fi
overall_html="<div class='overall-status ${overall_status_class}'>${overall_status_message}</div>"
final_html_body=$(generate_report_html "$VPS_HOSTNAME Status Report" "$overall_html" "sections_array")
final_subject="${SUBJECT_PREFIX} - ${report_subject_suffix}"
send_report_email "$final_subject" "$final_html_body"
log_message "INFO" "System status report generation finished. Overall status: $report_subject_suffix"

exit 0
