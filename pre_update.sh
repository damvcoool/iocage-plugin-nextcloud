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

# Detect database type early (needed for maintenance mode)
log_step_start "Detecting database type"
DETECTED_DB_TYPE=""

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
log_step_end "Detecting database type"

# Track whether we started a DB service so we can stop it afterwards
POSTGRES_STARTED=0
MYSQL_STARTED=0

# Start database service if not running (needed for maintenance mode and backup)
log_step_start "Ensuring database service is running"
case "$DETECTED_DB_TYPE" in
    "$DB_TYPE_POSTGRESQL")
        # Ensure PostgreSQL log directory exists with proper permissions
        mkdir -p /var/log/postgresql
        chown postgres:postgres /var/log/postgresql 2>/dev/null || true
        
        if ! service postgresql status >/dev/null 2>&1; then
            log_info "Starting PostgreSQL..."
            service postgresql start 2>/dev/null || true
            POSTGRES_STARTED=1
            # Wait for PostgreSQL to be ready
            max_wait=30
            waited=0
            while ! service postgresql status >/dev/null 2>&1 && [ $waited -lt $max_wait ]; do
                sleep 1
                waited=$((waited + 1))
                if [ $((waited % 5)) -eq 0 ]; then
                    log_info "Waiting for PostgreSQL... ($waited/$max_wait)"
                fi
            done
            if service postgresql status >/dev/null 2>&1; then
                log_info "PostgreSQL started successfully"
            else
                log_warn "PostgreSQL may not have started properly"
            fi
        else
            log_info "PostgreSQL is already running"
        fi
        ;;
    "$DB_TYPE_MYSQL")
        if ! service mysql-server status >/dev/null 2>&1; then
            log_info "Starting MySQL..."
            service mysql-server start 2>/dev/null || true
            MYSQL_STARTED=1
            # Wait for MySQL to be ready
            max_wait=30
            waited=0
            while ! service mysql-server status >/dev/null 2>&1 && [ $waited -lt $max_wait ]; do
                sleep 1
                waited=$((waited + 1))
                if [ $((waited % 5)) -eq 0 ]; then
                    log_info "Waiting for MySQL... ($waited/$max_wait)"
                fi
            done
            if service mysql-server status >/dev/null 2>&1; then
                log_info "MySQL started successfully"
            else
                log_warn "MySQL may not have started properly"
            fi
        else
            log_info "MySQL is already running"
        fi
        ;;
    *)
        log_info "No database service to start"
        ;;
esac
log_step_end "Ensuring database service is running"

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

# If SSL_STATE is none (HTTP only), ensure ALLOW_INSECURE_ACCESS is set
# This ensures the HTTP-only configuration is preserved during upgrade
if [ "$SSL_STATE" = "none" ]; then
    log_info "HTTP-only configuration detected, ensuring ALLOW_INSECURE_ACCESS=true"
    if [ ! -f /root/jail_options.env ]; then
        echo "ALLOW_INSECURE_ACCESS=true" > /root/jail_options.env
        log_info "Created jail_options.env with ALLOW_INSECURE_ACCESS=true"
    elif grep -q "ALLOW_INSECURE_ACCESS=true" /root/jail_options.env; then
        log_info "ALLOW_INSECURE_ACCESS=true already set"
    elif grep -q "ALLOW_INSECURE_ACCESS" /root/jail_options.env; then
        # Update existing value (may be set to false)
        sed -i '' 's/ALLOW_INSECURE_ACCESS=.*/ALLOW_INSECURE_ACCESS=true/' /root/jail_options.env 2>/dev/null || \
        sed -i 's/ALLOW_INSECURE_ACCESS=.*/ALLOW_INSECURE_ACCESS=true/' /root/jail_options.env
        log_info "Updated ALLOW_INSECURE_ACCESS to true in jail_options.env"
    else
        echo "ALLOW_INSECURE_ACCESS=true" >> /root/jail_options.env
        log_info "Added ALLOW_INSECURE_ACCESS=true to jail_options.env"
    fi
fi

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

# Perform database backup
log_step_start "Performing database backup"
case "$DETECTED_DB_TYPE" in
    "$DB_TYPE_POSTGRESQL")
        log_info "PostgreSQL detected, creating backup..."
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
echo "$DETECTED_DB_TYPE" > "$BACKUP_DIR/database_type.txt"
log_info "Database type saved: $DETECTED_DB_TYPE"
log_step_end "Performing database backup"

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

# Stop all services before package update to ensure clean transition
# This is critical when transitioning from MySQL to PostgreSQL
log_step_start "Stopping all services before package update"

# Stop nginx first (depends on php-fpm and database)
log_info "Stopping nginx..."
if service nginx stop >/dev/null 2>&1; then
    log_info "nginx stopped"
else
    log_info "nginx was not running or failed to stop"
fi

# Stop php-fpm
log_info "Stopping php-fpm..."
if service php_fpm stop >/dev/null 2>&1; then
    log_info "php-fpm stopped"
else
    # Try alternative service name
    if service php-fpm stop >/dev/null 2>&1; then
        log_info "php-fpm stopped (alternative name)"
    else
        log_info "php-fpm was not running or failed to stop"
    fi
fi

# Stop redis
log_info "Stopping redis..."
if service redis stop >/dev/null 2>&1; then
    log_info "redis stopped"
else
    log_info "redis was not running or failed to stop"
fi

# Stop fail2ban
log_info "Stopping fail2ban..."
if service fail2ban stop >/dev/null 2>&1; then
    log_info "fail2ban stopped"
else
    log_info "fail2ban was not running or failed to stop"
fi

# Stop database services (both MySQL and PostgreSQL if running)
log_info "Stopping database services..."
if service mysql-server stop >/dev/null 2>&1; then
    log_info "MySQL stopped"
fi
if service postgresql stop >/dev/null 2>&1; then
    log_info "PostgreSQL stopped"
fi

log_step_end "Stopping all services before package update"

# MySQL to PostgreSQL migration using occ db:convert-type
# This migration must happen BEFORE the plugin upgrade removes MySQL
log_step_start "MySQL to PostgreSQL migration (if needed)"

if [ "$DETECTED_DB_TYPE" = "$DB_TYPE_MYSQL" ]; then
    log_info "MySQL detected - performing database migration using occ db:convert-type"
    
    # Install PostgreSQL if not already installed
    log_info "Installing PostgreSQL..."
    if pkg install -y postgresql18-server postgresql18-client >/dev/null 2>&1; then
        log_info "PostgreSQL installed successfully"
    else
        log_warn "PostgreSQL may already be installed or installation failed"
    fi
    
    # Install PHP PostgreSQL extension required for occ db:convert-type
    # Detect the installed PHP version and install the matching pdo_pgsql extension
    log_info "Installing PHP PostgreSQL extension for database migration..."
    PHP_PGSQL_INSTALLED=0
    PHP_VERSION=$(php -v 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1,2 | tr -d '.')
    # Validate PHP_VERSION is a 2-digit number (e.g., 84, 83, 82)
    if [ -n "$PHP_VERSION" ] && echo "$PHP_VERSION" | grep -qE '^[0-9]{2}$'; then
        log_info "Detected PHP version: $PHP_VERSION"
        if pkg install -y "php${PHP_VERSION}-pdo_pgsql" >/dev/null 2>&1; then
            log_info "PHP PostgreSQL extension installed successfully"
            PHP_PGSQL_INSTALLED=1
        else
            log_warn "PHP PostgreSQL extension may already be installed or installation failed"
            # Check if extension is already installed
            if php -m 2>/dev/null | grep -qi "pdo_pgsql"; then
                log_info "PHP PostgreSQL extension is already available"
                PHP_PGSQL_INSTALLED=1
            fi
        fi
    else
        log_warn "Could not detect PHP version, trying common versions..."
        # Try common PHP versions (84, 83, 82) as fallback
        for ver in 84 83 82; do
            if pkg install -y "php${ver}-pdo_pgsql" >/dev/null 2>&1; then
                log_info "PHP PostgreSQL extension (php${ver}-pdo_pgsql) installed successfully"
                PHP_PGSQL_INSTALLED=1
                break
            fi
        done
    fi
    
    # Final check if PHP PostgreSQL extension is available
    if [ "$PHP_PGSQL_INSTALLED" = "0" ]; then
        if php -m 2>/dev/null | grep -qi "pdo_pgsql"; then
            log_info "PHP PostgreSQL extension is already available"
        else
            log_warn "Failed to install PHP PostgreSQL extension - occ db:convert-type may fail"
        fi
    fi
    
    # Enable PostgreSQL in rc.conf
    log_info "Enabling PostgreSQL in rc.conf..."
    sysrc -f /etc/rc.conf postgresql_enable="YES" 2>/dev/null || true
    sysrc -f /etc/rc.conf postgresql_initdb_flags="--auth-local=trust --auth-host=trust" 2>/dev/null || true
    
    # Initialize PostgreSQL if needed
    PG_DATA_FOUND=0
    for pg_data_dir in /var/db/postgres/data* ; do
        if [ -d "$pg_data_dir" ]; then
            PG_DATA_FOUND=1
            break
        fi
    done
    
    if [ "$PG_DATA_FOUND" = "0" ]; then
        log_info "Initializing PostgreSQL database..."
        mkdir -p /var/log/postgresql
        chown postgres:postgres /var/log/postgresql 2>/dev/null || true
        if /usr/local/etc/rc.d/postgresql oneinitdb 2>/dev/null; then
            log_info "PostgreSQL initialized successfully"
        else
            log_warn "PostgreSQL initialization may have failed"
        fi
    fi
    
    # Start PostgreSQL
    log_info "Starting PostgreSQL..."
    service postgresql start 2>/dev/null || true
    
    # Wait for PostgreSQL to be ready
    max_wait=30
    waited=0
    while ! su -m postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1 && [ $waited -lt $max_wait ]; do
        sleep 1
        waited=$((waited + 1))
        if [ $((waited % 5)) -eq 0 ]; then
            log_info "Waiting for PostgreSQL... ($waited/$max_wait)"
        fi
    done
    
    if su -m postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1; then
        log_info "PostgreSQL is ready"
        
        # Create PostgreSQL user and database for the migration
        log_info "Creating PostgreSQL user and database..."
        
        # Escape single quotes in password for SQL
        DB_PASS_SQL=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")
        
        # Check if database already exists
        if su -m postgres -c "psql -lqt | cut -d \| -f 1 | grep -qw $DB_NAME" 2>/dev/null; then
            log_info "PostgreSQL database '$DB_NAME' already exists"
        else
            # Create user and database
            # Note: Password is passed via ALTER USER which is slightly more secure
            su -m postgres -c "psql -c \"CREATE USER $DB_USER WITH NOSUPERUSER NOCREATEDB NOCREATEROLE;\"" 2>/dev/null || true
            su -m postgres -c "psql -c \"ALTER USER $DB_USER WITH PASSWORD '$DB_PASS_SQL';\"" 2>/dev/null || true
            su -m postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\"" 2>/dev/null || true
            su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\"" 2>/dev/null || true
            su -m postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\"" 2>/dev/null || true
            log_info "PostgreSQL user and database created"
        fi
        
        # Ensure MySQL is running for the migration
        if ! service mysql-server status >/dev/null 2>&1; then
            log_info "Starting MySQL for migration..."
            service mysql-server start 2>/dev/null || true
            sleep 3
        fi
        
        # Check if PostgreSQL already has Nextcloud data (migration already done)
        if su -m postgres -c "psql -d $DB_NAME -c \"SELECT 1 FROM oc_users LIMIT 1\"" >/dev/null 2>&1; then
            log_info "PostgreSQL already has Nextcloud data - migration not needed"
            MIGRATION_DONE=1
        else
            MIGRATION_DONE=0
            
            # Run occ db:convert-type to migrate from MySQL to PostgreSQL
            log_info "Running Nextcloud database migration (occ db:convert-type)..."
            log_info "This may take several minutes depending on database size..."
            
            # Make sure Nextcloud is NOT in maintenance mode for this operation
            su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --off" 2>/dev/null || true
            
            # Run the migration using environment variable for password (more secure than command line)
            export OCC_DB_PASS="$DB_PASS"
            if su -m www -c "php /usr/local/www/nextcloud/occ db:convert-type --all-apps --password \"\$OCC_DB_PASS\" pgsql '$DB_USER' localhost '$DB_NAME'" 2>&1; then
                log_info "Database migration completed successfully!"
                MIGRATION_DONE=1
                
                # Save migration status for post_update
                echo "occ_convert_success" > "$BACKUP_DIR/migration_method.txt"
            else
                log_warn "occ db:convert-type failed - will fall back to SQL conversion in post_update"
                echo "occ_convert_failed" > "$BACKUP_DIR/migration_method.txt"
            fi
            unset OCC_DB_PASS
        fi
        
        if [ "$MIGRATION_DONE" = "1" ]; then
            log_info "Migration successful - stopping MySQL"
            service mysql-server stop 2>/dev/null || true
        fi
    else
        log_warn "PostgreSQL did not start - migration will be attempted in post_update"
    fi
    
    # Disable MySQL in rc.conf (will be removed during upgrade)
    if grep -q 'mysql_enable="YES"' /etc/rc.conf 2>/dev/null; then
        log_info "Disabling mysql_enable in rc.conf..."
        sysrc -f /etc/rc.conf mysql_enable="NO" 2>/dev/null || true
    fi
    
    log_info "MySQL to PostgreSQL migration preparation completed"
elif [ "$DETECTED_DB_TYPE" = "$DB_TYPE_POSTGRESQL" ]; then
    log_info "PostgreSQL already in use - no migration needed"
else
    log_info "No database detected - fresh install, no migration needed"
fi

log_step_end "MySQL to PostgreSQL migration (if needed)"

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
