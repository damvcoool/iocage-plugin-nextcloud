#!/bin/sh

set -eu

echo "========================================"
echo "MySQL to PostgreSQL 18 Migration Tool"
echo "========================================"
echo ""
echo "This script migrates your Nextcloud data from a MySQL backup to PostgreSQL."
echo ""
echo "This tool is designed to run AFTER the plugin upgrade when:"
echo "  - MySQL is no longer installed"
echo "  - PostgreSQL is already initialized and running"
echo "  - A MySQL backup exists from the pre-update process"
echo ""

# Load environment
if [ -f /usr/local/bin/load_env ]; then
    . /usr/local/bin/load_env
fi

# Helper function to manage PHP-FPM service (handles both service names)
php_fpm_service() {
    action="$1"
    if service php_fpm "$action" 2>/dev/null; then
        return 0
    elif service php-fpm "$action" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get database credentials
DB_USER=$(cat /root/dbuser 2>/dev/null || echo "dbadmin")
DB_PASS=$(cat /root/dbpassword 2>/dev/null || echo "")
DB_NAME="nextcloud"

if [ -z "$DB_PASS" ]; then
    echo "ERROR: Cannot read database password from /root/dbpassword"
    exit 1
fi

# Find the MySQL backup from pre_update
PRE_UPDATE_BACKUP=""
MYSQL_BACKUP=""

if [ -f /root/last_pre_update_backup ]; then
    PRE_UPDATE_BACKUP=$(cat /root/last_pre_update_backup)
    if [ -f "$PRE_UPDATE_BACKUP/nextcloud_mysql.sql" ]; then
        MYSQL_BACKUP="$PRE_UPDATE_BACKUP/nextcloud_mysql.sql"
    fi
fi

# Also check for manual backup locations
if [ -z "$MYSQL_BACKUP" ]; then
    # Look for any mysql backup in /root
    for backup_dir in /root/pre_update_backup_* /root/mysql_backup_*; do
        if [ -d "$backup_dir" ]; then
            for sql_file in "$backup_dir"/nextcloud_mysql.sql "$backup_dir"/nextcloud.sql; do
                if [ -f "$sql_file" ] && [ -s "$sql_file" ]; then
                    MYSQL_BACKUP="$sql_file"
                    PRE_UPDATE_BACKUP="$backup_dir"
                    break 2
                fi
            done
        fi
    done
fi

if [ -z "$MYSQL_BACKUP" ]; then
    echo "ERROR: No MySQL backup found."
    echo ""
    echo "Expected locations:"
    echo "  - From pre_update: Check /root/last_pre_update_backup"
    echo "  - Manual backup: /root/pre_update_backup_*/nextcloud_mysql.sql"
    echo "  - Manual backup: /root/mysql_backup_*/nextcloud.sql"
    echo ""
    echo "If you have a MySQL dump elsewhere, you can specify it as an argument:"
    echo "  $0 /path/to/mysql_backup.sql"
    exit 1
fi

# Allow override via command line argument
if [ $# -ge 1 ] && [ -f "$1" ]; then
    MYSQL_BACKUP="$1"
    echo "Using specified MySQL backup: $MYSQL_BACKUP"
fi

BACKUP_SIZE=$(du -h "$MYSQL_BACKUP" | cut -f1)
echo "Found MySQL backup: $MYSQL_BACKUP ($BACKUP_SIZE)"
echo ""

# Check PostgreSQL status
if ! service postgresql status >/dev/null 2>&1; then
    echo "PostgreSQL is not running. Starting it..."
    service postgresql start 2>/dev/null || true
    sleep 3
    
    if ! service postgresql status >/dev/null 2>&1; then
        echo "ERROR: Could not start PostgreSQL"
        exit 1
    fi
fi

echo "PostgreSQL is running."

# Check if pgloader is installed
PGLOADER_AVAILABLE=0
if command -v pgloader >/dev/null 2>&1; then
    PGLOADER_AVAILABLE=1
    echo "pgloader is available for direct migration."
else
    echo "pgloader is NOT installed."
    echo ""
    echo "To install pgloader (recommended for automatic migration):"
    echo "  pkg install pgloader"
    echo ""
fi

echo ""
echo "WARNING: This will migrate data from MySQL backup to PostgreSQL."
echo "  - Nginx and PHP-FPM will be stopped during migration"
echo "  - The PostgreSQL database will be recreated (existing data will be lost)"
echo ""
echo "Press CTRL+C to cancel, or press ENTER to continue..."
read dummy

# Stop web services
echo ""
echo "Stopping web services..."
service nginx stop 2>/dev/null || true
php_fpm_service stop || true

# Ensure PostgreSQL database exists and is empty
echo ""
echo "Preparing PostgreSQL database..."

# Escape single quotes in password for SQL
DB_PASS_SQL=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")

# Drop and recreate the database to ensure clean state
su -m postgres -c "psql -c \"DROP DATABASE IF EXISTS $DB_NAME;\"" 2>/dev/null || true
su -m postgres -c "psql -c \"DROP USER IF EXISTS $DB_USER;\"" 2>/dev/null || true

# Create user and database
su -m postgres -c "psql -c \"CREATE USER $DB_USER WITH PASSWORD '$DB_PASS_SQL' NOSUPERUSER NOCREATEDB NOCREATEROLE;\""
su -m postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\""
su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\""
su -m postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\""

echo "PostgreSQL database prepared."

# Attempt to convert and import MySQL dump to PostgreSQL
# Note: This uses basic sed transformations since MySQL is no longer available
# For complex databases, using pgloader with a temporary MySQL instance is recommended
echo ""
echo "Converting MySQL dump to PostgreSQL format..."
echo "This may take a while depending on database size..."

# Create a temporary converted SQL file
CONVERTED_SQL="/tmp/nextcloud_pg_converted.sql"

# Basic MySQL to PostgreSQL conversion
# This handles common differences but may not cover all cases
cat "$MYSQL_BACKUP" | \
    sed 's/`//g' | \
    sed 's/ENGINE=InnoDB[^;]*//gi' | \
    sed 's/ENGINE=MyISAM[^;]*//gi' | \
    sed 's/DEFAULT CHARSET=[a-zA-Z0-9_]*//gi' | \
    sed 's/COLLATE=[a-zA-Z0-9_]*//gi' | \
    sed 's/AUTO_INCREMENT=[0-9]*//gi' | \
    sed 's/AUTO_INCREMENT/SERIAL/gi' | \
    sed 's/UNSIGNED//gi' | \
    sed 's/\\'\''/'\'\''/g' | \
    sed 's/TINYINT(1)/BOOLEAN/gi' | \
    sed 's/TINYINT([0-9]*)/SMALLINT/gi' | \
    sed 's/MEDIUMINT([0-9]*)/INTEGER/gi' | \
    sed 's/INT([0-9]*)/INTEGER/gi' | \
    sed 's/BIGINT([0-9]*)/BIGINT/gi' | \
    sed 's/DOUBLE/DOUBLE PRECISION/gi' | \
    sed 's/FLOAT([0-9,]*)/REAL/gi' | \
    sed 's/DATETIME/TIMESTAMP/gi' | \
    sed 's/LONGTEXT/TEXT/gi' | \
    sed 's/MEDIUMTEXT/TEXT/gi' | \
    sed 's/TINYTEXT/TEXT/gi' | \
    sed 's/LONGBLOB/BYTEA/gi' | \
    sed 's/MEDIUMBLOB/BYTEA/gi' | \
    sed 's/TINYBLOB/BYTEA/gi' | \
    sed 's/BLOB/BYTEA/gi' | \
    sed 's/VARBINARY([0-9]*)/BYTEA/gi' | \
    sed 's/BINARY([0-9]*)/BYTEA/gi' | \
    sed '/^\/\*!.*\*\/;$/d' | \
    sed '/^SET /d' | \
    sed '/^LOCK TABLES/d' | \
    sed '/^UNLOCK TABLES/d' | \
    sed '/^--/d' | \
    grep -v "^$" > "$CONVERTED_SQL" || true

IMPORT_SUCCESS=0
if [ -s "$CONVERTED_SQL" ]; then
    echo "Importing converted SQL into PostgreSQL..."
    
    # Import the converted SQL
    if PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -h localhost -d "$DB_NAME" -f "$CONVERTED_SQL" 2>/tmp/pg_import_errors.log; then
        echo "Import completed."
        IMPORT_SUCCESS=1
        # Check if there were errors
        if [ -s /tmp/pg_import_errors.log ]; then
            echo "Some warnings/errors occurred during import:"
            head -20 /tmp/pg_import_errors.log
            echo "..."
            echo "Full log at: /tmp/pg_import_errors.log"
        fi
    else
        echo "WARNING: Import had errors. Check /tmp/pg_import_errors.log"
        echo ""
        echo "The automatic SQL conversion may not handle all MySQL-specific syntax."
    fi
    
    rm -f "$CONVERTED_SQL"
else
    echo "WARNING: SQL conversion produced empty output."
fi

# If automatic import failed, provide guidance
if [ "$IMPORT_SUCCESS" = "0" ]; then
    echo ""
    echo "========================================"
    echo "MANUAL MIGRATION MAY BE REQUIRED"
    echo "========================================"
    echo ""
    if [ "$PGLOADER_AVAILABLE" = "1" ]; then
        echo "pgloader is installed but requires a live MySQL connection."
    else
        echo "For the best migration experience, install pgloader:"
        echo "  pkg install pgloader"
    fi
    echo ""
    echo "To use pgloader for migration:"
    echo "  1. Set up a temporary MySQL instance on another machine"
    echo "  2. Restore your backup: mysql -u root < $MYSQL_BACKUP"
    echo "  3. Run: pgloader mysql://$DB_USER:PASSWORD@mysql-host/$DB_NAME \\"
    echo "                 pgsql://$DB_USER:PASSWORD@localhost/$DB_NAME"
    echo ""
    echo "Your MySQL backup is preserved at: $MYSQL_BACKUP"
    echo "========================================"
fi

# Update Nextcloud config.php to use PostgreSQL
echo ""
echo "Updating Nextcloud configuration..."

NC_CONFIG="/usr/local/www/nextcloud/config/config.php"
if [ -f "$NC_CONFIG" ]; then
    # Use PHP to safely update the config
    # Pass credentials via environment variables to avoid escaping issues
    export NC_DB_USER="$DB_USER"
    export NC_DB_PASS="$DB_PASS"
    export NC_DB_NAME="$DB_NAME"
    export NC_CONFIG_PATH="$NC_CONFIG"
    
    php -r '
$configFile = getenv("NC_CONFIG_PATH");
if (file_exists($configFile)) {
    include $configFile;
    $config = isset($CONFIG) ? $CONFIG : array();
    
    // Update database settings
    $config["dbtype"] = "pgsql";
    $config["dbhost"] = "localhost";
    $config["dbport"] = "5432";
    $config["dbuser"] = getenv("NC_DB_USER");
    $config["dbpassword"] = getenv("NC_DB_PASS");
    $config["dbname"] = getenv("NC_DB_NAME");
    
    // Remove MySQL-specific setting
    if (isset($config["mysql.utf8mb4"])) {
        unset($config["mysql.utf8mb4"]);
    }
    
    // Write back the config
    $content = "<?php\n\$CONFIG = " . var_export($config, true) . ";\n";
    file_put_contents($configFile, $content);
    echo "Config updated successfully\n";
} else {
    echo "Config file not found\n";
    exit(1);
}
'
    
    # Clear environment variables
    unset NC_DB_USER NC_DB_PASS NC_DB_NAME NC_CONFIG_PATH
    
    echo "Nextcloud config.php updated for PostgreSQL."
else
    echo "WARNING: Nextcloud config.php not found at $NC_CONFIG"
fi

# Start services
echo ""
echo "Starting services..."
php_fpm_service start || true
service nginx start 2>/dev/null || true

# Verify migration
echo ""
echo "Verifying migration..."

# Check if PostgreSQL has tables
TABLE_COUNT=$(su -m postgres -c "psql -d $DB_NAME -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';\"" 2>/dev/null | tr -d ' ' || echo "0")

if [ "$TABLE_COUNT" -gt 0 ]; then
    echo "SUCCESS: PostgreSQL database has $TABLE_COUNT tables."
    
    # Try to run Nextcloud maintenance commands
    echo ""
    echo "Running Nextcloud database maintenance..."
    
    # Disable maintenance mode if it was on
    su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --off" 2>/dev/null || true
    
    # Add missing indices
    su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-indices" 2>/dev/null || true
    
    # Add missing columns
    su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-columns" 2>/dev/null || true
    
    # Add missing primary keys
    su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-primary-keys" 2>/dev/null || true
    
    echo ""
    echo "========================================"
    echo "Migration Complete"
    echo "========================================"
    echo ""
    echo "Please verify your Nextcloud installation by:"
    echo "  1. Accessing the web interface"
    echo "  2. Checking that your data is accessible"
    echo "  3. Running: su -m www -c 'php /usr/local/www/nextcloud/occ status'"
    echo ""
else
    echo "WARNING: PostgreSQL database appears empty (0 tables)."
    echo ""
    echo "The automatic conversion may have failed. Manual steps required:"
    echo ""
    echo "1. Install pgloader: pkg install pgloader"
    echo "2. Set up a temporary MySQL instance with your backup"
    echo "3. Use pgloader for direct MySQL to PostgreSQL migration"
    echo ""
    echo "Your MySQL backup is preserved at: $MYSQL_BACKUP"
    echo ""
    echo "Alternatively, you can do a fresh Nextcloud installation:"
    echo "  1. Access the web interface"
    echo "  2. Complete the setup wizard"
    echo "  3. Your files in the data directory will still be there"
    echo "     (but user accounts and settings will need to be recreated)"
fi

echo ""
echo "Backup location: $PRE_UPDATE_BACKUP"
echo ""
