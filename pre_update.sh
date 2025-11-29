#!/bin/sh

set -eu

# Source logging helper if available
if [ -f /usr/local/bin/log_helper ]; then
    . /usr/local/bin/log_helper
    log_script_start "Pre-Update: Preparing for Nextcloud Update"
else
    # Fallback logging functions if log_helper not available
    log_info() { echo "[INFO] $*"; }
    log_step_start() { echo ">>> Starting: $*"; }
    log_step_end() { echo "<<< Finished: $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
    echo "========================================"
    echo "Pre-Update: Preparing for Nextcloud Update"
    echo "========================================"
fi

# Constants for database types
DB_TYPE_POSTGRESQL="postgresql"
DB_TYPE_MYSQL="mysql"
DB_TYPE_NONE="none"

# Load environment
log_step_start "Loading environment"
if [ -f /usr/local/bin/load_env ]; then
    . /usr/local/bin/load_env
    log_info "Environment loaded from /usr/local/bin/load_env"
else
    log_warn "load_env not found, skipping environment load"
fi
log_step_end "Loading environment"

# Create backup directory with timestamp
log_step_start "Creating backup directory"
BACKUP_DIR="/root/pre_update_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
log_info "Backup directory: $BACKUP_DIR"
log_step_end "Creating backup directory"

# Get database credentials
log_step_start "Reading database credentials"
DB_USER=$(cat /root/dbuser 2>/dev/null || echo "dbadmin")
DB_PASS=$(cat /root/dbpassword 2>/dev/null || echo "")
DB_NAME="nextcloud"
log_info "Database user: $DB_USER, Database name: $DB_NAME"
log_step_end "Reading database credentials"

# Put Nextcloud in maintenance mode
log_step_start "Enabling Nextcloud maintenance mode"
if su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --on" 2>/dev/null; then
    log_info "Maintenance mode enabled"
else
    log_warn "Could not enable maintenance mode (Nextcloud may not be installed yet)"
fi
log_step_end "Enabling Nextcloud maintenance mode"

# Backup Nextcloud configuration
log_step_start "Backing up Nextcloud configuration"
if [ -d /usr/local/www/nextcloud/config ]; then
    cp -r /usr/local/www/nextcloud/config "$BACKUP_DIR/nextcloud-config"
    log_info "Configuration backed up to: $BACKUP_DIR/nextcloud-config"
else
    log_warn "No Nextcloud config directory found (fresh install?)"
fi
log_step_end "Backing up Nextcloud configuration"

# Backup SSL certificates and detect SSL configuration state
log_step_start "Backing up SSL certificates and detecting SSL state"

CERT_PATH=/usr/local/etc/letsencrypt/live/truenas
SSL_STATE="none"

# Check if we have Let's Encrypt certificates by examining the certificate issuer
# Match various Let's Encrypt certificate authorities (R3, E1, etc.) and ISRG Root
has_letsencrypt_cert() {
    [ -f "${CERT_PATH}/fullchain.pem" ] && \
        openssl x509 -in "${CERT_PATH}/fullchain.pem" -issuer -noout 2>/dev/null | grep -qiE "Let's Encrypt|ISRG Root"
}

# Check if we have self-signed certificates (check for root.cer which is only created for self-signed)
has_self_signed_cert() {
    [ -f "${CERT_PATH}/root.cer" ] && [ -f "${CERT_PATH}/fullchain.pem" ]
}

# Check if nginx is configured for HTTPS by looking at the active configuration
nginx_has_ssl() {
    [ -f /usr/local/etc/nginx/conf.d/nextcloud.https.conf ]
}

# Determine the SSL state
if has_letsencrypt_cert; then
    SSL_STATE="letsencrypt"
    log_info "Detected Let's Encrypt certificates"
elif has_self_signed_cert; then
    SSL_STATE="self-signed"
    log_info "Detected self-signed certificates"
elif nginx_has_ssl; then
    SSL_STATE="custom-ssl"
    log_info "Detected custom SSL configuration"
else
    SSL_STATE="none"
    log_info "No SSL configuration detected (HTTP only)"
fi

# Check Nextcloud config for SSL requirement (overwrite.cli.url)
NC_URL_SCHEME="http"
if [ -f /usr/local/www/nextcloud/config/config.php ]; then
    if grep -q "'overwrite.cli.url' => 'https://" /usr/local/www/nextcloud/config/config.php 2>/dev/null; then
        NC_URL_SCHEME="https"
        log_info "Nextcloud is configured to use HTTPS (overwrite.cli.url)"
    elif grep -q "'overwrite.cli.url' => 'http://" /usr/local/www/nextcloud/config/config.php 2>/dev/null; then
        NC_URL_SCHEME="http"
        log_info "Nextcloud is configured to use HTTP (overwrite.cli.url)"
    fi
fi

# Save SSL state for post_update to use
echo "$SSL_STATE" > "$BACKUP_DIR/ssl_state.txt"
echo "$NC_URL_SCHEME" > "$BACKUP_DIR/nc_url_scheme.txt"
log_info "SSL state saved: $SSL_STATE, URL scheme: $NC_URL_SCHEME"

# Backup SSL certificates
log_step_start "Backing up SSL certificates"
if [ -d /usr/local/etc/letsencrypt ]; then
    cp -r /usr/local/etc/letsencrypt "$BACKUP_DIR/letsencrypt"
    log_info "SSL certificates backed up to: $BACKUP_DIR/letsencrypt"
else
    log_info "No SSL certificates found"
fi
log_step_end "Backing up SSL certificates"

# Save ALLOW_INSECURE_ACCESS state if it was explicitly set
log_step_start "Checking ALLOW_INSECURE_ACCESS state"
if [ -f /root/jail_options.env ] && grep -q "ALLOW_INSECURE_ACCESS" /root/jail_options.env; then
    cp /root/jail_options.env "$BACKUP_DIR/jail_options.env"
    log_info "jail_options.env backed up"
else
    log_info "No ALLOW_INSECURE_ACCESS setting found"
fi
log_step_end "Checking ALLOW_INSECURE_ACCESS state"
log_step_end "Backing up SSL certificates and detecting SSL state"

# Detect database type using multiple methods for reliability
log_step_start "Detecting and backing up database"

# Function to detect database type from Nextcloud config
detect_db_from_nextcloud_config() {
    if [ -f /usr/local/www/nextcloud/config/config.php ]; then
        # Extract dbtype from config.php (handle both single and double quotes)
        NC_DBTYPE=$(grep "dbtype" /usr/local/www/nextcloud/config/config.php 2>/dev/null | sed "s/.*=> *[\"']\([^\"']*\)[\"'].*/\1/" | head -1)
        case "$NC_DBTYPE" in
            pgsql)
                echo "$DB_TYPE_POSTGRESQL"
                return 0
                ;;
            mysql)
                echo "$DB_TYPE_MYSQL"
                return 0
                ;;
        esac
    fi
    return 1
}

# Function to detect database type from rc.conf (enabled services)
detect_db_from_rcconf() {
    if [ -f /etc/rc.conf ]; then
        if grep -q 'postgresql_enable="YES"' /etc/rc.conf 2>/dev/null; then
            echo "$DB_TYPE_POSTGRESQL"
            return 0
        elif grep -q 'mysql_enable="YES"' /etc/rc.conf 2>/dev/null; then
            echo "$DB_TYPE_MYSQL"
            return 0
        fi
    fi
    return 1
}

# Function to detect database type from running services
detect_db_from_running_services() {
    if service postgresql status >/dev/null 2>&1; then
        echo "$DB_TYPE_POSTGRESQL"
        return 0
    elif service mysql-server status >/dev/null 2>&1; then
        echo "$DB_TYPE_MYSQL"
        return 0
    fi
    return 1
}

# Try detection methods in order of reliability
DETECTED_DB_TYPE=""
# Track whether we started a DB service for the backup so we can stop it afterwards
POSTGRES_STARTED=0
MYSQL_STARTED=0

# Method 1: Check Nextcloud configuration (most reliable)
log_info "Checking Nextcloud config for database type..."
if DETECTED_DB_TYPE=$(detect_db_from_nextcloud_config); then
    log_info "Database type detected from Nextcloud config: $DETECTED_DB_TYPE"
fi

# Method 2: Check rc.conf for enabled services
if [ -z "$DETECTED_DB_TYPE" ]; then
    log_info "Checking rc.conf for database type..."
    if DETECTED_DB_TYPE=$(detect_db_from_rcconf); then
        log_info "Database type detected from rc.conf: $DETECTED_DB_TYPE"
    fi
fi

# Method 3: Check running services
if [ -z "$DETECTED_DB_TYPE" ]; then
    log_info "Checking running services for database type..."
    if DETECTED_DB_TYPE=$(detect_db_from_running_services); then
        log_info "Database type detected from running services: $DETECTED_DB_TYPE"
    fi
fi

# Default to none if no database detected
if [ -z "$DETECTED_DB_TYPE" ]; then
    DETECTED_DB_TYPE="$DB_TYPE_NONE"
    log_info "No database detected (fresh install?)"
fi

# Perform backup based on detected database type
log_step_start "Performing database backup"
case "$DETECTED_DB_TYPE" in
    "$DB_TYPE_POSTGRESQL")
        log_info "PostgreSQL detected, creating backup..."
        # Start PostgreSQL if not running (needed for backup)
        if ! service postgresql status >/dev/null 2>&1; then
            log_info "Starting PostgreSQL for backup..."
            service postgresql start 2>/dev/null || true
            POSTGRES_STARTED=1
            # Wait for PostgreSQL to be ready
            max_wait=30
            waited=0
            while ! service postgresql status >/dev/null 2>&1 && [ $waited -lt $max_wait ]; do
                sleep 1
                waited=$((waited + 1))
                # Log only every 5 seconds to reduce log noise
                if [ $((waited % 5)) -eq 0 ]; then
                    log_info "Waiting for PostgreSQL... ($waited/$max_wait)"
                fi
            done
        fi
        if [ -n "$DB_PASS" ]; then
            log_info "Running pg_dump..."
            PGPASSWORD="$DB_PASS" pg_dump -U "$DB_USER" -h localhost "$DB_NAME" > "$BACKUP_DIR/nextcloud_pg.sql" 2>/dev/null || true
            if [ -s "$BACKUP_DIR/nextcloud_pg.sql" ]; then
                BACKUP_SIZE=$(du -h "$BACKUP_DIR/nextcloud_pg.sql" | cut -f1)
                log_info "PostgreSQL backup completed: $BACKUP_DIR/nextcloud_pg.sql ($BACKUP_SIZE)"
            else
                log_warn "PostgreSQL backup may have failed or database is empty"
            fi
        else
            log_warn "No database password found, skipping database backup"
        fi
        ;;
    "$DB_TYPE_MYSQL")
        log_info "MySQL detected, creating backup..."
        # Start MySQL if not running (needed for backup)
        if ! service mysql-server status >/dev/null 2>&1; then
            log_info "Starting MySQL for backup..."
            service mysql-server start 2>/dev/null || true
            MYSQL_STARTED=1
            # Wait for MySQL to be ready
            max_wait=30
            waited=0
            while ! service mysql-server status >/dev/null 2>&1 && [ $waited -lt $max_wait ]; do
                sleep 1
                waited=$((waited + 1))
                # Log only every 5 seconds to reduce log noise
                if [ $((waited % 5)) -eq 0 ]; then
                    log_info "Waiting for MySQL... ($waited/$max_wait)"
                fi
            done
        fi
        if [ -n "$DB_PASS" ]; then
            log_info "Running mysqldump..."
            MYSQL_PWD="$DB_PASS" mysqldump -u "$DB_USER" \
                --single-transaction \
                --routines \
                --triggers \
                --hex-blob \
                "$DB_NAME" > "$BACKUP_DIR/nextcloud_mysql.sql" 2>/dev/null || true
            if [ -s "$BACKUP_DIR/nextcloud_mysql.sql" ]; then
                BACKUP_SIZE=$(du -h "$BACKUP_DIR/nextcloud_mysql.sql" | cut -f1)
                log_info "MySQL backup completed: $BACKUP_DIR/nextcloud_mysql.sql ($BACKUP_SIZE)"
            else
                log_warn "MySQL backup may have failed or database is empty"
            fi
        else
            log_warn "No database password found, skipping database backup"
        fi
        ;;
    *)
        log_info "No database to backup"
        ;;
esac
log_step_end "Performing database backup"

# After a successful backup, stop the database server(s) we started for the backup.
# We only stop the service if:
#  - we started it in this script (POSTGRES_STARTED or MYSQL_STARTED is set), and
#  - the backup file exists and is non-empty (indicating a successful backup).
log_step_start "Stopping database services started for backup"
if [ "$POSTGRES_STARTED" = "1" ]; then
    if [ -s "$BACKUP_DIR/nextcloud_pg.sql" ]; then
        log_info "Stopping PostgreSQL (was started for backup)..."
        if service postgresql stop >/dev/null 2>&1; then
            log_info "PostgreSQL stopped"
        else
            log_warn "Failed to stop PostgreSQL"
        fi
    else
        log_warn "PostgreSQL was started for backup but backup file not found or empty; not stopping PostgreSQL"
    fi
fi

if [ "$MYSQL_STARTED" = "1" ]; then
    if [ -s "$BACKUP_DIR/nextcloud_mysql.sql" ]; then
        log_info "Stopping MySQL (was started for backup)..."
        if service mysql-server stop >/dev/null 2>&1; then
            log_info "MySQL stopped"
        else
            log_warn "Failed to stop MySQL"
        fi
    else
        log_warn "MySQL was started for backup but backup file not found or empty; not stopping MySQL"
    fi
fi
log_step_end "Stopping database services started for backup"

echo "$DETECTED_DB_TYPE" > "$BACKUP_DIR/database_type.txt"
log_info "Database type saved: $DETECTED_DB_TYPE"
log_step_end "Detecting and backing up database"

# Save current migration state
log_step_start "Saving migration state"
if [ -f /root/migrations/current_migration.txt ]; then
    cp /root/migrations/current_migration.txt "$BACKUP_DIR/migration_state.txt"
    log_info "Migration state backed up"
else
    echo "0" > "$BACKUP_DIR/migration_state.txt"
    log_info "No previous migration state (fresh install)"
fi
log_step_end "Saving migration state"

# Store backup location for post_update reference
echo "$BACKUP_DIR" > /root/last_pre_update_backup
log_info "Backup location saved to /root/last_pre_update_backup"

# Log completion
if [ -f /usr/local/bin/log_helper ]; then
    log_script_end "Pre-update backup" "completed successfully"
else
    echo ""
    echo "========================================"
    echo "Pre-update backup completed successfully"
    echo "========================================"
fi
log_info "Backup location: $BACKUP_DIR"
log_info "Contents:"
ls -la "$BACKUP_DIR"
log_info "The update will now proceed..."
