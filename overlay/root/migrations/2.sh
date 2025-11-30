#!/bin/sh

set -eu

# Source logging helper if available
if [ -f /usr/local/bin/log_helper ]; then
    . /usr/local/bin/log_helper
else
    # Fallback logging functions if log_helper not available
    log_info() { echo "[INFO] $*"; }
    log_step_start() { echo ">>> Starting: $*"; }
    log_step_end() { echo "<<< Finished: $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

log_step_start "Migration 2: MySQL to PostgreSQL 18"

echo "========================================"
echo "Migration 2: MySQL to PostgreSQL 18"
echo "========================================"

# Load environment
. /usr/local/bin/load_env

# Check if this was a MySQL to PostgreSQL migration by checking the pre_update backup
# This is important because Migration 1 may have already started PostgreSQL
PRE_UPDATE_BACKUP=""
if [ -f /root/last_pre_update_backup ]; then
    PRE_UPDATE_BACKUP=$(cat /root/last_pre_update_backup)
fi

PREVIOUS_DB_TYPE=""
if [ -n "$PRE_UPDATE_BACKUP" ] && [ -f "$PRE_UPDATE_BACKUP/database_type.txt" ]; then
    PREVIOUS_DB_TYPE=$(cat "$PRE_UPDATE_BACKUP/database_type.txt")
    log_info "Previous database type from backup: $PREVIOUS_DB_TYPE"
fi

# Function to check if PostgreSQL has Nextcloud data by checking multiple core tables
# This is more robust than checking a single table in case of partial migrations
pg_has_nextcloud_data() {
    # Check for oc_users table as it's a core Nextcloud table that must exist
    # Also check for oc_appconfig which stores app configuration
    if su -m postgres -c "psql -d nextcloud -c \"SELECT 1 FROM oc_users LIMIT 1\"" >/dev/null 2>&1; then
        return 0
    fi
    if su -m postgres -c "psql -d nextcloud -c \"SELECT 1 FROM oc_appconfig LIMIT 1\"" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Function to display MySQL to PostgreSQL migration instructions
show_mysql_migration_instructions() {
    echo ""
    echo "========================================"
    echo "IMPORTANT: MySQL to PostgreSQL Migration"
    echo "========================================"
    echo ""
    echo "This plugin has been upgraded from MySQL to PostgreSQL 18."
    echo "Your MySQL database backup was created during the pre-update process."
    echo ""
    echo "Backup location: $PRE_UPDATE_BACKUP"
    echo "MySQL dump file: $PRE_UPDATE_BACKUP/nextcloud_mysql.sql"
    echo ""
    echo "PostgreSQL is now running but your data has NOT been migrated."
    echo "Nextcloud will need to be re-initialized or data restored."
    echo ""
    echo "Options:"
    echo "  1. Fresh start: Complete Nextcloud setup wizard (users/files/settings lost)"
    echo "  2. Manual migration: Use pgloader or another tool to migrate the MySQL dump"
    echo ""
    echo "For manual migration with pgloader:"
    echo "  pkg install pgloader"
    echo "  pgloader mysql://dbadmin:PASSWORD@localhost/nextcloud \\"
    echo "           pgsql://dbadmin:PASSWORD@localhost/nextcloud"
    echo ""
    echo "See /root/migrate_mysql_to_postgresql.sh for more details."
    echo "========================================"
    echo ""
}

# Function to display live MySQL migration prompt
show_live_mysql_migration_prompt() {
    echo ""
    echo "========================================"
    echo "IMPORTANT: MySQL to PostgreSQL Migration Required"
    echo "========================================"
    echo ""
    echo "This plugin now uses PostgreSQL 18 instead of MySQL."
    echo "Your existing MySQL database has been detected."
    echo ""
    echo "To migrate your data, please run the migration script:"
    echo "  /root/migrate_mysql_to_postgresql.sh"
    echo ""
    echo "The migration will:"
    echo "  1. Backup your MySQL database"
    echo "  2. Export data using Nextcloud's maintenance mode"
    echo "  3. Initialize PostgreSQL"
    echo "  4. Import data into PostgreSQL"
    echo "  5. Update Nextcloud configuration"
    echo ""
    echo "Manual migration required to ensure data integrity."
    echo "========================================"
    echo ""
}

# Handle MySQL to PostgreSQL migration scenarios
if [ "$PREVIOUS_DB_TYPE" = "mysql" ]; then
    log_info "Detected upgrade from MySQL installation"
    
    # Check if PostgreSQL already has data (migration was already done manually)
    if service postgresql status >/dev/null 2>&1; then
        if pg_has_nextcloud_data; then
            log_info "PostgreSQL already has Nextcloud data, migration appears complete"
            log_step_end "Migration 2: MySQL to PostgreSQL 18" "skipped - data already migrated"
            exit 0
        fi
        # PostgreSQL is running but has no data - need to inform user about data migration
        log_info "PostgreSQL is running but database is empty - data migration required"
    else
        # PostgreSQL not running, but previous DB was MySQL - initialize PostgreSQL
        log_info "PostgreSQL not running, initializing for MySQL migration..."
        
        # Check if PostgreSQL is already initialized
        if [ ! -d /var/db/postgres/data18 ]; then
            log_info "Setting PostgreSQL init flags..."
            sysrc -f /etc/rc.conf postgresql_initdb_flags="--auth-local=trust --auth-host=trust"
            log_info "Running PostgreSQL initdb..."
            /usr/local/etc/rc.d/postgresql oneinitdb
        fi
        
        sysrc -f /etc/rc.conf postgresql_enable="YES"
        log_info "Starting PostgreSQL service..."
        service postgresql start 2>/dev/null || true
    fi
    
    # Show migration instructions for MySQL users and exit
    log_info "MySQL backup should be available in the pre_update backup"
    show_mysql_migration_instructions
    log_step_end "Migration 2: MySQL to PostgreSQL 18" "data migration required"
    exit 0
fi

# Not a MySQL migration from pre_update - check other conditions

# Check if we're already on PostgreSQL with data
log_info "Checking if PostgreSQL is already running..."
if service postgresql status >/dev/null 2>&1; then
    if pg_has_nextcloud_data; then
        log_info "PostgreSQL already running with data, skipping migration"
        log_step_end "Migration 2: MySQL to PostgreSQL 18" "skipped - already on PostgreSQL"
        exit 0
    fi
    # PostgreSQL running but empty - this is a fresh install, nothing to migrate
    log_info "PostgreSQL running (fresh install), no migration needed"
    log_step_end "Migration 2: MySQL to PostgreSQL 18" "skipped - fresh PostgreSQL install"
    exit 0
fi

# Check if PostgreSQL data directory exists (already initialized)
log_info "Checking if PostgreSQL is already initialized..."
if [ -d /var/db/postgres/data18 ]; then
    log_info "PostgreSQL already initialized, starting service"
    sysrc -f /etc/rc.conf postgresql_enable="YES"
    log_info "Starting PostgreSQL service..."
    service postgresql start 2>/dev/null || true
    log_step_end "Migration 2: MySQL to PostgreSQL 18" "skipped - already initialized"
    exit 0
fi

# Check if MySQL is running and has data (live MySQL scenario without pre_update)
log_info "Checking if MySQL is running..."
if ! service mysql-server status >/dev/null 2>&1; then
    log_info "MySQL not running - this appears to be a fresh install"
    log_info "Initializing PostgreSQL for new installation..."
    
    # Initialize and start PostgreSQL for fresh installs
    # Set authentication options to suppress initdb warning about "trust" authentication
    log_info "Setting PostgreSQL init flags..."
    sysrc -f /etc/rc.conf postgresql_initdb_flags="--auth-local=trust --auth-host=trust"
    log_info "Running PostgreSQL initdb..."
    /usr/local/etc/rc.d/postgresql oneinitdb
    sysrc -f /etc/rc.conf postgresql_enable="YES"
    log_info "Starting PostgreSQL service..."
    service postgresql start
    
    log_info "PostgreSQL initialized successfully"
    log_step_end "Migration 2: MySQL to PostgreSQL 18" "completed - fresh install"
    exit 0
fi

# MySQL is running with existing data (live MySQL scenario)
log_info "MySQL is running with existing data"
show_live_mysql_migration_prompt
log_step_end "Migration 2: MySQL to PostgreSQL 18" "manual migration required"
exit 0
