#!/bin/sh

set -eu

echo "========================================"
echo "Pre-Update: Preparing for Nextcloud Update"
echo "========================================"

# Constants for database types
DB_TYPE_POSTGRESQL="postgresql"
DB_TYPE_MYSQL="mysql"
DB_TYPE_NONE="none"

# Load environment
if [ -f /usr/local/bin/load_env ]; then
    . /usr/local/bin/load_env
fi

# Create backup directory with timestamp
BACKUP_DIR="/root/pre_update_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "Backup directory: $BACKUP_DIR"

# Get database credentials
DB_USER=$(cat /root/dbuser 2>/dev/null || echo "dbadmin")
DB_PASS=$(cat /root/dbpassword 2>/dev/null || echo "")
DB_NAME="nextcloud"

# Put Nextcloud in maintenance mode
echo ""
echo "Enabling Nextcloud maintenance mode..."
if su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --on" 2>/dev/null; then
    echo "Maintenance mode enabled"
else
    echo "Warning: Could not enable maintenance mode (Nextcloud may not be installed yet)"
fi

# Backup Nextcloud configuration
echo ""
echo "Backing up Nextcloud configuration..."
if [ -d /usr/local/www/nextcloud/config ]; then
    cp -r /usr/local/www/nextcloud/config "$BACKUP_DIR/nextcloud-config"
    echo "Configuration backed up to: $BACKUP_DIR/nextcloud-config"
else
    echo "Warning: No Nextcloud config directory found (fresh install?)"
fi

# Backup SSL certificates and detect SSL configuration state
echo ""
echo "Backing up SSL certificates and detecting SSL state..."

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
    echo "Detected Let's Encrypt certificates"
elif has_self_signed_cert; then
    SSL_STATE="self-signed"
    echo "Detected self-signed certificates"
elif nginx_has_ssl; then
    SSL_STATE="custom-ssl"
    echo "Detected custom SSL configuration"
else
    SSL_STATE="none"
    echo "No SSL configuration detected (HTTP only)"
fi

# Check Nextcloud config for SSL requirement (overwrite.cli.url)
NC_URL_SCHEME="http"
if [ -f /usr/local/www/nextcloud/config/config.php ]; then
    if grep -q "'overwrite.cli.url' => 'https://" /usr/local/www/nextcloud/config/config.php 2>/dev/null; then
        NC_URL_SCHEME="https"
        echo "Nextcloud is configured to use HTTPS (overwrite.cli.url)"
    elif grep -q "'overwrite.cli.url' => 'http://" /usr/local/www/nextcloud/config/config.php 2>/dev/null; then
        NC_URL_SCHEME="http"
        echo "Nextcloud is configured to use HTTP (overwrite.cli.url)"
    fi
fi

# Save SSL state for post_update to use
echo "$SSL_STATE" > "$BACKUP_DIR/ssl_state.txt"
echo "$NC_URL_SCHEME" > "$BACKUP_DIR/nc_url_scheme.txt"

# Backup SSL certificates
if [ -d /usr/local/etc/letsencrypt ]; then
    cp -r /usr/local/etc/letsencrypt "$BACKUP_DIR/letsencrypt"
    echo "SSL certificates backed up to: $BACKUP_DIR/letsencrypt"
else
    echo "No SSL certificates found"
fi

# Save ALLOW_INSECURE_ACCESS state if it was explicitly set
if [ -f /root/jail_options.env ] && grep -q "ALLOW_INSECURE_ACCESS" /root/jail_options.env; then
    cp /root/jail_options.env "$BACKUP_DIR/jail_options.env"
    echo "jail_options.env backed up"
fi

# Detect database type using multiple methods for reliability
echo ""
echo "Detecting and backing up database..."

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

# Method 1: Check Nextcloud configuration (most reliable)
if DETECTED_DB_TYPE=$(detect_db_from_nextcloud_config); then
    echo "Database type detected from Nextcloud config: $DETECTED_DB_TYPE"
fi

# Method 2: Check rc.conf for enabled services
if [ -z "$DETECTED_DB_TYPE" ]; then
    if DETECTED_DB_TYPE=$(detect_db_from_rcconf); then
        echo "Database type detected from rc.conf: $DETECTED_DB_TYPE"
    fi
fi

# Method 3: Check running services
if [ -z "$DETECTED_DB_TYPE" ]; then
    if DETECTED_DB_TYPE=$(detect_db_from_running_services); then
        echo "Database type detected from running services: $DETECTED_DB_TYPE"
    fi
fi

# Default to none if no database detected
if [ -z "$DETECTED_DB_TYPE" ]; then
    DETECTED_DB_TYPE="$DB_TYPE_NONE"
    echo "No database detected (fresh install?)"
fi

# Perform backup based on detected database type
case "$DETECTED_DB_TYPE" in
    "$DB_TYPE_POSTGRESQL")
        echo "PostgreSQL detected, creating backup..."
        # Start PostgreSQL if not running (needed for backup)
        if ! service postgresql status >/dev/null 2>&1; then
            echo "Starting PostgreSQL for backup..."
            service postgresql start 2>/dev/null || true
            # Wait for PostgreSQL to be ready
            max_wait=30
            waited=0
            while ! service postgresql status >/dev/null 2>&1 && [ $waited -lt $max_wait ]; do
                sleep 1
                waited=$((waited + 1))
            done
        fi
        if [ -n "$DB_PASS" ]; then
            PGPASSWORD="$DB_PASS" pg_dump -U "$DB_USER" -h localhost "$DB_NAME" > "$BACKUP_DIR/nextcloud_pg.sql" 2>/dev/null || true
            if [ -s "$BACKUP_DIR/nextcloud_pg.sql" ]; then
                BACKUP_SIZE=$(du -h "$BACKUP_DIR/nextcloud_pg.sql" | cut -f1)
                echo "PostgreSQL backup completed: $BACKUP_DIR/nextcloud_pg.sql ($BACKUP_SIZE)"
            else
                echo "Warning: PostgreSQL backup may have failed or database is empty"
            fi
        else
            echo "Warning: No database password found, skipping database backup"
        fi
        ;;
    "$DB_TYPE_MYSQL")
        echo "MySQL detected, creating backup..."
        # Start MySQL if not running (needed for backup)
        if ! service mysql-server status >/dev/null 2>&1; then
            echo "Starting MySQL for backup..."
            service mysql-server start 2>/dev/null || true
            # Wait for MySQL to be ready
            max_wait=30
            waited=0
            while ! service mysql-server status >/dev/null 2>&1 && [ $waited -lt $max_wait ]; do
                sleep 1
                waited=$((waited + 1))
            done
        fi
        if [ -n "$DB_PASS" ]; then
            MYSQL_PWD="$DB_PASS" mysqldump -u "$DB_USER" \
                --single-transaction \
                --routines \
                --triggers \
                --hex-blob \
                "$DB_NAME" > "$BACKUP_DIR/nextcloud_mysql.sql" 2>/dev/null || true
            if [ -s "$BACKUP_DIR/nextcloud_mysql.sql" ]; then
                BACKUP_SIZE=$(du -h "$BACKUP_DIR/nextcloud_mysql.sql" | cut -f1)
                echo "MySQL backup completed: $BACKUP_DIR/nextcloud_mysql.sql ($BACKUP_SIZE)"
            else
                echo "Warning: MySQL backup may have failed or database is empty"
            fi
        else
            echo "Warning: No database password found, skipping database backup"
        fi
        ;;
    *)
        echo "No database to backup"
        ;;
esac

echo "$DETECTED_DB_TYPE" > "$BACKUP_DIR/database_type.txt"
echo "Database type saved: $DETECTED_DB_TYPE"

# Save current migration state
echo ""
echo "Saving migration state..."
if [ -f /root/migrations/current_migration.txt ]; then
    cp /root/migrations/current_migration.txt "$BACKUP_DIR/migration_state.txt"
    echo "Migration state backed up"
else
    echo "0" > "$BACKUP_DIR/migration_state.txt"
    echo "No previous migration state (fresh install)"
fi

# Store backup location for post_update reference
echo "$BACKUP_DIR" > /root/last_pre_update_backup

echo ""
echo "========================================"
echo "Pre-update backup completed successfully"
echo "========================================"
echo "Backup location: $BACKUP_DIR"
echo ""
echo "Contents:"
ls -la "$BACKUP_DIR"
echo ""
echo "The update will now proceed..."
echo "========================================"
