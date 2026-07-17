#!/bin/bash
# OpenHost entrypoint for FitTrackee.
#
# Brings up a bundled PostgreSQL/PostGIS cluster (data under the persistent
# app-data dir), runs FitTrackee migrations, provisions the owner account
# (pre-activated, throwaway password never stored), starts gunicorn on :5000,
# and starts the auth-proxy sidecar on the OpenHost-routed port (:8080).
set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data}"
PGDATA="$PERSIST/pgdata"
UPLOADS="$PERSIST/uploads"
STATICMAP="$PERSIST/staticmap_cache"
LOGDIR="$PERSIST/logs"
mkdir -p "$PGDATA" "$UPLOADS" "$STATICMAP" "$LOGDIR"

# Locate the PostgreSQL binaries. The installed major version is whatever the
# postgis package depended on (recorded at build time in /etc/oh-pg-version).
PGVER=""
[ -f /etc/oh-pg-version ] && . /etc/oh-pg-version
if [ -n "$PGVER" ] && [ -d "/usr/libexec/postgresql$PGVER" ]; then
    PGBIN="/usr/libexec/postgresql$PGVER"
else
    PGBIN="$(ls -d /usr/libexec/postgresql* 2>/dev/null | head -1 || true)"
fi
[ -z "$PGBIN" ] && PGBIN="/usr/bin"
export PATH="$PGBIN:$PATH"
echo "[start] using postgres binaries at $PGBIN"

DB_NAME=fittrackee
DB_USER=fittrackee
DB_PASS="$(cat "$PERSIST/.pgpass" 2>/dev/null || true)"
if [ -z "$DB_PASS" ]; then
    # DB password for the loopback-only Postgres. Not a user credential; the
    # cluster only listens on 127.0.0.1 inside this container.
    DB_PASS="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "$DB_PASS" > "$PERSIST/.pgpass"
    chmod 600 "$PERSIST/.pgpass"
fi

# Postgres refuses to run as root and requires ownership of PGDATA.
chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

# --- initialise the cluster on first boot ----------------------------------
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[start] initialising PostgreSQL cluster"
    su-exec postgres initdb -D "$PGDATA" -E UTF8 --no-locale >/dev/null
    # Loopback only; trust local socket, md5 for TCP.
    echo "listen_addresses = '127.0.0.1'" >> "$PGDATA/postgresql.conf"
    echo "unix_socket_directories = '/tmp'" >> "$PGDATA/postgresql.conf"
fi

# Remove a stale pid left by an unclean previous shutdown (container was
# killed) so pg_ctl doesn't refuse to start / warn "another server might be
# running".
if [ -f "$PGDATA/postmaster.pid" ]; then
    STALE_PID="$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || true)"
    if [ -n "$STALE_PID" ] && ! kill -0 "$STALE_PID" 2>/dev/null; then
        echo "[start] removing stale postmaster.pid ($STALE_PID)"
        rm -f "$PGDATA/postmaster.pid"
    fi
fi

echo "[start] starting PostgreSQL"
su-exec postgres pg_ctl -D "$PGDATA" -o "-k /tmp" -w -t 60 start

# Wait for socket.
PG_UP=0
for i in $(seq 1 60); do
    if su-exec postgres psql -h /tmp -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
        PG_UP=1
        break
    fi
    sleep 1
done
if [ "$PG_UP" != "1" ]; then
    echo "[start] FATAL: PostgreSQL did not become ready"
    exit 1
fi

# --- provision role, db, postgis ------------------------------------------
su-exec postgres psql -h /tmp -d postgres -tc \
    "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
    su-exec postgres psql -h /tmp -d postgres -c \
        "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS'"
# Keep the password in sync if it was regenerated.
su-exec postgres psql -h /tmp -d postgres -c \
    "ALTER ROLE $DB_USER PASSWORD '$DB_PASS'" >/dev/null

su-exec postgres psql -h /tmp -d postgres -tc \
    "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 || \
    su-exec postgres psql -h /tmp -d postgres -c \
        "CREATE DATABASE $DB_NAME OWNER $DB_USER"
if ! su-exec postgres psql -h /tmp -d "$DB_NAME" -c \
        "CREATE EXTENSION IF NOT EXISTS postgis" >/dev/null; then
    echo "[start] FATAL: could not create the postgis extension (packaging bug?)"
    su-exec postgres pg_ctl -D "$PGDATA" -m fast stop || true
    exit 1
fi

# --- FitTrackee config -----------------------------------------------------
APP_SUBDOMAIN="${OPENHOST_APP_NAME:-fittrackee}"
if [ -n "${OPENHOST_ZONE_DOMAIN:-}" ]; then
    UI_URL="https://${APP_SUBDOMAIN}.${OPENHOST_ZONE_DOMAIN}"
else
    UI_URL="http://localhost:8080"
fi

SECRET_FILE="$PERSIST/.app_secret"
if [ ! -f "$SECRET_FILE" ]; then
    head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
fi
APP_SECRET_KEY="$(cat "$SECRET_FILE")"

export FLASK_APP=fittrackee
export APP_SETTINGS=fittrackee.config.ProductionConfig
export APP_SECRET_KEY
export DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"
export UI_URL
export UPLOAD_FOLDER="$UPLOADS"
export STATICMAP_CACHE_DIR="$STATICMAP"
export APP_WORKERS="${APP_WORKERS:-1}"

echo "[start] running migrations"
ftcli db upgrade

# --- provision the owner account (pre-activated) ---------------------------
RAW_OWNER="${OPENHOST_OWNER_USERNAME:-owner}"
SAFE_OWNER="$(printf '%s' "$RAW_OWNER" | tr -cd 'A-Za-z0-9_-' | cut -c1-30)"
[ -z "$SAFE_OWNER" ] && SAFE_OWNER="owner"
OWNER_EMAIL="${SAFE_OWNER}@${OPENHOST_ZONE_DOMAIN:-fittrackee.local}"

UID_FILE="$PERSIST/.owner_uid"
if [ ! -f "$UID_FILE" ]; then
    echo "[start] creating owner account '$SAFE_OWNER'"
    THROWAWAY="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')Aa1!"
    # ftcli exits non-zero if the user already exists; tolerate that.
    ftcli users create "$SAFE_OWNER" --email "$OWNER_EMAIL" \
        --password "$THROWAWAY" --role owner || \
        echo "[start] owner create returned non-zero (may already exist)"
    OWNER_ID="$(su-exec postgres psql -h /tmp -d "$DB_NAME" -tAc \
        "SELECT id FROM users WHERE username='$SAFE_OWNER' OR email='$OWNER_EMAIL' ORDER BY id LIMIT 1")"
    if [ -n "$OWNER_ID" ]; then
        printf '%s' "$OWNER_ID" > "$UID_FILE"
        chmod 600 "$UID_FILE"
    fi
fi
OWNER_ID="$(cat "$UID_FILE" 2>/dev/null || echo 1)"
echo "[start] owner id=$OWNER_ID email=$OWNER_EMAIL"

# --- start gunicorn (as fittrackee user) -----------------------------------
echo "[start] starting gunicorn"
su-exec fittrackee env \
    FLASK_APP="$FLASK_APP" APP_SETTINGS="$APP_SETTINGS" \
    APP_SECRET_KEY="$APP_SECRET_KEY" DATABASE_URL="$DATABASE_URL" \
    UI_URL="$UI_URL" UPLOAD_FOLDER="$UPLOADS" \
    STATICMAP_CACHE_DIR="$STATICMAP" \
    gunicorn -b 127.0.0.1:5000 "fittrackee:create_app()" \
        --workers="$APP_WORKERS" --timeout "${APP_TIMEOUT:-30}" \
        --log-level "${LOG_LEVEL:-info}" --no-control-socket &
GUNICORN_PID=$!

# --- start auth-proxy ------------------------------------------------------
export AUTH_PROXY_LISTEN_PORT="${PORT_OPENHOST:-8080}"
export BACKEND_HOST=127.0.0.1
export BACKEND_PORT=5000
export JWT_SECRET="$APP_SECRET_KEY"
export OWNER_ID
python3 /usr/local/bin/auth_proxy.py &
PROXY_PID=$!

wait -n "$GUNICORN_PID" "$PROXY_PID"
echo "[start] a child exited; shutting down"
su-exec postgres pg_ctl -D "$PGDATA" -m fast stop || true
kill "$GUNICORN_PID" "$PROXY_PID" 2>/dev/null || true
wait || true
exit 1
