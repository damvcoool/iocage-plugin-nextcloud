#!/bin/sh

set -eu

echo "========================================"
echo "Migration 2: MySQL to PostgreSQL 18"
echo "========================================"

# Load environment
. /usr/local/bin/load_env

# Check if we're already on PostgreSQL
if service postgresql status >/dev/null 2>&1; then
    echo "PostgreSQL already running, skipping migration"
    exit 0
fi

# Check if PostgreSQL data directory exists (already initialized)
if [ -d /var/db/postgres/data18 ]; then
    echo "PostgreSQL already initialized, skipping migration"
    sysrc -f /etc/rc.conf postgresql_enable="YES"
    service postgresql start 2>/dev/null || true
    exit 0
fi

# Check if MySQL is running and has data
if ! service mysql-server status >/dev/null 2>&1; then
    echo "MySQL not running - this appears to be a fresh install"
    echo "Initializing PostgreSQL for new installation..."
    
    # Initialize and start PostgreSQL for fresh installs
    # Set authentication options to suppress initdb warning about "trust" authentication
    sysrc -f /etc/rc.conf postgresql_initdb_flags="--auth-local=trust --auth-host=trust"
    /usr/local/etc/rc.d/postgresql oneinitdb
    sysrc -f /etc/rc.conf postgresql_enable="YES"
    service postgresql start
    
    echo "PostgreSQL initialized successfully"
    exit 0
fi

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
exit 0

