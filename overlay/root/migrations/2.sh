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

# Check if we're already on PostgreSQL
log_info "Checking if PostgreSQL is already running..."
if service postgresql status >/dev/null 2>&1; then
    log_info "PostgreSQL already running, skipping migration"
    log_step_end "Migration 2: MySQL to PostgreSQL 18" "skipped - already on PostgreSQL"
    exit 0
fi

# Check if PostgreSQL data directory exists (already initialized)
log_info "Checking if PostgreSQL is already initialized..."
if [ -d /var/db/postgres/data18 ]; then
    log_info "PostgreSQL already initialized, skipping migration"
    sysrc -f /etc/rc.conf postgresql_enable="YES"
    log_info "Starting PostgreSQL service..."
    service postgresql start 2>/dev/null || true
    log_step_end "Migration 2: MySQL to PostgreSQL 18" "skipped - already initialized"
    exit 0
fi

# Check if MySQL is running and has data
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

log_info "MySQL is running with existing data"
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

# Don't fail the migration, just inform the user
log_step_end "Migration 2: MySQL to PostgreSQL 18" "manual migration required"
exit 0
