# Universal Maintenance Scripts

This repository contains a collection of scripts designed to automate essential maintenance, diagnostic, and backup tasks for Linux servers. It is primarily managed on a Hetzner VPS (`dave-vps-arm`) but includes components adaptable for other Debian/Ubuntu-based systems and Raspberry Pi devices.

## Overview

The goal is to provide a reliable and configurable way to manage server health, security, data integrity, and certificate monitoring through automated (cron-driven) and manual utilities, with clear distinctions for different host environments.

## Repository Structure

-   **`/` (Root Directory):** Contains universal scripts, main configuration (`config.sh`), and core utilities (`email_utils.sh`) primarily used by the Hetzner VPS. Some scripts here can be adapted for other systems.
-   **`/pi-specific/`:** Contains scripts and configurations (`pi_config.sh`, `sd_backup_excludes.txt`) tailored for Raspberry Pi devices.

## I. Hetzner VPS (`dave-vps-arm`) Specific Setup

This section details scripts and configurations as they are set up and run on the primary Hetzner VPS.

### A. Core Automated Scripts (Run via root's cron on Hetzner VPS)
These utilize `config.sh` and `email_utils.sh` from this repository.

*   **`backup_system_tarball.sh`**:
    *   Performs system backup to a tarball, manages Docker services, uploads via `rclone`.
    *   Sends HTML email notification.
    *   Cron: Weekly (e.g., Sunday 3 AM).
*   **`system_update.sh`**:
    *   Updates system packages using `apt`), handles reboots.
    *   Sends HTML email notification.
    *   Cron: Weekly (e.g., Sunday 4 AM).
*   **`system_status.sh`**:
    *   Generates a comprehensive HTML system status email.
    *   Includes: System Health, Maintenance Status, Security, Services, Docker, Network, Firewall, User Activity, Host Certbot Status.
    *   Cron: Weekly (e.g., Sunday 7 AM).
*   **`find_certbot_domains_status.sh`**:
    *   Monitors SSL certificates managed by the **host's Certbot instance on this Hetzner VPS**.
    *   Sends an HTML email notification *only if* issues are found (expiry, errors).
    *   Cron: Daily (e.g., 5 AM).

### B. System-Level Certbot Renewal & Hetzner Traefik Monitoring (Hetzner VPS)
This script is **part of the Hetzner VPS system configuration, not directly in this Git repository's versioned files.**
*   **Location:** `/usr/local/sbin/certbot_check_renew.sh`
*   **Triggered by:** Systemd `certbot.timer` (via `certbot.service` override) approximately twice daily.
*   **Purpose on Hetzner VPS:**
    1.  Runs `/usr/bin/certbot renew --non-interactive` for actual host Certbot renewals.
    2.  Checks Traefik `acme.json` on the Hetzner VPS (path: `/home/dave/docker_apps/pangolin_stack/config/letsencrypt/acme.json`).
    3.  Sends plain text email alerts ONLY for critical `certbot renew` command failures or Traefik certificates (on Hetzner) expiring soon.

### C. Manual Utility Scripts (in `~/universal-maintenance-scripts/` on Hetzner VPS)
*   **`cleanup.sh`**: Interactive system cleanup (Docker, temp files, apt). Run with `sudo`.
*   **`update_cloudflared.sh`**: Updates Cloudflared Docker instance (path `/home/dave/cloudflared/docker-compose.yml`). Uses `config.sh` for notifications. Run with `sudo`. (Can be cronned if desired).

## II. Scripts for Other Systems (e.g., Oracle VPS, Other Traefik Instances)

*   **`check_traefik_certs.sh` (Template/Example):**
    *   A version of this script (template provided separately during setup discussions) is intended for deployment on any server running Traefik where its `acme.json` needs monitoring (e.g., your Oracle VPS).
    *   This script is **not automatically deployed** from this repository. It should be copied to the target server and customized.
    *   Requires its own on-server configuration (variables at the top of that script), `msmtp`/`mail` setup, and cron job *on that target server*.
    *   (Example on Oracle VPS: `/home/opc/scripts/check_traefik_certs.sh`, monitoring `/home/opc/migration/config/letsencrypt/acme.json`, run by `opc` user's cron).

## III. For Raspberry Pi Devices (in `pi-specific/` of this repository)

These scripts are versioned here and intended for deployment to Raspberry Pi devices.

*   **`pi-specific/sd_backup.sh`**: Backs up Raspberry Pi SD card contents using `rsync` and `rclone`.
*   **`pi-specific/pi_config.sh`**: **Crucial configuration file for `sd_backup.sh`**. Must be customized on each Pi with Pi-specific user, paths, rclone settings, etc.
*   **`pi-specific/sd_backup_excludes.txt`**: Exclude list for `sd_backup.sh`.

## IV. Configuration & Core Utilities (in `~/universal-maintenance-scripts/`)

These are primarily used by the scripts running on the Hetzner VPS.

*   **`config.sh`**:
    *   **Central configuration file.** MUST BE EDITED with details for the system it's on (primarily for Hetzner VPS: `PI_EMAIL`, `PI_LOGS_DIR`, `HOSTNAME_LABEL`, `PI_MSMTP_CONFIG`, `PI_MSMTP_LOG`).
    *   Sources `email_utils.sh`.
*   **`email_utils.sh`**:
    *   Provides common functions (`generate_email_html`, `send_html_notification`) for HTML email notifications.

## General Setup Instructions

1.  **Clone Repository (on each target machine where scripts will be run):**
    ```bash
    git clone https://github.com/davedavedavenm/universal-maintenance-scripts.git
    cd universal-maintenance-scripts
    ```

2.  **Configure `config.sh` (on Hetzner VPS / Primary Machine):**
    ```bash
    nano config.sh 
    ```
    Set `PI_EMAIL`, `PI_LOGS_DIR`, etc.

3.  **Configure `pi-specific/pi_config.sh` (on each Pi):**
    ```bash
    nano pi-specific/pi_config.sh
    ```
    Set Pi-specific details.

4.  **Configure `check_traefik_certs.sh` (on Oracle VPS / Other Traefik Hosts):**
    Copy a template of `check_traefik_certs.sh` (similar to the one developed for Oracle VPS) to the target machine, place it (e.g., in `~/scripts`), and edit its internal configuration block.

5.  **Install Dependencies (on each relevant machine):**
    ```bash
    # Example for Debian/Ubuntu (adjust for Oracle Linux using dnf)
    sudo apt update
    sudo apt install -y msmtp msmtp-mta rclone tar gzip bc coreutils util-linux procps bsd-mailx fail2ban ufw docker.io docker-compose certbot python3-certbot-dns-cloudflare jq openssl
    ```
    *   **Oracle/RHEL-based:** Use `sudo dnf install -y ...` for these packages.

6.  **Configure MSMTP/Mail Sending (on each machine that needs to send email):**
    *   For root-run scripts on Hetzner: Configure `/etc/msmtprc` (see `PI_MSMTP_CONFIG` and `PI_MSMTP_LOG` in `config.sh`).
    *   For `opc`-run script on Oracle: Configure `/home/opc/.msmtprc` (or as defined in `check_traefik_certs.sh`).
    *   Ensure `msmtprc` files have `chmod 600` permissions.

7.  **Make Scripts Executable (on each machine):**
    ```bash
    chmod +x *.sh
    chmod +x pi-specific/*.sh 
    # And chmod +x /path/to/check_traefik_certs.sh on Oracle, etc.
    ```

## Cron Job Setup Examples

### Hetzner VPS (root's crontab - `sudo crontab -e`)
```cron
# Daily: Host Certbot Problem Alerter (HTML email ONLY on issues)
0 5 * * * /home/dave/universal-maintenance-scripts/find_certbot_domains_status.sh

# Weekly: Full System Status Report (Sunday 7 AM)
0 7 * * 0 /home/dave/universal-maintenance-scripts/system_status.sh

# Weekly: System Package Updates (Sunday 4 AM)
0 4 * * 0 /home/dave/universal-maintenance-scripts/system_update.sh

# Weekly: System Tarball Backup (Sunday 3 AM)
0 3 * * 0 /home/dave/universal-maintenance-scripts/backup_system_tarball.sh

# Note: The system's certbot.timer runs /usr/local/sbin/certbot_check_renew.sh for actual renewals and Hetzner Traefik checks.
Use code with caution.
Markdown
Oracle VPS (opc user's crontab - crontab -e)
# Daily: Traefik Certificate Expiry Check (emails ONLY on issues)
30 5 * * * /home/opc/scripts/check_traefik_certs.sh > /dev/null 2>&1
Use code with caution.
Cron
Raspberry Pi (e.g., pi user's crontab)
# Daily: SD Card Backup (adjust path to where you cloned the scripts on the Pi)
# 0 2 * * * /home/pi/universal-maintenance-scripts/pi-specific/sd_backup.sh
Use code with caution.
Cron
Overall Certificate Monitoring Strategy
Hetzner VPS (Host Certbot): find_certbot_domains_status.sh (daily cron) for expiry/error alerts. Actual renewals by system certbot.timer (via modified /usr/local/sbin/certbot_check_renew.sh).
Hetzner VPS (Traefik): /usr/local/sbin/certbot_check_renew.sh (twice-daily systemd timer) for expiry/error alerts.
Oracle VPS (Traefik): check_traefik_certs.sh (daily cron by opc user) for expiry/error alerts.
Pi Devices (Host Certbot, if used): Deploy find_certbot_domains_status.sh, config.sh, email_utils.sh to Pi, customize config.sh for Pi, and set up cron.
(Recommended Future Addition) External Monitoring: Consider setting up Uptime Kuma (self-hosted Docker app) or a similar service to monitor all public-facing HTTPS endpoints from an external perspective for an additional layer of certificate expiry and uptime monitoring.
Logging
Logs are generally stored in the directory specified by PI_LOGS_DIR (in config.sh on Hetzner) or as defined in individual scripts on other systems (e.g., /home/opc/logs on Oracle).
This repository is the central place for managing these scripts. Adapt and deploy components as needed for each target system.
