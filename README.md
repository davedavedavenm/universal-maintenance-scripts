
# Universal Maintenance Scripts

This repository contains a collection of scripts designed to automate essential maintenance, diagnostic, and backup tasks for Linux servers, including Debian/Ubuntu-based VPS instances and Raspberry Pi devices.

## Overview

The primary goal of these scripts is to provide a reliable and configurable way to manage server health, security, and data integrity through automated (cron-driven) and manual utilities.

## Scripts Included

### Core Automated Maintenance Scripts
These scripts are typically run via cron jobs.

*   **`backup_system_tarball.sh`**:
    *   Performs a full system backup by creating a compressed tarball of the root filesystem (excluding specified paths).
    *   Manages Docker containers (stopping/starting specific services) during the backup process if configured.
    *   Uploads the backup to a cloud storage remote using `rclone`.
    *   Sends an HTML email notification with the backup status and log snippet.
*   **`system_update.sh`**:
    *   Updates system packages (e.g., using `apt`).
    *   Handles unattended upgrades and can perform a reboot if required by updates.
    *   Sends an HTML email notification with the update status and log snippet.
*   **`system_status.sh`**:
    *   Generates a comprehensive system status report in HTML format, sent via email (typically weekly).
    *   Includes: System Health (Disk, Memory, CPU Temp, Uptime), Maintenance Status (Backup/Update Logs), Security Status (SSH, Fail2ban), Service Status, Docker Container List, Network Ports, Firewall Status, Recent User Activity, and Certbot SSL Certificate Status.
*   **`find_certbot_domains_status.sh`**:
    *   Checks all SSL certificates managed by the host's Certbot.
    *   Sends an HTML email notification *only if* issues are found (e.g., certificates expiring soon, renewal errors).
    *   Intended for daily cron execution to provide timely alerts.

### Manual Utility & Diagnostic Scripts

*   **`cleanup.sh`**:
    *   An interactive script to help clean system resources.
    *   Offers options to clean Docker resources (unused containers, images, volumes, networks, build cache), temporary files, and the `apt` cache.
*   **`update_cloudflared.sh`**:
    *   Updates a Cloudflared tunnel instance running via a specific Docker Compose file.
    *   Pulls the latest image and restarts the container. Sends an HTML email notification.
*   **`find_certbot_domains_status.sh`** (Manual Use):
    *   Can also be run manually to quickly check the status of all Certbot certificates (outputs to console if no issues).

### Pi-Specific Scripts (Located in `pi-specific/` subfolder)

*   **`pi-specific/sd_backup.sh`**:
    *   Designed specifically for Raspberry Pi devices to back up the entire SD card content.
    *   Uses `rsync` to copy the filesystem, creates a tarball, and uploads it via `rclone`.
    *   Configured via `pi-specific/pi_config.sh`.
*   **`pi-specific/pi_config.sh`**:
    *   Configuration file for `sd_backup.sh` and other Pi-specific scripts. Contains Pi-specific paths, rclone settings, etc.
*   **`pi-specific/sd_backup_excludes.txt`**:
    *   Exclude list for the `sd_backup.sh` script.

### Configuration & Core Utilities

*   **`config.sh`**:
    *   **Central configuration file for all universal scripts.**
    *   **Must be edited** to set user-specific details: `PI_EMAIL` (recipient for notifications), `PI_LOGS_DIR` (log storage), `PI_HOSTNAME` (or `HOSTNAME_LABEL`), `PI_MSMTP_CONFIG` (path to root msmtp config), `PI_MSMTP_LOG` (path for root msmtp log), rclone remote names, etc.
*   **`email_utils.sh`**:
    *   Provides common functions (`generate_email_html`, `send_html_notification`) for creating and sending HTML email notifications. Sourced by `config.sh`.

## Setup and Configuration

1.  **Clone the Repository:**
    ```bash
    git clone https://github.com/davedavedavenm/universal-maintenance-scripts.git
    cd universal-maintenance-scripts
    ```

2.  **Review and Edit `config.sh`:**
    This is the most crucial step. Open `config.sh` and customize the variables for your environment:
    ```bash
    nano config.sh
    ```
    Pay close attention to `PI_EMAIL`, `PI_LOGS_DIR`, `PI_MSMTP_CONFIG`, `PI_MSMTP_LOG`, and any rclone related variables if used directly by scripts (though `backup_system_tarball.sh` has its own internal rclone logic that might also need checking/configuration).

3.  **For Pi Usage - Review and Edit `pi-specific/pi_config.sh`:**
    If you intend to use the Pi-specific scripts on a Raspberry Pi:
    ```bash
    nano pi-specific/pi_config.sh
    ```
    Customize it for each Pi's specific setup (hostname, backup remotes, user, paths). Also ensure `pi-specific/sd_backup_excludes.txt` meets your needs.

4.  **Install Dependencies:**
    Ensure the following command-line tools are installed. On Debian/Ubuntu:
    ```bash
    sudo apt update
    sudo apt install -y msmtp msmtp-mta rclone tar gzip bc coreutils util-linux procps bsd-mailx fail2ban ufw docker.io docker-compose certbot python3-certbot-dns-cloudflare # Adjust as needed
    ```
    *   `msmtp`, `msmtp-mta`: For sending emails.
    *   `rclone`: For cloud backups.
    *   `bc`: For calculations (e.g., CPU temperature).
    *   `docker.io`, `docker-compose`: If using Docker-related scripts.
    *   `certbot`, `python3-certbot-dns-cloudflare`: If using Certbot scripts with Cloudflare DNS.
    *   Others are generally standard.

5.  **Configure MSMTP:**
    For email notifications to work, `msmtp` must be configured. Create/edit the system-wide configuration file specified in `config.sh` (e.g., `/etc/msmtprc`). This file will contain your SMTP server details and credentials.
    Example for `/etc/msmtprc` (permissions `600`, owned by `root`):
    ```
    defaults
    auth           on
    tls            on
    tls_trust_file /etc/ssl/certs/ca-certificates.crt
    logfile        [Path_From_PI_MSMTP_LOG_in_config.sh] # e.g., /home/dave/vps_maintenance_logs/msmtp_root.log

    account        default
    host           smtp.yourprovider.com
    port           587
    from           your_sending_email@example.com
    user           your_smtp_username
    password       your_smtp_password_or_app_password

    # Fallback account (optional)
    # account default : default
    ```
    **Secure this file properly as it contains credentials.**

6.  **Make Scripts Executable:**
    ```bash
    chmod +x *.sh
    chmod +x pi-specific/*.sh
    ```

## Usage

### Automated Scripts (Cron Jobs)
Edit root's crontab: `sudo crontab -e`
Add entries similar to the following, adjusting paths and schedules as needed:

```cron
# Example Cron Entries (run as root)

# Daily: Check Certbot certificates and alert on issues
0 5 * * * /home/dave/universal-maintenance-scripts/find_certbot_domains_status.sh

# Weekly: Full System Status Report (e.g., Sunday at 7 AM)
0 7 * * 0 /home/dave/universal-maintenance-scripts/system_status.sh

# Weekly: System Package Updates (e.g., Sunday at 4 AM)
0 4 * * 0 /home/dave/universal-maintenance-scripts/system_update.sh

# Daily: System Tarball Backup (e.g., at 3 AM)
0 3 * * * /home/dave/universal-maintenance-scripts/backup_system_tarball.sh

# Daily/Weekly: Update Cloudflared (if used and managed by this script)
# 0 2 * * 1 /home/dave/universal-maintenance-scripts/update_cloudflared.sh # Example for weekly
Use code with caution.
Markdown
Manual Scripts
Navigate to ~/universal-maintenance-scripts/ and run as needed. Some scripts require sudo.
sudo ./cleanup.sh (Interactive)
sudo ./update_cloudflared.sh
For Pi scripts, navigate to pi-specific/ on the Pi.
Logging
Most scripts log their activities to the directory specified by PI_LOGS_DIR in config.sh (e.g., /home/dave/vps_maintenance_logs/). Each script typically creates its own log file (e.g., system_update.log, backup_system_tarball.log).
This README provides a general guide. Please adapt configurations and scripts to your specific server environments and requirements.
