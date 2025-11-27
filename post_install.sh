#!/bin/sh

set -eu

# Load environment variable from /etc/iocage-env
. load_env

# Check for pre_update backup to determine SSL configuration
# This allows post_install to respect the previous SSL state during updates
PRE_UPDATE_BACKUP=""
SSL_STATE=""
if [ -f /root/last_pre_update_backup ]; then
    PRE_UPDATE_BACKUP=$(cat /root/last_pre_update_backup)
    if [ -n "$PRE_UPDATE_BACKUP" ] && [ -f "$PRE_UPDATE_BACKUP/ssl_state.txt" ]; then
        SSL_STATE=$(cat "$PRE_UPDATE_BACKUP/ssl_state.txt")
        echo "Found pre-update SSL state: $SSL_STATE"
        
        # Restore jail_options.env if it existed (preserves ALLOW_INSECURE_ACCESS setting)
        if [ -f "$PRE_UPDATE_BACKUP/jail_options.env" ]; then
            cp "$PRE_UPDATE_BACKUP/jail_options.env" /root/jail_options.env
            # Re-source load_env to pick up restored settings
            . load_env
            echo "Restored jail_options.env from pre-update backup"
        fi
    fi
fi

# Determine whether to apply SSL based on pre_update state or ALLOW_INSECURE_ACCESS
APPLY_SSL="true"
if [ -n "$SSL_STATE" ]; then
    # Use pre_update SSL state to determine SSL configuration
    case "$SSL_STATE" in
        letsencrypt|self-signed|custom-ssl)
            APPLY_SSL="true"
            echo "SSL will be configured (previous state: $SSL_STATE)"
            ;;
        none)
            APPLY_SSL="false"
            # Set ALLOW_INSECURE_ACCESS=true for HTTP-only configuration
            if [ ! -f /root/jail_options.env ]; then
                echo "ALLOW_INSECURE_ACCESS=true" > /root/jail_options.env
            elif ! grep -q "ALLOW_INSECURE_ACCESS" /root/jail_options.env; then
                echo "ALLOW_INSECURE_ACCESS=true" >> /root/jail_options.env
            fi
            # Re-source to pick up the change
            . load_env
            echo "SSL will NOT be configured (previous state: HTTP only)"
            ;;
    esac
elif [ "${ALLOW_INSECURE_ACCESS:-false}" = "true" ]; then
    APPLY_SSL="false"
    echo "SSL will NOT be configured (ALLOW_INSECURE_ACCESS=true)"
fi

# Generate self-signed TLS certificates BEFORE sync_configuration
# Only if SSL should be applied and certificates don't already exist
CERT_PATH=/usr/local/etc/letsencrypt/live/truenas
if [ "$APPLY_SSL" = "true" ]; then
    # Check if we should restore certificates from pre_update backup
    if [ -n "$PRE_UPDATE_BACKUP" ] && [ -d "$PRE_UPDATE_BACKUP/letsencrypt" ]; then
        echo "Restoring SSL certificates from pre-update backup..."
        mkdir -p /usr/local/etc/letsencrypt
        cp -a "$PRE_UPDATE_BACKUP/letsencrypt/." /usr/local/etc/letsencrypt/ 2>/dev/null || true
        echo "SSL certificates restored from: $PRE_UPDATE_BACKUP/letsencrypt"
    elif [ ! -f "${CERT_PATH}/fullchain.pem" ]; then
        echo "Generating self-signed TLS certificates..."
        generate_self_signed_tls_certificates
    else
        echo "SSL certificates already exist, keeping them"
    fi
fi

# Generate some configuration from templates.
sync_configuration

# Enable the necessary services
sysrc -f /etc/rc.conf nginx_enable="YES"
sysrc -f /etc/rc.conf postgresql_enable="YES"
sysrc -f /etc/rc.conf php_fpm_enable="YES"
sysrc -f /etc/rc.conf redis_enable="YES"
sysrc -f /etc/rc.conf fail2ban_enable="YES"

chmod 777 /tmp

# Initialize PostgreSQL
echo "Initializing PostgreSQL..."
/usr/local/etc/rc.d/postgresql oneinitdb

# Start the services with better error handling
echo "Starting PHP-FPM..."
service php_fpm start 2>/dev/null || echo "Warning: PHP-FPM failed to start"

echo "Starting PostgreSQL..."
service postgresql start 2>/dev/null || echo "Warning: PostgreSQL failed to start"

echo "Starting Redis..."
service redis start 2>/dev/null || echo "Warning: Redis failed to start"

# https://docs.nextcloud.com/server/stable/admin_manual/installation/installation_wizard.html do not use the same name for user and db
USER="dbadmin"
DB="nextcloud"
NCUSER="ncadmin"

# Save the config values
echo "$DB" > /root/dbname
echo "$USER" > /root/dbuser
echo "$NCUSER" > /root/ncuser
export LC_ALL=C
openssl rand --hex 8 > /root/dbpassword
openssl rand --hex 8 > /root/ncpassword
PASS=$(cat /root/dbpassword)
NCPASS=$(cat /root/ncpassword)

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
max_attempts=30
attempt=0
until su -m postgres -c "psql -c 'SELECT 1' >/dev/null 2>&1" || [ $attempt -eq $max_attempts ]
do
    attempt=$((attempt + 1))
    echo "PostgreSQL is unavailable - attempt $attempt of $max_attempts"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo "ERROR: PostgreSQL failed to start after $max_attempts attempts"
    exit 1
fi

# Configure PostgreSQL
echo "Configuring PostgreSQL..."
su -m postgres -c "psql -c \"CREATE USER ${USER} WITH PASSWORD '${PASS}';\""
su -m postgres -c "psql -c \"CREATE DATABASE ${DB} OWNER ${USER} ENCODING 'UTF8' TEMPLATE template0;\""
su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${DB} TO ${USER};\""

# Make the default log directory
mkdir -p /var/log/zm
chown www:www /var/log/zm

# Make the default nextcloud data directory
NCDATA_DIR=/usr/local/nextcloud/data
mkdir -p $NCDATA_DIR
chown www:www $NCDATA_DIR

# Use occ to complete Nextcloud installation
echo "Installing Nextcloud..."
su -m www -c "php /usr/local/www/nextcloud/occ maintenance:install \
  --database=\"pgsql\" \
  --database-name=\"nextcloud\" \
  --database-user=\"$USER\" \
  --database-pass=\"$PASS\" \
  --database-host=\"localhost\" \
  --admin-user=\"$NCUSER\" \
  --admin-pass=\"$NCPASS\" \
  --data-dir=\"$NCDATA_DIR\""

echo "Configuring Nextcloud background jobs..."
su -m www -c "php /usr/local/www/nextcloud/occ background:cron"

echo "Configuring Redis cache..."
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set redis host --value=localhost"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set redis port --value=6379 --type=integer"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set memcache.local --value='\\OC\\Memcache\\APCu'"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set memcache.distributed --value='\\OC\\Memcache\\Redis'"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set memcache.locking --value='\\OC\\Memcache\\Redis'"

echo "Adding missing database indices..."
su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-indices"

echo "Installing default applications..."
su -m www -c "php /usr/local/www/nextcloud/occ app:install contacts" || echo "Warning: Failed to install contacts app"
su -m www -c "php /usr/local/www/nextcloud/occ app:install calendar" || echo "Warning: Failed to install calendar app"
su -m www -c "php /usr/local/www/nextcloud/occ app:install notes" || echo "Warning: Failed to install notes app"
su -m www -c "php /usr/local/www/nextcloud/occ app:install deck" || echo "Warning: Failed to install deck app"

echo "Setting trusted domains..."
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set trusted_domains 1 --value='${IOCAGE_JAIL_IP}'"

# create sessions tmp dir outside nextcloud installation
mkdir -p /usr/local/www/nextcloud-sessions-tmp >/dev/null 2>/dev/null
chmod o-rwx /usr/local/www/nextcloud-sessions-tmp
chown -R www:www /usr/local/www/nextcloud-sessions-tmp
chown -R www:www /usr/local/www/nextcloud/apps-pkg

# Starting fail2ban
echo "Starting Fail2ban..."
service fail2ban start 2>/dev/null || echo "Warning: Fail2ban failed to start"

# Starting nginx (after all configuration is complete)
echo "Starting Nginx..."
service nginx start 2>/dev/null || echo "Warning: Nginx failed to start"

# Removing rwx permission on the nextcloud folder to others users
chmod -R o-rwx /usr/local/www/nextcloud

# Give full ownership of the nextcloud directory to www
chown -R www:www /usr/local/www/nextcloud

echo "Database Name: $DB" > /root/PLUGIN_INFO
echo "Database User: $USER" >> /root/PLUGIN_INFO
echo "Database Password: $PASS" >> /root/PLUGIN_INFO

echo "Nextcloud Admin User: $NCUSER" >> /root/PLUGIN_INFO
echo "Nextcloud Admin Password: $NCPASS" >> /root/PLUGIN_INFO

echo "Nextcloud Data Directory: $NCDATA_DIR" >> /root/PLUGIN_INFO

# Display completion message
echo ""
echo "=========================================="
echo "Nextcloud installation completed!"
echo "=========================================="
echo "You can access Nextcloud at:"
if [ "$APPLY_SSL" = "true" ]; then
    echo "  https://${IOCAGE_JAIL_IP}"
    echo ""
    echo "NOTE: This installation uses self-signed certificates."
    echo "You can install the root certificate from:"
    echo "  /usr/local/etc/letsencrypt/live/truenas/root.cer"
else
    echo "  http://${IOCAGE_JAIL_IP}"
fi
echo ""
echo "Admin credentials stored in: /root/PLUGIN_INFO"
echo "=========================================="
