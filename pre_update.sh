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

# Check which database is running and back it up
echo ""
echo "Detecting and backing up database..."

if service postgresql status >/dev/null 2>&1; then
    # PostgreSQL is running
    echo "PostgreSQL detected, creating backup..."
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
    echo "$DB_TYPE_POSTGRESQL" > "$BACKUP_DIR/database_type.txt"
    
elif service mysql-server status >/dev/null 2>&1; then
    # MySQL is running - use MYSQL_PWD environment variable for security
    echo "MySQL detected, creating backup..."
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
    echo "$DB_TYPE_MYSQL" > "$BACKUP_DIR/database_type.txt"
    
else
    echo "No database running (fresh install?)"
    echo "$DB_TYPE_NONE" > "$BACKUP_DIR/database_type.txt"
fi

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
