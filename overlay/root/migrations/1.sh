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

log_step_start "Migration 1: Initial setup"

# Generate certificates so nginx is happy
log_info "Generating self-signed TLS certificates..."
generate_self_signed_tls_certificates

# Enable and start new services
log_info "Enabling Redis service..."
sysrc -f /etc/rc.conf redis_enable="YES"
log_info "Enabling Fail2ban service..."
sysrc -f /etc/rc.conf fail2ban_enable="YES"

# Check if we have PostgreSQL or MySQL
log_info "Checking database services..."
if service postgresql status >/dev/null 2>&1; then
    # Already on PostgreSQL
    log_info "PostgreSQL already running"
    service postgresql restart 2>/dev/null || true
elif service mysql-server status >/dev/null 2>&1; then
    # Still on MySQL
    log_info "MySQL detected, configuring MySQL..."
    sysrc -f /etc/rc.conf mysql_enable="YES"
    service mysql-server start 2>/dev/null || true
    
    # Wait for mysql to be up
    log_info "Waiting for MySQL to be ready..."
    max_attempts=30
    attempt=0
    until mysql --user dbadmin --password="$(cat /root/dbpassword)" --execute "SHOW DATABASES" > /dev/null 2>/dev/null || [ $attempt -eq $max_attempts ]
    do
        attempt=$((attempt + 1))
        log_info "MariaDB is unavailable - attempt $attempt of $max_attempts"
        sleep 2
    done
    if [ $attempt -lt $max_attempts ]; then
        log_info "MySQL is ready"
    else
        log_warn "MySQL did not become ready in time"
    fi
else
    # No database service running - check if PostgreSQL is enabled and start it
    log_info "No database service running"
    if grep -q 'postgresql_enable="YES"' /etc/rc.conf 2>/dev/null; then
        # Check if PostgreSQL needs initialization (data directory doesn't exist)
        # Look for any postgres data directory (supports different PostgreSQL versions)
        PG_DATA_FOUND=0
        for pg_data_dir in /var/db/postgres/data* ; do
            if [ -d "$pg_data_dir" ]; then
                PG_DATA_FOUND=1
                break
            fi
        done
        
        if [ "$PG_DATA_FOUND" = "0" ]; then
            log_info "PostgreSQL not initialized - initializing now..."
            # Set authentication options to suppress initdb warning about "trust" authentication
            sysrc -f /etc/rc.conf postgresql_initdb_flags="--auth-local=trust --auth-host=trust"
            if /usr/local/etc/rc.d/postgresql oneinitdb 2>/dev/null; then
                log_info "PostgreSQL initialized successfully"
            else
                log_warn "PostgreSQL initialization may have failed - service start will be attempted"
            fi
        fi
        
        log_info "PostgreSQL is enabled, starting service..."
        service postgresql start 2>/dev/null || true
        
        # Wait for PostgreSQL to be ready
        log_info "Waiting for PostgreSQL to be ready..."
        max_attempts=30
        attempt=0
        until su -m postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1 || [ $attempt -eq $max_attempts ]
        do
            attempt=$((attempt + 1))
            log_info "PostgreSQL is unavailable - attempt $attempt of $max_attempts"
            sleep 2
        done
        if [ $attempt -lt $max_attempts ]; then
            log_info "PostgreSQL is ready"
        else
            log_warn "PostgreSQL did not become ready in time"
        fi
    elif grep -q 'mysql_enable="YES"' /etc/rc.conf 2>/dev/null; then
        log_info "MySQL is enabled, starting service..."
        service mysql-server start 2>/dev/null || true
        
        # Wait for MySQL to be ready
        log_info "Waiting for MySQL to be ready..."
        max_attempts=30
        attempt=0
        until mysql --user dbadmin --password="$(cat /root/dbpassword)" --execute "SHOW DATABASES" > /dev/null 2>/dev/null || [ $attempt -eq $max_attempts ]
        do
            attempt=$((attempt + 1))
            log_info "MySQL is unavailable - attempt $attempt of $max_attempts"
            sleep 2
        done
        if [ $attempt -lt $max_attempts ]; then
            log_info "MySQL is ready"
        else
            log_warn "MySQL did not become ready in time"
        fi
    else
        log_warn "No database service enabled in rc.conf"
    fi
fi

log_info "Starting Redis..."
service redis start 2>/dev/null
log_info "Starting Fail2ban..."
service fail2ban start 2>/dev/null

# Check if we're upgrading from MySQL to PostgreSQL and need to update config.php
# This happens when the old config.php has dbtype=mysql but PostgreSQL is now enabled
log_info "Checking for MySQL to PostgreSQL migration..."
NEEDS_DB_CONFIG_UPDATE=0
NC_CONFIG_FILE="/usr/local/www/nextcloud/config/config.php"

if [ -f "$NC_CONFIG_FILE" ]; then
    # Check if config.php still points to MySQL
    NC_DBTYPE=$(grep "dbtype" "$NC_CONFIG_FILE" 2>/dev/null | sed "s/.*=> *[\"']\([^\"']*\)[\"'].*/\1/" | head -1)
    if [ "$NC_DBTYPE" = "mysql" ]; then
        # Config still points to MySQL, but we're now on PostgreSQL
        if grep -q 'postgresql_enable="YES"' /etc/rc.conf 2>/dev/null && ! service mysql-server status >/dev/null 2>&1; then
            log_info "Detected MySQL config but PostgreSQL is enabled - updating configuration..."
            NEEDS_DB_CONFIG_UPDATE=1
        fi
    fi
fi

# If we need to update the database configuration in config.php
if [ "$NEEDS_DB_CONFIG_UPDATE" = "1" ]; then
    log_info "Updating Nextcloud config.php for PostgreSQL..."
    
    # Get database credentials
    DB_USER=$(cat /root/dbuser 2>/dev/null || echo "dbadmin")
    DB_PASS=$(cat /root/dbpassword 2>/dev/null || echo "")
    DB_NAME="nextcloud"
    
    if [ -z "$DB_PASS" ]; then
        log_warn "No database password found, generating new one..."
        export LC_ALL=C
        openssl rand --hex 8 > /root/dbpassword
        DB_PASS=$(cat /root/dbpassword)
    fi
    
    # Ensure PostgreSQL is running and ready
    log_info "Ensuring PostgreSQL is running..."
    service postgresql start 2>/dev/null || true
    max_attempts=30
    attempt=0
    until su -m postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1 || [ $attempt -eq $max_attempts ]
    do
        attempt=$((attempt + 1))
        sleep 2
    done
    
    if [ $attempt -eq $max_attempts ]; then
        log_error "PostgreSQL failed to start - cannot update database configuration"
    else
        # Create PostgreSQL database and user if they don't exist
        log_info "Creating PostgreSQL database and user..."
        su -m postgres -c "psql -c \"CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';\"" 2>/dev/null || log_info "User $DB_USER may already exist"
        su -m postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\"" 2>/dev/null || log_info "Database $DB_NAME may already exist"
        su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\"" 2>/dev/null || true
        su -m postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\"" 2>/dev/null || true
        
        # Update config.php to use PostgreSQL instead of MySQL
        # Use sed to update the database settings
        log_info "Updating database settings in config.php..."
        
        # Update dbtype from mysql to pgsql
        sed -i.bak "s/'dbtype' *=> *'mysql'/'dbtype' => 'pgsql'/" "$NC_CONFIG_FILE"
        
        # Update dbhost to localhost (in case it was using a socket path)
        sed -i "s/'dbhost' *=> *'[^']*'/'dbhost' => 'localhost'/" "$NC_CONFIG_FILE"
        
        # Update dbport to 5432 (PostgreSQL default)
        sed -i "s/'dbport' *=> *'[^']*'/'dbport' => '5432'/" "$NC_CONFIG_FILE"
        
        # Update dbuser
        sed -i "s/'dbuser' *=> *'[^']*'/'dbuser' => '$DB_USER'/" "$NC_CONFIG_FILE"
        
        # Update dbpassword
        sed -i "s/'dbpassword' *=> *'[^']*'/'dbpassword' => '$DB_PASS'/" "$NC_CONFIG_FILE"
        
        # Remove mysql.utf8mb4 setting which is MySQL-specific
        sed -i "/'mysql\.utf8mb4'/d" "$NC_CONFIG_FILE"
        
        # Set installed to false since we need to reinstall with PostgreSQL
        # This allows the installation wizard to set up the database tables
        sed -i "s/'installed' *=> *true/'installed' => false/" "$NC_CONFIG_FILE"
        
        log_info "config.php updated for PostgreSQL"
        
        # Clean up backup
        rm -f "${NC_CONFIG_FILE}.bak"
        
        log_warn "=========================================="
        log_warn "IMPORTANT: MySQL to PostgreSQL Migration"
        log_warn "=========================================="
        log_warn "Your Nextcloud configuration has been updated to use PostgreSQL."
        log_warn "However, your data has NOT been migrated automatically."
        log_warn ""
        log_warn "The database is now empty and Nextcloud will need to be re-initialized."
        log_warn "Your user data files are still available but database content"
        log_warn "(users, shares, app settings) will need to be restored from backup."
        log_warn ""
        log_warn "Backup location: Check /root/last_pre_update_backup for backup path"
        log_warn "=========================================="
    fi
fi

# Change cron execution method
log_info "Configuring Nextcloud background jobs..."
su -m www -c "php /usr/local/www/nextcloud/occ background:cron" || log_warn "Failed to configure background jobs - database may need initialization"

# Install default applications
log_info "Installing default applications..."
log_info "Installing contacts app..."
su -m www -c "php /usr/local/www/nextcloud/occ app:install contacts" || true
log_info "Installing calendar app..."
su -m www -c "php /usr/local/www/nextcloud/occ app:install calendar" || true
log_info "Installing notes app..."
su -m www -c "php /usr/local/www/nextcloud/occ app:install notes" || true
log_info "Installing deck app..."
su -m www -c "php /usr/local/www/nextcloud/occ app:install deck" || true

log_step_end "Migration 1: Initial setup"
