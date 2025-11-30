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
        until su -m postgres -c "psql -c 'SELECT 1' >/dev/null 2>&1" || [ $attempt -eq $max_attempts ]
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

# Change cron execution method
log_info "Configuring Nextcloud background jobs..."
su -m www -c "php /usr/local/www/nextcloud/occ background:cron"

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
