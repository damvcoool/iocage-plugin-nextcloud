#!/bin/sh

set -eu

# Generate certificates so nginx is happy
generate_self_signed_tls_certificates

# Enable and start new services
sysrc -f /etc/rc.conf redis_enable="YES"
sysrc -f /etc/rc.conf fail2ban_enable="YES"

# Check if we have PostgreSQL or MySQL
if service postgresql status >/dev/null 2>&1; then
    # Already on PostgreSQL
    echo "PostgreSQL already running"
    service postgresql restart 2>/dev/null
elif service mysql-server status >/dev/null 2>&1; then
    # Still on MySQL
    sysrc -f /etc/rc.conf mysql_enable="YES"
    service mysql-server start 2>/dev/null
    
    # Wait for mysql to be up
    until mysql --user dbadmin --password="$(cat /root/dbpassword)" --execute "SHOW DATABASES" > /dev/null 2>/dev/null
    do
        echo "MariaDB is unavailable - sleeping"
        sleep 1
    done
fi

service redis start 2>/dev/null
service fail2ban start 2>/dev/null

# Change cron execution method
su -m www -c "php /usr/local/www/nextcloud/occ background:cron"

# Install default applications
su -m www -c "php /usr/local/www/nextcloud/occ app:install contacts" || true
su -m www -c "php /usr/local/www/nextcloud/occ app:install calendar" || true
su -m www -c "php /usr/local/www/nextcloud/occ app:install notes" || true
su -m www -c "php /usr/local/www/nextcloud/occ app:install deck" || true
