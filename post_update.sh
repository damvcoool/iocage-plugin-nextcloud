#!/bin/sh

set -eu

# Source logging helper if available
if [ -f /usr/local/bin/log_helper ]; then
    . /usr/local/bin/log_helper
    log_script_start "Post-Update: Completing Nextcloud Update"
else
    # Fallback logging functions if log_helper not available
    log_info() { echo "[INFO] $*"; }
    log_step_start() { echo ">>> Starting: $*"; }
    log_step_end() { echo "<<< Finished: $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
    echo "========================================"
    echo "Post-Update: Completing Nextcloud Update"
    echo "========================================"
fi

# Helper function to restart a service if it's running
restart_service() {
    service_name="$1"
    alt_name="${2:-}"
    
    log_info "Checking service: $service_name"
    
    # Try primary service name first
    if service "$service_name" status >/dev/null 2>&1; then
        log_info "Service $service_name is running, restarting..."
        service "$service_name" restart 2>/dev/null || true
        log_info "Service $service_name restarted"
        return 0
    fi
    
    # Try alternative service name if provided
    if [ -n "$alt_name" ]; then
        log_info "Trying alternative service name: $alt_name"
        if service "$alt_name" status >/dev/null 2>&1; then
            log_info "Service $alt_name is running, restarting..."
            service "$alt_name" restart 2>/dev/null || true
            log_info "Service $alt_name restarted"
            return 0
        fi
    fi
    
    log_info "Service $service_name not running, skipping restart"
    return 0
}

# Load environment
log_step_start "Loading environment"
if [ -f /usr/local/bin/load_env ]; then
    . /usr/local/bin/load_env
    log_info "Environment loaded from /usr/local/bin/load_env"
else
    log_warn "load_env not found, skipping environment load"
fi
log_step_end "Loading environment"

# Check for pre_update backup location
log_step_start "Checking for pre_update backup"
PRE_UPDATE_BACKUP=""
if [ -f /root/last_pre_update_backup ]; then
    PRE_UPDATE_BACKUP=$(cat /root/last_pre_update_backup)
    log_info "Pre-update backup found at: $PRE_UPDATE_BACKUP"
else
    log_warn "No pre_update backup location found"
fi
log_step_end "Checking for pre_update backup"

# Restore SSL configuration from pre_update backup
log_step_start "Restoring SSL configuration"
CERT_PATH=/usr/local/etc/letsencrypt/live/truenas

if [ -n "$PRE_UPDATE_BACKUP" ] && [ -d "$PRE_UPDATE_BACKUP" ]; then
    # Read SSL state from pre_update backup
    SSL_STATE="none"
    if [ -f "$PRE_UPDATE_BACKUP/ssl_state.txt" ]; then
        SSL_STATE=$(cat "$PRE_UPDATE_BACKUP/ssl_state.txt")
        log_info "Previous SSL state: $SSL_STATE"
    fi

    # Restore jail_options.env if it existed (preserves ALLOW_INSECURE_ACCESS setting)
    if [ -f "$PRE_UPDATE_BACKUP/jail_options.env" ]; then
        cp "$PRE_UPDATE_BACKUP/jail_options.env" /root/jail_options.env
        log_info "Restored jail_options.env"
    fi

    # Restore SSL certificates based on previous state
    case "$SSL_STATE" in
        letsencrypt|self-signed|custom-ssl)
            # Restore backed up certificates
            if [ -d "$PRE_UPDATE_BACKUP/letsencrypt" ]; then
                log_info "Restoring SSL certificates from backup..."
                # Ensure the parent directory exists
                mkdir -p /usr/local/etc/letsencrypt
                # Restore the certificates using cp -a to preserve structure
                cp -a "$PRE_UPDATE_BACKUP/letsencrypt/." /usr/local/etc/letsencrypt/ 2>/dev/null || true
                log_info "SSL certificates restored from: $PRE_UPDATE_BACKUP/letsencrypt"
            else
                log_warn "No SSL certificates backup found, generating new self-signed certificates"
                log_step_start "Generating self-signed TLS certificates"
                generate_self_signed_tls_certificates 2>/dev/null || true
                log_step_end "Generating self-signed TLS certificates"
            fi
            ;;
        none)
            # Previous config was HTTP only - skip SSL setup
            log_info "Previous configuration was HTTP only, skipping SSL setup"
            # Ensure ALLOW_INSECURE_ACCESS is set to true if it wasn't previously configured
            if [ ! -f /root/jail_options.env ]; then
                echo "ALLOW_INSECURE_ACCESS=true" > /root/jail_options.env
                log_info "Created jail_options.env with ALLOW_INSECURE_ACCESS=true"
            elif ! grep -q "ALLOW_INSECURE_ACCESS" /root/jail_options.env; then
                echo "ALLOW_INSECURE_ACCESS=true" >> /root/jail_options.env
                log_info "Added ALLOW_INSECURE_ACCESS=true to jail_options.env"
            fi
            ;;
        *)
            # Unknown state - generate self-signed as fallback
            log_info "Unknown SSL state, generating self-signed certificates as fallback"
            log_step_start "Generating self-signed TLS certificates"
            generate_self_signed_tls_certificates 2>/dev/null || true
            log_step_end "Generating self-signed TLS certificates"
            ;;
    esac
else
    # No pre_update backup - check if certs already exist
    if [ -f "${CERT_PATH}/fullchain.pem" ]; then
        log_info "SSL certificates already exist, keeping them"
    else
        log_info "No SSL certificates found, generating self-signed certificates"
        log_step_start "Generating self-signed TLS certificates"
        generate_self_signed_tls_certificates 2>/dev/null || true
        log_step_end "Generating self-signed TLS certificates"
    fi
fi
log_step_end "Restoring SSL configuration"

# Run migrations in /root/migrations.
log_step_start "Running database migrations"
if [ ! -e /root/migrations/current_migration.txt ]
then
	echo "0" > /root/migrations/current_migration.txt
	log_info "Initialized migration state to 0"
fi

current_migration=$(cat /root/migrations/current_migration.txt)
log_info "Current migration version: $current_migration"
while [ -f "/root/migrations/$((current_migration+1)).sh" ]
do
	log_info "* [migrate] Migrating from $current_migration to $((current_migration+1))."

	{
		"/root/migrations/$((current_migration+1)).sh" &&
		current_migration=$((current_migration+1)) &&
		log_info "* [migrate] Migration $current_migration done." &&
		echo "$current_migration" > /root/migrations/current_migration.txt
	} || {
		log_error "Fail to run migrations."
		# Do not exit so the post_update script can continue.
		break
	}
done
log_info "Final migration version: $current_migration"
log_step_end "Running database migrations"

# Generate some configuration from templates.
log_step_start "Syncing configuration files"
sync_configuration
log_info "Configuration files synced"
log_step_end "Syncing configuration files"

# Removing rwx permission on the nextcloud folder to others users
log_step_start "Setting file permissions"
log_info "Removing rwx permission on nextcloud folder for other users..."
chmod -R o-rwx /usr/local/www/nextcloud
# Give full ownership of the nextcloud directory to www
log_info "Setting ownership of nextcloud directory to www..."
chown -R www:www /usr/local/www/nextcloud
log_step_end "Setting file permissions"

# Restart services to apply any configuration changes
log_step_start "Restarting services"

# Restart PHP-FPM (try php_fpm first as it's the FreeBSD service name)
restart_service "php_fpm"

# Restart Redis
restart_service "redis"

# Restart the appropriate database (only one should be running)
# Check which database is enabled in rc.conf to avoid checking non-existent services
if grep -q 'postgresql_enable="YES"' /etc/rc.conf 2>/dev/null; then
    restart_service "postgresql"
elif grep -q 'mysql_enable="YES"' /etc/rc.conf 2>/dev/null; then
    restart_service "mysql-server"
else
    log_info "No database service enabled in rc.conf, skipping database restart"
fi

# Restart nginx
restart_service "nginx"
log_step_end "Restarting services"

# Run Nextcloud upgrade if needed
log_step_start "Running Nextcloud upgrade"
log_info "Executing: occ upgrade"
su -m www -c "php /usr/local/www/nextcloud/occ upgrade" 2>/dev/null || true
log_step_end "Running Nextcloud upgrade"

# Verify and repair Nextcloud data
log_step_start "Verifying and repairing Nextcloud data"
log_info "Executing: occ maintenance:repair"
su -m www -c "php /usr/local/www/nextcloud/occ maintenance:repair" 2>/dev/null || true
log_step_end "Verifying and repairing Nextcloud data"

# Add missing database indices and columns
log_step_start "Adding missing database indices and columns"
log_info "Executing: occ db:add-missing-indices"
su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-indices" 2>/dev/null || true
log_info "Executing: occ db:add-missing-columns"
su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-columns" 2>/dev/null || true
log_info "Executing: occ db:add-missing-primary-keys"
su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-primary-keys" 2>/dev/null || true
log_info "Executing: occ db:convert-filecache-bigint"
su -m www -c "php /usr/local/www/nextcloud/occ db:convert-filecache-bigint --no-interaction" 2>/dev/null || true
log_step_end "Adding missing database indices and columns"

# Update all apps if needed
log_step_start "Updating Nextcloud apps"
log_info "Executing: occ app:update --all"
su -m www -c "php /usr/local/www/nextcloud/occ app:update --all" 2>/dev/null || true
log_step_end "Updating Nextcloud apps"

# Disable maintenance mode
log_step_start "Disabling maintenance mode"
su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --off" 2>/dev/null || true
log_info "Maintenance mode disabled"
log_step_end "Disabling maintenance mode"

# Log completion
if [ -f /usr/local/bin/log_helper ]; then
    log_script_end "Post-update" "completed successfully"
else
    echo ""
    echo "========================================"
    echo "Post-update completed successfully"
    echo "========================================"
fi
if [ -n "$PRE_UPDATE_BACKUP" ] && [ -d "$PRE_UPDATE_BACKUP" ]; then
    log_info "Your backup is still available at: $PRE_UPDATE_BACKUP"
fi
