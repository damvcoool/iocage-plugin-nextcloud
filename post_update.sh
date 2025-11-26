#!/bin/sh

set -eu

echo "========================================"
echo "Post-Update: Completing Nextcloud Update"
echo "========================================"

# Helper function to restart a service if it's running
restart_service() {
    service_name="$1"
    alt_name="${2:-}"
    
    if service "$service_name" status >/dev/null 2>&1; then
        service "$service_name" restart 2>/dev/null || true
    elif [ -n "$alt_name" ] && service "$alt_name" status >/dev/null 2>&1; then
        service "$alt_name" restart 2>/dev/null || true
    fi
}

# Load environment
if [ -f /usr/local/bin/load_env ]; then
    . /usr/local/bin/load_env
fi

# Check for pre_update backup location
PRE_UPDATE_BACKUP=""
if [ -f /root/last_pre_update_backup ]; then
    PRE_UPDATE_BACKUP=$(cat /root/last_pre_update_backup)
    echo "Pre-update backup found at: $PRE_UPDATE_BACKUP"
fi

# Run migrations in /root/migrations.
echo ""
echo "Running database migrations..."
if [ ! -e /root/migrations/current_migration.txt ]
then
	echo "0" > /root/migrations/current_migration.txt
fi

current_migration=$(cat /root/migrations/current_migration.txt)
while [ -f "/root/migrations/$((current_migration+1)).sh" ]
do
	echo "* [migrate] Migrating from $current_migration to $((current_migration+1))."

	{
		"/root/migrations/$((current_migration+1)).sh" &&
		current_migration=$((current_migration+1)) &&
		echo "* [migrate] Migration $current_migration done." &&
		echo "$current_migration" > /root/migrations/current_migration.txt
	} || {
		echo "ERROR - Fail to run migrations."
		# Do not exit so the post_update script can continue.
		break
	}
done

# Generate some configuration from templates.
echo ""
echo "Syncing configuration files..."
sync_configuration

# Removing rwx permission on the nextcloud folder to others users
chmod -R o-rwx /usr/local/www/nextcloud
# Give full ownership of the nextcloud directory to www
chown -R www:www /usr/local/www/nextcloud

# Restart services to apply any configuration changes
echo ""
echo "Restarting services..."

# Restart PHP-FPM (try both service name variants)
restart_service "php-fpm" "php_fpm"

# Restart Redis
restart_service "redis"

# Restart the appropriate database
restart_service "postgresql"
restart_service "mysql-server"

# Restart nginx
restart_service "nginx"

# Run Nextcloud upgrade if needed
echo ""
echo "Running Nextcloud upgrade..."
su -m www -c "php /usr/local/www/nextcloud/occ upgrade" 2>/dev/null || true

# Add missing database indices
echo "Adding missing database indices..."
su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-indices" 2>/dev/null || true
su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-columns" 2>/dev/null || true
su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-primary-keys" 2>/dev/null || true

# Disable maintenance mode
echo ""
echo "Disabling maintenance mode..."
su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --off" 2>/dev/null || true

echo ""
echo "========================================"
echo "Post-update completed successfully"
echo "========================================"
if [ -n "$PRE_UPDATE_BACKUP" ] && [ -d "$PRE_UPDATE_BACKUP" ]; then
    echo "Your backup is still available at: $PRE_UPDATE_BACKUP"
fi
echo "========================================"
