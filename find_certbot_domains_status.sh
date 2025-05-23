#!/bin/bash

# find_certbot_domains_status.sh
# Checks Certbot certificate statuses and emails if issues (e.g., expiring soon) are found.

# --- Configuration ---
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file $CONFIG_FILE not found!" >&2
    # Attempt to log this critical failure if possible
    # As config is not found, PI_LOGS_DIR might not be available. Log to /tmp as a fallback.
    echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL: Configuration file $CONFIG_FILE not found." >> "/tmp/find_certbot_status_critical_error.log"
    exit 1
fi
source "$CONFIG_FILE" # This should bring in functions from email_utils.sh via config.sh

# Now check if the crucial email function is actually available after sourcing config
if ! command -v generate_email_html &> /dev/null; then
    echo "ERROR: Email utility function 'generate_email_html' not found after sourcing $CONFIG_FILE." >&2
    echo "Ensure $CONFIG_FILE correctly sources your email utility script (e.g., email_utils.sh)." >&2
    echo "And ensure that email_utils.sh defines 'generate_email_html' and is in the same directory as $CONFIG_FILE." >&2
    # Log this critical failure. PI_LOGS_DIR should be available now if config.sh was sourced but utils were not.
    # If PI_LOGS_DIR is still not set (e.g. error in config.sh itself), it will go to /tmp.
    error_log_dir=${PI_LOGS_DIR:-/tmp}
    mkdir -p "$error_log_dir" # Ensure log directory exists
    echo "$(date '+%Y-%m-%d %H:%M:%S') - CRITICAL: Email utility 'generate_email_html' not loaded. Check config.sh sourcing of email_utils.sh." >> "$error_log_dir/find_certbot_status_critical_error.log"
    exit 1
fi

# --- Script Settings ---
# CERT_EXPIRY_WARN_DAYS is expected to be set in config.sh, with a default here if not.
EXPIRY_WARN_DAYS=${CERT_EXPIRY_WARN_DAYS:-14} 
LOG_FILE_THIS_SCRIPT="${PI_LOGS_DIR}/find_certbot_status.log" # Renamed to avoid conflict with other LOG_FILE vars
MAX_LOG_SIZE_KB=1024 

# --- Helper Functions for this script ---
log_this_script() {
    # Ensures PI_LOGS_DIR is usable or defaults
    local current_log_dir=${PI_LOGS_DIR:-/tmp}
    mkdir -p "$current_log_dir" # Ensure log directory exists before trying to write
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${current_log_dir}/find_certbot_status.log" # Use specific log file name
}

rotate_this_script_log() {
    local current_log_dir=${PI_LOGS_DIR:-/tmp}
    local current_log_file="${current_log_dir}/find_certbot_status.log"
    if [ -f "$current_log_file" ] && [[ $(du -k "$current_log_file" | cut -f1) -gt $MAX_LOG_SIZE_KB ]]; then
        mv "$current_log_file" "${current_log_file}.1" 2>/dev/null && gzip -f "${current_log_file}.1" 2>/dev/null &
        # Start new log with rotation message, using log_this_script to ensure directory exists
        log_this_script "Log rotated." 
    fi
}

# --- Sanity Checks ---
if [ "$EUID" -ne 0 ]; then
    log_this_script "[ERROR] Script requires root privileges to run 'certbot certificates'."
    echo "[ERROR] Script requires root privileges. Please execute using sudo or as root."
    exit 1
fi

if ! command -v certbot &> /dev/null; then
    log_this_script "[ERROR] certbot command not found."
    echo "[ERROR] certbot command not found. Please install Certbot."
    exit 1
fi

if [ -z "$PI_EMAIL" ]; then
    log_this_script "[ERROR] PI_EMAIL is not set in config.sh. Cannot send notifications."
    echo "[ERROR] PI_EMAIL is not set in config.sh. Exiting."
    exit 1
fi

# Ensure PI_LOGS_DIR exists before first use by logging/rotation
if [ -n "$PI_LOGS_DIR" ]; then
    mkdir -p "$PI_LOGS_DIR"
else
    log_this_script "[WARNING] PI_LOGS_DIR not set, logging to /tmp for this script."
fi

rotate_this_script_log
log_this_script "[INFO] Starting Certbot status check."

# --- Main Logic ---
cert_output_raw=$(sudo certbot certificates 2>&1)
cert_output_exit_code=$?

if [ $cert_output_exit_code -ne 0 ]; then
    log_this_script "[ERROR] 'sudo certbot certificates' command failed. Exit code: $cert_output_exit_code"
    log_this_script "[ERROR] Raw output: $cert_output_raw"
    
    subject_label=${HOSTNAME_LABEL:-$(hostname)}
    subject="[CRITICAL] ${subject_label} - Certbot Command Failure"
    body_content="The 'sudo certbot certificates' command failed on ${subject_label}.
    Please check the system and the script log: ${LOG_FILE_THIS_SCRIPT}

    Exit Code: ${cert_output_exit_code}
    Output:
    <pre>$(echo "$cert_output_raw" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>" # HTML escape output
    
    html_body=$(generate_email_html "Certbot Command Failure" "$body_content")
    # Use PI_MSMTP_CONFIG for root and PI_MSMTP_LOG from config.sh
    send_html_notification "$PI_EMAIL" "$subject" "$html_body" \
        "$(cat "$PI_MSMTP_CONFIG" 2>/dev/null)" \
        "$(cat "${PI_LOGS_DIR}/msmtp_root.log" 2>/dev/null)" # Assuming a PI_MSMTP_LOG for root is defined or a default path
    echo "[ERROR] 'sudo certbot certificates' failed. Notification sent."
    exit 1
fi

problem_certs_details=""
found_issue=false

if echo "$cert_output_raw" | grep -qiE "invalid|error|problem|could not be renewed|failed|skipping"; then
    found_issue=true
    problem_certs_details+="<p><strong>General Certbot Issue Detected in 'certbot certificates' output (lines containing keywords):</strong></p>"
    problem_certs_details+="<pre>$(echo "$cert_output_raw" | grep -iE --color=never 'WARNING:|ERROR:|invalid|problem|fail|skip' | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre><hr>"
    log_this_script "[WARNING] General Certbot issue detected in 'certbot certificates' output."
fi

parsed_certs_info=$(echo "$cert_output_raw" | awk -v warn_days="$EXPIRY_WARN_DAYS" '
    BEGIN { 
        cert_block=""; name=""; domains=""; expiry_date_line=""; status_line=""; 
        days_remaining="N/A"; problem_flag=0; 
        OFS="\n"; # Output field separator for print
    }
    function reset_vars() {
        cert_block=""; name=""; domains=""; expiry_date_line=""; status_line=""; 
        days_remaining="N/A"; problem_flag=0; 
    }
    /^Certificate Name:/ {
        if (name != "") process_block(); # Process previous block
        reset_vars();
        name = $0; 
        cert_block = name;
    }
    /Domains:/ && name {
        domains = $0; cert_block = cert_block OFS "  " domains;
    }
    /Expiry Date:/ && name {
        expiry_date_line = $0; cert_block = cert_block OFS "  " expiry_date_line;
    }
    # Regex for VALID: XX days
    /VALID:[[:space:]]+[0-9]+[[:space:]]+days/ && name { 
        status_line = $0; cert_block = cert_block OFS "  " status_line;
        current_days = $2; # $2 should be the number of days
        gsub(/[^0-9]/, "", current_days); # Clean it to be sure it is just a number
        days_remaining = current_days + 0; # Force numeric context
        if (days_remaining <= warn_days) {
            problem_flag=1;
            cert_block = cert_block OFS "    WARNING: Certificate expiring in " days_remaining " days (threshold: " warn_days " days)";
        }
    }
    # Catch other non-VALID statuses (like INVALID, EXPIRED, REVOKED) that appear on a line by themselves
    ( /INVALID/ || /REVOKED/ || /EXPIRED/ || /UNKNOWN STATUS/ || /ERROR IN CERTIFICATE/) && name && !/VALID:/ {
        if (status_line == "") { # Only if we haven_t already captured a VALID status line
            status_line = $0; # Capture the whole line
            cert_block = cert_block OFS "  " status_line;
            problem_flag=1; 
        }
    }
    END { if (name != "") process_block(); } # Process the last block

    function process_block() {
        if (problem_flag) {
            print "--- CERTIFICATE REQUIRES ATTENTION ---";
            print cert_block; # This already includes name, domains, expiry, status, and warning
            print "--------------------------------------\n";
        }
    }
')


if [ -n "$parsed_certs_info" ]; then
    if ! $found_issue; then # If general issues didn't already set this
      problem_certs_details+="<p><strong>Certificates requiring attention (expiring soon or other issues):</strong></p>"
    fi
    found_issue=true # Ensure it's true if parsed_certs_info has content
    problem_certs_details+="<pre>$(echo "$parsed_certs_info" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>"
    log_this_script "[WARNING] Found certificates requiring attention:\n$parsed_certs_info"
fi


if [ "$found_issue" = true ]; then
    log_this_script "[ACTION] Sending notification email for Certbot issues."
    subject_label=${HOSTNAME_LABEL:-$(hostname)}
    subject="[WARNING] ${subject_label} - Certbot Certificate Issues Detected"
    
    email_body_content="<p>The following Certbot certificate issues were detected on ${subject_label}:</p>"
    email_body_content+="${problem_certs_details}" # This contains pre-formatted HTML details
    email_body_content+="<hr><p>Full 'certbot certificates' output for context:</p><pre>$(echo "$cert_output_raw" | sed 's/&/\&/g; s/</\</g; s/>/\>/g')</pre>" # HTML escape
    
    html_body=$(generate_email_html "Certbot Certificate Issues" "$email_body_content")
    send_html_notification "$PI_EMAIL" "$subject" "$html_body" \
        "$(cat "$PI_MSMTP_CONFIG" 2>/dev/null)" \
        "$(cat "${PI_LOGS_DIR}/msmtp_root.log" 2>/dev/null)"
    echo "[WARNING] Certbot issues found. Notification sent."
else
    log_this_script "[INFO] No Certbot certificate issues found requiring notification."
    echo "[INFO] All Certbot certificates are okay (not expiring within $EXPIRY_WARN_DAYS days and no general errors detected)."
fi

log_this_script "[INFO] Certbot status check finished."
exit 0
