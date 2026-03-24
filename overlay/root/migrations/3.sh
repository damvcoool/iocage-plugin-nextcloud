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

log_step_start "Migration 3: PostgreSQL major-version upgrade to 18"

TARGET_PG_VERSION=18
TARGET_PG_DATA="/var/db/postgres/data${TARGET_PG_VERSION}"

# ------------------------------------------------------------------
# Determine the old PostgreSQL major version
# ------------------------------------------------------------------

# Helper: return 0 if the argument is a positive integer, 1 otherwise.
is_numeric() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Prefer the version recorded by pre_update.sh over guessing from the
# data-directory name, because the pre_update backup is the most reliable
# source and is available even after the old binaries are removed.
PRE_UPDATE_BACKUP=""
if [ -f /root/last_pre_update_backup ]; then
    PRE_UPDATE_BACKUP=$(cat /root/last_pre_update_backup)
fi

OLD_PG_VERSION=""
if [ -n "$PRE_UPDATE_BACKUP" ] && [ -f "$PRE_UPDATE_BACKUP/pg_version.txt" ]; then
    _raw=$(cat "$PRE_UPDATE_BACKUP/pg_version.txt" | tr -d '[:space:]')
    if is_numeric "$_raw"; then
        OLD_PG_VERSION="$_raw"
        log_info "Previous PostgreSQL major version (from backup): $OLD_PG_VERSION"
    else
        log_warn "pg_version.txt contained non-numeric value '$_raw' — ignoring"
    fi
fi

# Fall back to scanning for old data directories if the backup does not
# contain the version file (e.g. upgrading from a very old plugin version).
if [ -z "$OLD_PG_VERSION" ]; then
    for pg_data_dir in /var/db/postgres/data[0-9]*; do
        if [ -d "$pg_data_dir" ]; then
            ver=$(basename "$pg_data_dir" | sed 's/^data//')
            if is_numeric "$ver" && [ "$ver" -lt "$TARGET_PG_VERSION" ]; then
                OLD_PG_VERSION="$ver"
                log_info "Detected old PostgreSQL data directory: $pg_data_dir (version $ver)"
            fi
        fi
    done
fi

# ------------------------------------------------------------------
# Skip if no version upgrade is needed
# ------------------------------------------------------------------

if [ -z "$OLD_PG_VERSION" ]; then
    log_info "No old PostgreSQL version detected — skipping major-version upgrade"
    log_step_end "Migration 3: PostgreSQL major-version upgrade to 18" "skipped - no old version found"
    exit 0
fi

if [ "$OLD_PG_VERSION" -ge "$TARGET_PG_VERSION" ]; then
    log_info "PostgreSQL is already at version $OLD_PG_VERSION — no upgrade needed"
    log_step_end "Migration 3: PostgreSQL major-version upgrade to 18" "skipped - already at target version"
    exit 0
fi

log_info "PostgreSQL major-version upgrade required: $OLD_PG_VERSION -> $TARGET_PG_VERSION"

# Read database credentials early so they are available throughout the script
DB_USER=$(cat /root/dbuser 2>/dev/null || echo "dbadmin")
DB_PASS=$(cat /root/dbpassword 2>/dev/null || echo "")
DB_NAME="nextcloud"

# ------------------------------------------------------------------
# Skip if PG18 is already initialised and healthy
# ------------------------------------------------------------------

if [ -d "$TARGET_PG_DATA" ] && [ -f "$TARGET_PG_DATA/PG_VERSION" ]; then
    log_info "PG$TARGET_PG_VERSION data directory already exists at $TARGET_PG_DATA"
    sysrc -f /etc/rc.conf postgresql_enable="YES" 2>/dev/null || true
    if service postgresql start >/dev/null 2>&1; then
        # Verify Nextcloud data is accessible
        if su -m postgres -c "psql -d $DB_NAME -c 'SELECT 1 FROM oc_users LIMIT 1'" >/dev/null 2>&1; then
            log_info "PostgreSQL $TARGET_PG_VERSION is running with Nextcloud data — nothing to do"
            log_step_end "Migration 3: PostgreSQL major-version upgrade to 18" "skipped - already healthy"
            exit 0
        fi
        log_warn "PostgreSQL $TARGET_PG_VERSION started but database appears empty — will restore from backup"
        service postgresql stop >/dev/null 2>&1 || true
    else
        log_warn "PostgreSQL $TARGET_PG_VERSION data directory exists but service failed to start — will reinitialise"
    fi
    # Remove the broken / empty data directory so oneinitdb can recreate it
    rm -rf "$TARGET_PG_DATA"
fi

# ------------------------------------------------------------------
# Locate the pre_update SQL backup files
# ------------------------------------------------------------------

PG_DUMP_FILE=""
PG_GLOBALS_FILE=""
if [ -n "$PRE_UPDATE_BACKUP" ]; then
    if [ -f "$PRE_UPDATE_BACKUP/nextcloud_pg.sql" ] && [ -s "$PRE_UPDATE_BACKUP/nextcloud_pg.sql" ]; then
        PG_DUMP_FILE="$PRE_UPDATE_BACKUP/nextcloud_pg.sql"
        log_info "Found PostgreSQL database dump: $PG_DUMP_FILE"
    fi
    if [ -f "$PRE_UPDATE_BACKUP/nextcloud_pg_globals.sql" ] && [ -s "$PRE_UPDATE_BACKUP/nextcloud_pg_globals.sql" ]; then
        PG_GLOBALS_FILE="$PRE_UPDATE_BACKUP/nextcloud_pg_globals.sql"
        log_info "Found PostgreSQL globals dump: $PG_GLOBALS_FILE"
    fi
fi

if [ -z "$PG_DUMP_FILE" ]; then
    log_warn "No PostgreSQL backup found — will initialise a fresh cluster (Nextcloud will need re-setup)"
fi

# ------------------------------------------------------------------
# Initialise a fresh PG18 data directory
# ------------------------------------------------------------------

log_info "Initialising PostgreSQL $TARGET_PG_VERSION data directory at $TARGET_PG_DATA..."
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql 2>/dev/null || true
sysrc -f /etc/rc.conf postgresql_enable="YES" 2>/dev/null || true
sysrc -f /etc/rc.conf postgresql_initdb_flags="--auth-local=trust --auth-host=trust" 2>/dev/null || true

if /usr/local/etc/rc.d/postgresql oneinitdb 2>/dev/null; then
    log_info "PostgreSQL $TARGET_PG_VERSION initialised successfully"
else
    log_error "Failed to initialise PostgreSQL $TARGET_PG_VERSION"
    log_step_end "Migration 3: PostgreSQL major-version upgrade to 18" "failed"
    exit 1
fi

# Copy optimised postgresql.conf if present
if [ -f /usr/local/etc/postgresql/postgresql.conf ]; then
    cp /usr/local/etc/postgresql/postgresql.conf "$TARGET_PG_DATA/postgresql.conf" 2>/dev/null || true
    chown postgres:postgres "$TARGET_PG_DATA/postgresql.conf" 2>/dev/null || true
    log_info "Copied optimised postgresql.conf"
fi

# ------------------------------------------------------------------
# Start PG18 and wait until ready
# ------------------------------------------------------------------

log_info "Starting PostgreSQL $TARGET_PG_VERSION..."
service postgresql start 2>/dev/null || true

max_wait=60
waited=0
while ! su -m postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1 && [ "$waited" -lt "$max_wait" ]; do
    sleep 2
    waited=$((waited + 2))
    if [ $((waited % 10)) -eq 0 ]; then
        log_info "Waiting for PostgreSQL $TARGET_PG_VERSION... ($waited/$max_wait)"
    fi
done

if ! su -m postgres -c "psql -c 'SELECT 1'" >/dev/null 2>&1; then
    log_error "PostgreSQL $TARGET_PG_VERSION failed to start after $max_wait seconds"
    log_step_end "Migration 3: PostgreSQL major-version upgrade to 18" "failed"
    exit 1
fi
log_info "PostgreSQL $TARGET_PG_VERSION is ready"

# ------------------------------------------------------------------
# Restore from backup (or create an empty database for fresh setups)
# ------------------------------------------------------------------

# Escape single quotes for SQL use
DB_PASS_SQL=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")

if [ -n "$PG_DUMP_FILE" ]; then
    log_info "Restoring database from pre-update backup..."

    # Restore global objects (roles) first so the database owner role exists
    if [ -n "$PG_GLOBALS_FILE" ]; then
        log_info "Restoring PostgreSQL roles from globals dump..."
        su -m postgres -c "psql -f '$PG_GLOBALS_FILE'" >/dev/null 2>&1 || true
    fi

    # Ensure the user and database exist (globals restore may have already done this)
    su -m postgres -c "psql -c \"CREATE USER $DB_USER WITH NOSUPERUSER NOCREATEDB NOCREATEROLE;\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"ALTER USER $DB_USER WITH PASSWORD '$DB_PASS_SQL';\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\"" 2>/dev/null || true
    su -m postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\"" 2>/dev/null || true

    log_info "Restoring nextcloud database (this may take a while)..."
    PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -h localhost "$DB_NAME" < "$PG_DUMP_FILE" >/dev/null 2>&1
    RESTORE_EXIT=$?

    if [ "$RESTORE_EXIT" -eq 0 ]; then
        log_info "Database restored successfully"
        if su -m postgres -c "psql -d $DB_NAME -c 'SELECT 1 FROM oc_users LIMIT 1'" >/dev/null 2>&1; then
            log_info "Database restore verified — Nextcloud data is accessible"
        else
            log_warn "Restore completed but oc_users query failed (database may be empty)"
        fi
    else
        log_warn "Database restore finished with errors (exit code: $RESTORE_EXIT) — some data may be missing"
    fi
else
    # No backup: create an empty database so post_install/post_update can proceed
    log_info "No backup available — creating empty database for fresh installation"

    if [ -z "$DB_PASS" ]; then
        export LC_ALL=C
        openssl rand --hex 8 > /root/dbpassword
        DB_PASS=$(cat /root/dbpassword)
        DB_PASS_SQL=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")
        log_info "Generated new database password"
    fi

    su -m postgres -c "psql -c \"CREATE USER $DB_USER WITH NOSUPERUSER NOCREATEDB NOCREATEROLE;\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"ALTER USER $DB_USER WITH PASSWORD '$DB_PASS_SQL';\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;\"" 2>/dev/null || true
    su -m postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;\"" 2>/dev/null || true
    su -m postgres -c "psql -d $DB_NAME -c \"GRANT ALL ON SCHEMA public TO $DB_USER;\"" 2>/dev/null || true
    log_info "Empty database created"
fi

log_info "PostgreSQL $OLD_PG_VERSION -> $TARGET_PG_VERSION upgrade complete"
log_step_end "Migration 3: PostgreSQL major-version upgrade to 18" "completed"
exit 0
