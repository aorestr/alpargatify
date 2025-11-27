#!/bin/sh
set -eu

: "${FILEBROWSER_ADMIN_USER}"
: "${FILEBROWSER_ADMIN_PASSWORD}"
: "${DB_DIR:=/database}"
: "${DB_FILE:=${DB_DIR}/filebrowser.db}"
: "${ROOT_DIR:=/srv/music}"
: "${PORT:=8080}"
: "${ADDRESS:=0.0.0.0}"
: "${FB_TIMEOUT:=15}"   # seconds to wait for DB file creation during quick-setup

# Create dirs and ensure mounts exist
mkdir -p "$DB_DIR"
mkdir -p "$ROOT_DIR"

# best-effort chmod/chown to match host UID/GID (ignore errors)
# note: adjust if you prefer not to chown
chown -R "${PUID}:${PGID}" "$DB_DIR" "$ROOT_DIR" || true
chmod -R u+rw "$DB_DIR" "$ROOT_DIR" || true

# Helper to start filebrowser as quick-setup (background)
start_quick_setup() {
  echo "Starting temporary filebrowser quick-setup to bootstrap DB and initial user..."
  # run filebrowser in background with username/password so it bootstraps DB
  filebrowser -r "$ROOT_DIR" -d "$DB_FILE" --username "$FILEBROWSER_ADMIN_USER" --password "$FILEBROWSER_ADMIN_PASSWORD" --port "$PORT" --address "$ADDRESS" >/tmp/filebrowser-quick.log 2>&1 &
  FB_PID=$!
  # wait for DB file to appear (timeout)
  i=0
  while [ ! -f "$DB_FILE" ] && [ $i -lt "$FB_TIMEOUT" ]; do
    sleep 1
    i=$((i+1))
  done

  if [ -f "$DB_FILE" ]; then
    echo "Database created at $DB_FILE by quick-setup."
  else
    echo "Timed out waiting for DB creation. Dumping quick-setup log:" >&2
    sed -n '1,200p' /tmp/filebrowser-quick.log || true
  fi

  # gracefully stop the temporary server if still running
  if kill -0 "$FB_PID" 2>/dev/null; then
    echo "Stopping temporary quick-setup process (pid $FB_PID)..."
    kill "$FB_PID"
    # give it a little time to stop
    sleep 1
    if kill -0 "$FB_PID" 2>/dev/null; then
      kill -9 "$FB_PID" || true
    fi
  fi
}

# Check if DB exists
if [ ! -f "$DB_FILE" ]; then
  # DB missing: perform quick-setup to create DB + initial user
  start_quick_setup
else
  echo "Database $DB_FILE already exists — skipping quick-setup."
fi

# At this point DB should exist (or we tried). Now ensure admin user exists and password is correct.
# Use `filebrowser users find` / `users add` / `users update` against the DB.
# The filebrowser binary will read DB by default from current dir; pass -d to ensure we target same DB.
USER_PRESENT=0
if filebrowser users ls -d "$DB_FILE" >/dev/null 2>&1; then
  # list users, check first column for username match
  if filebrowser users ls -d "$DB_FILE" | awk '{print $2}' | grep -x -- "$FILEBROWSER_ADMIN_USER" >/dev/null 2>&1; then
    USER_PRESENT=1
  fi
fi

if [ "$USER_PRESENT" -eq 1 ]; then
  echo "User '$FILEBROWSER_ADMIN_USER' already exists in DB — updating password and admin perm."
  # update password and ensure admin perm; CLI uses --password to set hashed password (it accepts plain text and hashes it)
  filebrowser users update "$FILEBROWSER_ADMIN_USER" --password "$FILEBROWSER_ADMIN_PASSWORD" --perm.admin -d "$DB_FILE" || {
    echo "Warning: user update failed; continuing."
  }
else
  echo "Creating user '$FILEBROWSER_ADMIN_USER' in DB..."
  filebrowser users add "$FILEBROWSER_ADMIN_USER" "$FILEBROWSER_ADMIN_PASSWORD" --perm.admin -d "$DB_FILE" || {
    echo "Warning: user add failed; continuing."
  }
fi

# Final: run filebrowser foreground with explicit DB and root, listening on all interfaces
echo "Starting filebrowser (foreground) with DB=$DB_FILE and root=$ROOT_DIR on $ADDRESS:$PORT ..."
exec filebrowser -r "$ROOT_DIR" -d "$DB_FILE" --address "$ADDRESS" -p "$PORT"
