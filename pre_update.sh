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

# Backup SSL certificates
echo ""
echo "Backing up SSL certificates..."
if [ -d /usr/local/etc/letsencrypt ]; then
    cp -r /usr/local/etc/letsencrypt "$BACKUP_DIR/letsencrypt"
    echo "SSL certificates backed up to: $BACKUP_DIR/letsencrypt"
else
    echo "No SSL certificates found"
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
