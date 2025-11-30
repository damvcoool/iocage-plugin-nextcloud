#!/bin/sh

set -eu

# Check for flags
AUTO_MODE=0
FORCE_SQL_FALLBACK=0
MYSQL_BACKUP_ARG=""
for arg in "$@"; do
    case "$arg" in
        --auto)
            AUTO_MODE=1
            ;;
        --force-sql-fallback)
            FORCE_SQL_FALLBACK=1
            ;;
        *)
            # Assume it's a backup file path
            if [ -f "$arg" ]; then
                MYSQL_BACKUP_ARG="$arg"
            fi
            ;;
    esac
done

# Source logging helper if available (for consistent logging in auto mode)
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

if [ "$AUTO_MODE" = "0" ]; then
    echo "========================================"
    echo "MySQL to PostgreSQL Migration Tool"
    echo "========================================"
    echo ""
    echo "This script migrates your Nextcloud data from MySQL to PostgreSQL."
    echo ""
    echo "RECOMMENDED: Use Nextcloud's built-in occ db:convert-type command"
    echo "This requires MySQL to still be running alongside PostgreSQL."
    echo ""
    echo "FALLBACK: If MySQL is no longer available, this script can attempt"
    echo "to import from a MySQL SQL backup file (less reliable)."
    echo ""
fi

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
    if [ "$AUTO_MODE" = "1" ]; then
        log_error "Cannot read database password from /root/dbpassword"
    else
        echo "ERROR: Cannot read database password from /root/dbpassword"
    fi
    exit 1
fi

# Check PostgreSQL status
if ! service postgresql status >/dev/null 2>&1; then
    if [ "$AUTO_MODE" = "1" ]; then
        log_info "PostgreSQL is not running. Starting it..."
    else
        echo "PostgreSQL is not running. Starting it..."
    fi
    service postgresql start 2>/dev/null || true
    sleep 3
    
    if ! service postgresql status >/dev/null 2>&1; then
        if [ "$AUTO_MODE" = "1" ]; then
            log_error "Could not start PostgreSQL"
        else
            echo "ERROR: Could not start PostgreSQL"
        fi
        exit 1
    fi
fi

# Check if MySQL is available for occ db:convert-type
MYSQL_AVAILABLE=0
if service mysql-server status >/dev/null 2>&1; then
    MYSQL_AVAILABLE=1
fi

# Escape single quotes in password for SQL
DB_PASS_SQL=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")

# Ensure PostgreSQL database exists
ensure_postgresql_db() {
    # Check if database already exists
    if su -m postgres -c "psql -lqt | cut -d \| -f 1 | grep -qw $DB_NAME" 2>/dev/null; then
        if [ "$AUTO_MODE" = "1" ]; then
            log_info "PostgreSQL database '$DB_NAME' already exists"
        else
            echo "PostgreSQL database '$DB_NAME' already exists"
        fi
    else
        if [ "$AUTO_MODE" = "1" ]; then
            log_info "Creating PostgreSQL user and database..."
        else
            echo "Creating PostgreSQL user and database..."
        fi
        # Create user and database using ALTER USER for password (more secure)
        su -m postgres -c "psql -c \"CREATE USER $DB_USER WITH NOSUPERUSER NOCREATEDB NOCREATEROLE;\"" 2>/dev/null || true
        su -m postgres -c "psql -c \"ALTER USER $DB_USER WITH PASSWORD '$DB_PASS_SQL';\"" 2>/dev/null || true
        su -m postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\"" 2>/dev/null || true
        su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\"" 2>/dev/null || true
        su -m postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\"" 2>/dev/null || true
    fi
}

# Method 1: Use occ db:convert-type (RECOMMENDED)
try_occ_convert() {
    if [ "$AUTO_MODE" = "1" ]; then
        log_info "Attempting migration using occ db:convert-type..."
    else
        echo ""
        echo "Attempting migration using occ db:convert-type..."
        echo "This is the recommended method and handles all schema conversions properly."
        echo ""
    fi
    
    ensure_postgresql_db
    
    # Make sure Nextcloud is NOT in maintenance mode for this operation
    su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --off" 2>/dev/null || true
    
    # Run the migration using environment variable for password (more secure than command line)
    export OCC_DB_PASS="$DB_PASS"
    if su -m www -c "php /usr/local/www/nextcloud/occ db:convert-type --all-apps --password \"\$OCC_DB_PASS\" pgsql '$DB_USER' localhost '$DB_NAME'" 2>&1; then
        unset OCC_DB_PASS
        if [ "$AUTO_MODE" = "1" ]; then
            log_info "occ db:convert-type completed successfully!"
        else
            echo ""
            echo "SUCCESS: Database migration completed using occ db:convert-type!"
        fi
        return 0
    else
        unset OCC_DB_PASS
        if [ "$AUTO_MODE" = "1" ]; then
            log_warn "occ db:convert-type failed"
        else
            echo ""
            echo "WARNING: occ db:convert-type failed"
        fi
        return 1
    fi
}

# Method 2: SQL Fallback - Import from MySQL SQL dump (less reliable)
try_sql_fallback() {
    if [ "$AUTO_MODE" = "1" ]; then
        log_info "Attempting SQL fallback migration from MySQL backup..."
    else
        echo ""
        echo "Attempting SQL fallback migration from MySQL backup..."
        echo "Note: This method is less reliable than occ db:convert-type."
        echo ""
    fi
    
    # Find the MySQL backup
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
    
    # Allow override via command line argument
    if [ -n "$MYSQL_BACKUP_ARG" ]; then
        MYSQL_BACKUP="$MYSQL_BACKUP_ARG"
    fi
    
    if [ -z "$MYSQL_BACKUP" ] || [ ! -f "$MYSQL_BACKUP" ]; then
        if [ "$AUTO_MODE" = "1" ]; then
            log_error "No MySQL backup found for SQL fallback"
        else
            echo "ERROR: No MySQL backup found."
            echo "Expected locations:"
            echo "  - From pre_update: Check /root/last_pre_update_backup"
            echo "  - Manual backup: /root/pre_update_backup_*/nextcloud_mysql.sql"
        fi
        return 1
    fi
    
    BACKUP_SIZE=$(du -h "$MYSQL_BACKUP" | cut -f1)
    if [ "$AUTO_MODE" = "1" ]; then
        log_info "Found MySQL backup: $MYSQL_BACKUP ($BACKUP_SIZE)"
    else
        echo "Found MySQL backup: $MYSQL_BACKUP ($BACKUP_SIZE)"
    fi
    
    # Stop web services
    if [ "$AUTO_MODE" = "1" ]; then
        log_info "Stopping web services for migration..."
    else
        echo "Stopping web services..."
    fi
    service nginx stop 2>/dev/null || true
    php_fpm_service stop || true
    
    # Prepare PostgreSQL database (drop and recreate for clean state)
    if [ "$AUTO_MODE" = "1" ]; then
        log_info "Preparing PostgreSQL database..."
    else
        echo "Preparing PostgreSQL database..."
    fi
    
    su -m postgres -c "psql -c \"DROP DATABASE IF EXISTS $DB_NAME;\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"DROP USER IF EXISTS $DB_USER;\"" 2>/dev/null || true
    # Create user and set password separately for security
    su -m postgres -c "psql -c \"CREATE USER $DB_USER WITH NOSUPERUSER NOCREATEDB NOCREATEROLE;\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"ALTER USER $DB_USER WITH PASSWORD '$DB_PASS_SQL';\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\"" 2>/dev/null || true
    su -m postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\"" 2>/dev/null || true
    
    # Convert and import MySQL dump to PostgreSQL
    if [ "$AUTO_MODE" = "1" ]; then
        log_info "Converting MySQL dump to PostgreSQL format..."
    else
        echo "Converting MySQL dump to PostgreSQL format..."
    fi
    
    CONVERTED_SQL="/tmp/nextcloud_pg_converted.sql"
    
    # MySQL to PostgreSQL conversion using sed
    cat "$MYSQL_BACKUP" | \
        sed 's/`//g' | \
        sed 's/ENGINE=InnoDB[^;]*//gi' | \
        sed 's/ENGINE=MyISAM[^;]*//gi' | \
        sed 's/DEFAULT CHARSET=[a-zA-Z0-9_]*//gi' | \
        sed 's/COLLATE=[a-zA-Z0-9_]*//gi' | \
        sed 's/COLLATE [a-zA-Z0-9_]*//gi' | \
        sed 's/AUTO_INCREMENT=[0-9]*//gi' | \
        sed 's/UNSIGNED//gi' | \
        sed 's/  */ /g' | \
        sed 's/bigint([0-9]*) NOT NULL AUTO_INCREMENT/BIGSERIAL/gi' | \
        sed 's/bigint NOT NULL AUTO_INCREMENT/BIGSERIAL/gi' | \
        sed 's/int([0-9]*) NOT NULL AUTO_INCREMENT/SERIAL/gi' | \
        sed 's/int NOT NULL AUTO_INCREMENT/SERIAL/gi' | \
        sed 's/AUTO_INCREMENT/SERIAL/gi' | \
        sed 's/\\'\''/'\'\''/g' | \
        sed 's/TINYINT(1)/SMALLINT/gi' | \
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
        sed '/^[[:space:]]*KEY [a-zA-Z0-9_]* ([^)]*),*$/d' | \
        sed '/^[[:space:]]*UNIQUE KEY [a-zA-Z0-9_]* ([^)]*),*$/d' | \
        sed '/^[[:space:]]*FULLTEXT KEY [a-zA-Z0-9_]* ([^)]*),*$/d' | \
        sed '/^\/\*!.*\*\/;$/d' | \
        sed '/^SET /d' | \
        sed '/^LOCK TABLES/d' | \
        sed '/^UNLOCK TABLES/d' | \
        sed '/^--/d' | \
        sed 's/[[:space:]]user[[:space:]]/ "user" /gi' | \
        sed 's/, user,/, "user",/gi' | \
        sed 's/,user,/,"user",/gi' | \
        sed 's/(user,/("user",/gi' | \
        sed 's/, user)/, "user")/gi' | \
        sed 's/,user)/,"user")/gi' | \
        grep -v "^$" | \
        awk '
        {
            if (NR > 1) {
                if ($0 ~ /^[[:space:]]*\)/) {
                    gsub(/,[[:space:]]*$/, "", prev_line)
                }
                print prev_line
            }
            prev_line = $0
        }
        END {
            print prev_line
        }
        ' > "$CONVERTED_SQL" || true
    
    IMPORT_SUCCESS=0
    if [ -s "$CONVERTED_SQL" ]; then
        if [ "$AUTO_MODE" = "1" ]; then
            log_info "Importing converted SQL into PostgreSQL..."
        else
            echo "Importing converted SQL into PostgreSQL..."
        fi
        
        if PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -h localhost -d "$DB_NAME" -f "$CONVERTED_SQL" 2>/tmp/pg_import_errors.log; then
            IMPORT_SUCCESS=1
        fi
        rm -f "$CONVERTED_SQL"
    fi
    
    # Verify migration
    TABLE_COUNT=$(su -m postgres -c "psql -d $DB_NAME -t -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';\"" 2>/dev/null | tr -d ' ' || echo "0")
    
    if [ "$TABLE_COUNT" -gt 0 ]; then
        # Update Nextcloud config.php to use PostgreSQL
        NC_CONFIG="/usr/local/www/nextcloud/config/config.php"
        if [ -f "$NC_CONFIG" ]; then
            export NC_DB_USER="$DB_USER"
            export NC_DB_PASS="$DB_PASS"
            export NC_DB_NAME="$DB_NAME"
            export NC_CONFIG_PATH="$NC_CONFIG"
            
            php -r '
$configFile = getenv("NC_CONFIG_PATH");
if (file_exists($configFile)) {
    include $configFile;
    $config = isset($CONFIG) ? $CONFIG : array();
    $config["dbtype"] = "pgsql";
    $config["dbhost"] = "localhost";
    $config["dbport"] = "5432";
    $config["dbuser"] = getenv("NC_DB_USER");
    $config["dbpassword"] = getenv("NC_DB_PASS");
    $config["dbname"] = getenv("NC_DB_NAME");
    if (isset($config["mysql.utf8mb4"])) {
        unset($config["mysql.utf8mb4"]);
    }
    $content = "<?php\n\$CONFIG = " . var_export($config, true) . ";\n";
    file_put_contents($configFile, $content);
}
'
            unset NC_DB_USER NC_DB_PASS NC_DB_NAME NC_CONFIG_PATH
        fi
        
        if [ "$AUTO_MODE" = "1" ]; then
            log_info "SQL fallback migration completed - $TABLE_COUNT tables imported"
        else
            echo "SUCCESS: SQL fallback migration completed - $TABLE_COUNT tables imported"
        fi
        return 0
    else
        if [ "$AUTO_MODE" = "1" ]; then
            log_warn "SQL fallback migration failed - no tables in database"
        else
            echo "WARNING: SQL fallback migration failed - no tables imported"
        fi
        return 1
    fi
}

# Main migration logic
if [ "$AUTO_MODE" = "1" ]; then
    log_step_start "MySQL to PostgreSQL Migration"
fi

MIGRATION_SUCCESS=0

# Check if PostgreSQL already has Nextcloud data
if su -m postgres -c "psql -d $DB_NAME -c \"SELECT 1 FROM oc_users LIMIT 1\"" >/dev/null 2>&1; then
    if [ "$AUTO_MODE" = "1" ]; then
        log_info "PostgreSQL already has Nextcloud data - migration not needed"
        log_step_end "MySQL to PostgreSQL Migration" "not needed"
    else
        echo "PostgreSQL already has Nextcloud data - migration not needed."
    fi
    exit 0
fi

# Try occ db:convert-type first if MySQL is available (and not forced to use SQL fallback)
if [ "$MYSQL_AVAILABLE" = "1" ] && [ "$FORCE_SQL_FALLBACK" = "0" ]; then
    if [ "$AUTO_MODE" = "0" ]; then
        echo ""
        echo "MySQL is running - using occ db:convert-type (recommended method)"
        echo ""
        echo "Press CTRL+C to cancel, or press ENTER to continue..."
        read dummy
    fi
    
    if try_occ_convert; then
        MIGRATION_SUCCESS=1
    fi
fi

# If occ method failed or MySQL not available, try SQL fallback
if [ "$MIGRATION_SUCCESS" = "0" ]; then
    if [ "$AUTO_MODE" = "0" ] && [ "$MYSQL_AVAILABLE" = "0" ]; then
        echo ""
        echo "MySQL is not running - will use SQL fallback method"
        echo ""
        echo "WARNING: This will recreate the PostgreSQL database from MySQL backup."
        echo "Press CTRL+C to cancel, or press ENTER to continue..."
        read dummy
    fi
    
    if try_sql_fallback; then
        MIGRATION_SUCCESS=1
    fi
fi

# Final status
if [ "$MIGRATION_SUCCESS" = "1" ]; then
    # Start services if in interactive mode
    if [ "$AUTO_MODE" = "0" ]; then
        echo ""
        echo "Starting services..."
        php_fpm_service start || true
        service nginx start 2>/dev/null || true
        
        # Run Nextcloud maintenance commands
        echo "Running Nextcloud database maintenance..."
        su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --off" 2>/dev/null || true
        su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-indices" 2>/dev/null || true
        su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-columns" 2>/dev/null || true
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
    else
        log_info "Migration completed successfully"
        log_step_end "MySQL to PostgreSQL Migration" "success"
    fi
    exit 0
else
    if [ "$AUTO_MODE" = "1" ]; then
        log_error "Migration failed"
        log_step_end "MySQL to PostgreSQL Migration" "failed"
    else
        echo ""
        echo "========================================"
        echo "Migration Failed"
        echo "========================================"
        echo ""
        echo "The automatic migration could not complete successfully."
        echo ""
        echo "Options:"
        echo "  1. If MySQL is available, try: occ db:convert-type manually"
        echo "  2. Do a fresh Nextcloud installation via the web interface"
        echo "     (your files in the data directory will still be there)"
        echo ""
    fi
    exit 1
fi
