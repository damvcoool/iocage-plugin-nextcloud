#!/bin/sh

set -eu

echo "========================================"
echo "MySQL to PostgreSQL 18 Migration Tool"
echo "========================================"
echo ""
echo "This script will migrate your Nextcloud data from MySQL to PostgreSQL 18."
echo ""
echo "WARNING: This process will:"
echo "  - Put Nextcloud in maintenance mode"
echo "  - Stop all services temporarily"
echo "  - Backup your MySQL database"
echo "  - Initialize PostgreSQL"
echo "  - Migrate your data"
echo ""
echo "Press CTRL+C to cancel, or press ENTER to continue..."
read dummy

# Load environment
if [ -f /usr/local/bin/load_env ]; then
    . /usr/local/bin/load_env
fi

# Check if we're already on PostgreSQL
if service postgresql status >/dev/null 2>&1; then
    echo "ERROR: PostgreSQL is already running. Migration not needed."
    exit 1
fi

# Check if MySQL is running
if ! service mysql-server status >/dev/null 2>&1; then
    echo "ERROR: MySQL is not running. Cannot migrate."
    exit 1
fi

# Backup directory
BACKUP_DIR="/root/mysql_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo ""
echo "Creating MySQL backup in $BACKUP_DIR..."

# Get database credentials
DB_USER=$(cat /root/dbuser 2>/dev/null || echo "dbadmin")
DB_PASS=$(cat /root/dbpassword 2>/dev/null || echo "")
DB_NAME="nextcloud"

if [ -z "$DB_PASS" ]; then
    echo "ERROR: Cannot read database password from /root/dbpassword"
    exit 1
fi

# Backup Nextcloud config
echo "Backing up Nextcloud configuration..."
cp -r /usr/local/www/nextcloud/config "$BACKUP_DIR/nextcloud-config-backup"

# Put Nextcloud in maintenance mode
echo "Enabling Nextcloud maintenance mode..."
su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --on"

# Backup MySQL database
echo "Backing up MySQL database (this may take a while)..."
mysqldump -u "$DB_USER" -p"$DB_PASS" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --hex-blob \
    --add-drop-table \
    "$DB_NAME" > "$BACKUP_DIR/nextcloud.sql"

if [ ! -s "$BACKUP_DIR/nextcloud.sql" ]; then
    echo "ERROR: MySQL backup failed or is empty"
    su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --off"
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_DIR/nextcloud.sql" | cut -f1)
echo "MySQL backup completed: $BACKUP_DIR/nextcloud.sql ($BACKUP_SIZE)"

# Export data directory info
echo "Backing up data directory information..."
NCDATA_DIR=$(su -m www -c "php /usr/local/www/nextcloud/occ config:system:get datadirectory")
echo "$NCDATA_DIR" > "$BACKUP_DIR/data_directory.txt"

# Stop services
echo ""
echo "Stopping services..."
service nginx stop 2>/dev/null || true
service php-fpm stop 2>/dev/null || true
service mysql-server stop 2>/dev/null || true

# Initialize PostgreSQL
echo ""
echo "Initializing PostgreSQL..."
if [ ! -d /var/db/postgres/data18 ]; then
    # Set authentication options to suppress initdb warning about "trust" authentication
    sysrc -f /etc/rc.conf postgresql_initdb_flags="--auth-local=trust --auth-host=trust"
    /usr/local/etc/rc.d/postgresql oneinitdb
else
    echo "PostgreSQL already initialized"
fi

# Enable and start PostgreSQL
sysrc -f /etc/rc.conf postgresql_enable="YES"
sysrc -f /etc/rc.conf mysql_enable="NO"

echo "Starting PostgreSQL..."
service postgresql start

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
max_attempts=30
attempt=0
until su -m postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1 || [ $attempt -eq $max_attempts ]
do
    attempt=$((attempt + 1))
    echo "PostgreSQL is unavailable - attempt $attempt of $max_attempts"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo "ERROR: PostgreSQL failed to start"
    echo "Attempting to restore services..."
    sysrc -f /etc/rc.conf mysql_enable="YES"
    service mysql-server start
    service php-fpm start
    service nginx start
    su -m www -c "php /usr/local/www/nextcloud/occ maintenance:mode --off"
    exit 1
fi

# Create PostgreSQL database and user
echo ""
echo "Creating PostgreSQL database and user..."
su -m postgres -c "psql -c \"CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';\"" 2>/dev/null || echo "User may already exist"
su -m postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\""
su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\""
su -m postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\""

# Start PHP-FPM for occ commands
echo ""
echo "Starting PHP-FPM..."
service php-fpm start

# Update Nextcloud config to use PostgreSQL
echo "Updating Nextcloud configuration..."
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set dbtype --value=pgsql"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set dbname --value=$DB_NAME"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set dbhost --value=localhost"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set dbuser --value=$DB_USER"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set dbpassword --value=$DB_PASS"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set dbport --value=5432"

# Important: Use pgloader or manual conversion
echo ""
echo "========================================"
echo "MANUAL STEP REQUIRED"
echo "========================================"
echo ""
echo "The MySQL dump needs to be converted to PostgreSQL format."
echo "This requires the 'pgloader' tool or manual conversion."
echo ""
echo "Option 1: Install pgloader (recommended):"
echo "  pkg install pgloader"
echo "  pgloader mysql://dbadmin:PASSWORD@localhost/nextcloud pgsql://dbadmin:PASSWORD@localhost/nextcloud"
echo ""
echo "Option 2: Use the backup to manually restore (if you have another Nextcloud instance)"
echo ""
echo "Your MySQL backup is at: $BACKUP_DIR/nextcloud.sql"
echo ""
echo "Once data is migrated, run these commands:"
echo "  su -m www -c 'php /usr/local/www/nextcloud/occ maintenance:mode --off'"
echo "  su -m www -c 'php /usr/local/www/nextcloud/occ db:add-missing-indices'"
echo "  su -m www -c 'php /usr/local/www/nextcloud/occ db:add-missing-columns'"
echo "  service nginx start"
echo ""
echo "========================================"
echo ""
echo "If you need to rollback:"
echo "  1. Stop all services"
echo "  2. sysrc -f /etc/rc.conf mysql_enable=YES postgresql_enable=NO"
echo "  3. Restore config: cp -r $BACKUP_DIR/nextcloud-config-backup/* /usr/local/www/nextcloud/config/"
echo "  4. Start MySQL and restore: mysql -u $DB_USER -p < $BACKUP_DIR/nextcloud.sql"
echo "  5. Start services"
echo ""
