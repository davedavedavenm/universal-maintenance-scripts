#!/bin/bash
# Email Utility Functions

# Ensure this script is not run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script is meant to be sourced, not executed directly."
    exit 1
fi

# Function to generate a basic HTML email body structure
# Takes a title (string) and content (string, can be multi-line, can contain HTML)
# Outputs the full HTML structure for the email body.
generate_email_html() {
    local title="$1"
    local content="$2"
    local current_timestamp
    current_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # HOSTNAME_LABEL should be available from config.sh if sourced prior to calling this
    local effective_hostname=${HOSTNAME_LABEL:-$(hostname)}

    # Basic CSS - can be expanded if needed
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${title}</title>
    <style>
        body { font-family: Verdana, Geneva, sans-serif; margin: 0; padding: 10px; background-color: #f8f9fa; color: #333; font-size: 14px; }
        .container { max-width: 900px; margin: 20px auto; background-color: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 0 15px rgba(0,0,0,.1); }
        h1, h2, h3 { color: #004085; margin-top: 0; }
        h3 { margin-bottom: 5px; border-bottom: 1px solid #ccc; padding-bottom: 3px; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { border: 1px solid #dee2e6; padding: 8px; text-align: left; vertical-align: top; }
        th { background-color: #e9ecef; font-weight: 700; }
        pre { white-space: pre-wrap; word-wrap: break-word; background-color: #f1f1f1; border: 1px solid #ddd; padding: 10px; border-radius: 4px; font-family: monospace; font-size: 0.9em; max-height: 400px; overflow-y: auto; }
        .footer { font-size: .85em; text-align: center; color: #6c757d; margin-top: 20px; padding-top: 10px; border-top: 1px solid #ccc; }
        .status-ok { color: green; font-weight: 700; }
        .status-warn { color: orange; font-weight: 700; }
        .status-error { color: red; font-weight: 700; }
        .overall-status{padding:15px;margin-bottom:20px;border-radius:4px;font-weight:700;font-size:1.2em;text-align:center}
        .status-ok-bg{background-color:#d4edda;color:#155724;border:1px solid #c3e6cb}
        .status-warn-bg{background-color:#fff3cd;color:#856404;border:1px solid #ffeeba}
        .status-error-bg{background-color:#f8d7da;color:#721c24;border:1px solid #f5c6cb}
    </style>
</head>
<body>
    <div class="container">
        <h1>${title}</h1>
        ${content}
        <div class="footer">
            <p>Report generated at ${current_timestamp} by ${effective_hostname}</p>
        </div>
    </div>
</body>
</html>
EOF
}

# Function to send an HTML email notification
# Arguments:
# 1. recipient_email
# 2. email_subject
# 3. html_body_content (full HTML document as a string)
# 4. msmtp_config_path (optional, from config.sh, e.g. $PI_MSMTP_CONFIG or $PI_MSMTP_CONFIG_USER)
# 5. msmtp_log_path (optional, from config.sh, e.g. $PI_MSMTP_LOG or $PI_MSMTP_LOG_USER)
# 6. from_address (optional, e.g. $PI_EMAIL_FROM from config.sh)
send_html_notification() {
    local recipient_email="$1"
    local email_subject="$2"
    local html_body_content="$3"
    local msmtp_config_path="$4"
    local msmtp_log_path="$5"
    local from_address="$6" # Optional From: header value

    local from_header_line=""
    if [ -n "$from_address" ]; then
        from_header_line="From: ${from_address}\n"
    fi

    local mail_command_args=()
    if [ -n "$msmtp_config_path" ] && [ -f "$msmtp_config_path" ]; then
        mail_command_args+=("--file=${msmtp_config_path}")
    else
        # Log a warning if a specific config was expected but not found
        if [ -n "$msmtp_config_path" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [EMAIL_UTILS_WARN] - msmtp config '$msmtp_config_path' not found. Using system default." >> "${PI_LOGS_DIR:-/tmp}/email_utils.log"
        fi
    fi

    if [ -n "$msmtp_log_path" ]; then
        mail_command_args+=("--logfile=${msmtp_log_path}")
        # Ensure log directory for msmtp exists if path is provided
        mkdir -p "$(dirname "$msmtp_log_path")"
    fi
    
    # Add recipient to msmtp command arguments
    mail_command_args+=("-a default" "$recipient_email")

    if command -v msmtp &>/dev/null; then
        printf "${from_header_line}To:%s\nSubject:%s\nContent-Type:text/html;charset=utf-8\nMIME-Version:1.0\n\n%s" \
            "$recipient_email" "$email_subject" "$html_body_content" | msmtp "${mail_command_args[@]}"
        
        if [ $? -ne 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [EMAIL_UTILS_ERROR] - msmtp send failed for subject: $email_subject" >> "${PI_LOGS_DIR:-/tmp}/email_utils.log"
            return 1
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') [EMAIL_UTILS_INFO] - Email sent via msmtp for subject: $email_subject" >> "${PI_LOGS_DIR:-/tmp}/email_utils.log"
            return 0
        fi
    elif command -v mail &>/dev/null; then
        # 'mail' command has limited support for complex headers and HTML, but try anyway
        # Note: 'mail' command arguments for From: are not standard. msmtp is preferred.
        local mail_subject_escaped=$(echo "$email_subject" | sed 's/"/\\"/g') # Basic escaping for subject
        printf "Content-Type:text/html;charset=utf-8\nMIME-Version:1.0\n${from_header_line}\n%s" "$html_body_content" | \
            mail -s "$mail_subject_escaped" "$recipient_email"

        if [ $? -ne 0 ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [EMAIL_UTILS_ERROR] - 'mail' send failed for subject: $email_subject" >> "${PI_LOGS_DIR:-/tmp}/email_utils.log"
            return 1
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') [EMAIL_UTILS_INFO] - Email sent via 'mail' for subject: $email_subject" >> "${PI_LOGS_DIR:-/tmp}/email_utils.log"
            return 0
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [EMAIL_UTILS_ERROR] - No suitable mail client (msmtp or mail) found." >> "${PI_LOGS_DIR:-/tmp}/email_utils.log"
        return 1
    fi
}
