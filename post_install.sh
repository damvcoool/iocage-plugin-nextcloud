#!/bin/sh

set -xeu

# Load environment variable from /etc/iocage-env
. load_env

# Generate self-signed TLS certificates BEFORE sync_configuration
# Note: By default, HTTPS is enabled (ALLOW_INSECURE_ACCESS defaults to false in newer setup)
if [ "${ALLOW_INSECURE_ACCESS:-false}" = "false" ]
then
	generate_self_signed_tls_certificates
fi

# Generate some configuration from templates.
sync_configuration

# Enable the necessary services
sysrc -f /etc/rc.conf nginx_enable="YES"
sysrc -f /etc/rc.conf mysql_enable="YES"
sysrc -f /etc/rc.conf php_fpm_enable="YES"
sysrc -f /etc/rc.conf redis_enable="YES"
sysrc -f /etc/rc.conf fail2ban_enable="YES"

chmod 777 /tmp

# Create cache directories for performance optimizations
echo "Creating cache directories..."
mkdir -p /var/cache/opcache
chown www:www /var/cache/opcache
chmod 755 /var/cache/opcache

mkdir -p /var/tmp/nginx/fastcgi_cache
chown www:www /var/tmp/nginx/fastcgi_cache
chmod 755 /var/tmp/nginx/fastcgi_cache

# Start the services with better error handling
echo "Starting PHP-FPM..."
service php_fpm start 2>/dev/null || echo "Warning: PHP-FPM failed to start"

echo "Starting MySQL..."
service mysql-server start 2>/dev/null || echo "Warning: MySQL failed to start"

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

# Wait for MySQL to be ready
echo "Waiting for MySQL to be ready..."
max_attempts=30
attempt=0
until mysqladmin ping --silent 2>/dev/null || [ $attempt -eq $max_attempts ]
do
    attempt=$((attempt + 1))
    echo "MySQL is unavailable - attempt $attempt of $max_attempts"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo "ERROR: MySQL failed to start after $max_attempts attempts"
    exit 1
fi

# Configure mysql
echo "Configuring MySQL..."
mysqladmin -u root password "${PASS}"
mysql -u root -p"${PASS}" --connect-expired-password <<-EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${PASS}';
CREATE USER '${USER}'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON ${DB}.* TO '${USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

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
  --database=\"mysql\" \
  --database-name=\"nextcloud\" \
  --database-user=\"$USER\" \
  --database-pass=\"$PASS\" \
  --database-host=\"localhost\" \
  --admin-user=\"$NCUSER\" \
  --admin-pass=\"$NCPASS\" \
  --data-dir=\"$NCDATA_DIR\""

echo "Configuring Nextcloud background jobs..."
su -m www -c "php /usr/local/www/nextcloud/occ background:cron"

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
if [ "${ALLOW_INSECURE_ACCESS:-false}" = "false" ]; then
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
