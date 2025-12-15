#!/usr/bin/env bash
# new-library.sh - Create a new Navidrome library and FileBrowser user
# Usage: ./new-library.sh <username> <password>
#
# This script:
# - Creates a new library in /extra-libraries/<username>
# - Links the library to an existing Navidrome user (extracted by username)
# - Creates a FileBrowser user with access only to /srv/extra-libraries/<username>
# - Username must be the same for both Navidrome and FileBrowser
#
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Colors (portable-ish): red for error, orange-ish for warn if possible
###############################################################################
_init_colors() {
  RED=""
  ORANGE=""
  RESET=""

  # Prefer tput when available for reset
  if command -v tput >/dev/null 2>&1; then
    RESET="$(tput sgr0 2>/dev/null || true)"
  else
    RESET=$'\033[0m'
  fi

  # Detect 256-color capable terminals (TERM contains 256color)
  if [[ "${TERM:-}" == *256color* ]]; then
    # Orange-like (color 208)
    ORANGE=$'\033[38;5;208m'
    RED=$'\033[31m'
  else
    # Fallback to tput setaf or basic ANSI
    if command -v tput >/dev/null 2>&1; then
      RED="$(tput setaf 1 2>/dev/null || true)"
      ORANGE="$(tput setaf 3 2>/dev/null || true)"
      # If tput failed return empty, fall back to ANSI
      [ -z "$RED" ] && RED=$'\033[31m'
      [ -z "$ORANGE" ] && ORANGE=$'\033[33m'
    else
      RED=$'\033[31m'
      ORANGE=$'\033[33m'
    fi
  fi

  # If stderr not a terminal, disable colors to keep logs clean
  if [[ ! -t 2 ]]; then
    RED=""
    ORANGE=""
    RESET=""
  fi
}

_init_colors
time_stamp() { date +"%Y-%m-%d %H:%M:%S"; }
err()  { printf '%s %sERROR:%s %s\n' "$(time_stamp)" "$RED" "$RESET" "$*" >&2; }
warn() { printf '%s %sWARN:%s %s\n'  "$(time_stamp)" "$ORANGE" "$RESET" "$*" >&2; }
info() { printf '%s INFO: %s\n' "$(time_stamp)" "$*"; }

###############################################################################
# Usage
###############################################################################
usage() {
  cat <<EOF
Usage: $(basename "$0") <username> <password>

Creates a new Navidrome library and FileBrowser user account.

Arguments:
  username    Username (must already exist in Navidrome)
  password    Password for the FileBrowser user

Example:
  $(basename "$0") alice MySecurePass123

Requirements:
  - .env file must exist in script directory
  - NAVIDROME_EXTRA_LIBRARIES_PATH must be set in .env
  - navidrome and filebrowser containers must be running
  - User with <username> must already exist in Navidrome

Note:
  The same username will be used for both Navidrome (existing) and FileBrowser (new).
  FileBrowser will be stopped temporarily during user creation.
EOF
}

###############################################################################
# Parse arguments
###############################################################################
if [[ $# -ne 2 ]]; then
  err "Invalid number of arguments."
  usage
  exit 1
fi

USERNAME="$1"
PASSWORD="$2"

if [[ -z "$USERNAME" ]]; then
  err "Username cannot be empty."
  exit 1
fi

if [[ -z "$PASSWORD" ]]; then
  err "Password cannot be empty."
  exit 1
fi

# Validate username (alphanumeric, underscores, hyphens only)
if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  err "Username can only contain letters, numbers, underscores, and hyphens."
  exit 1
fi

###############################################################################
# Locate script dir and load .env
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  err ".env not found in script directory ($SCRIPT_DIR). Please create it before running."
  exit 2
fi

# Export variables from .env safely (ignores commented lines)
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

###############################################################################
# Validate required environment variables
###############################################################################
: "${NAVIDROME_EXTRA_LIBRARIES_PATH:?"NAVIDROME_EXTRA_LIBRARIES_PATH is not set in .env"}"

NAVIDROME_CONTAINER="${NAVIDROME_CONTAINER_NAME:-navidrome}"
FILEBROWSER_CONTAINER="${FILEBROWSER_CONTAINER_NAME:-filebrowser}"
DB_FILE="${DB_FILE:-/database/filebrowser.db}"

###############################################################################
# Check if required containers are running
###############################################################################
info "Checking required containers..."

check_container() {
  local container_name="$1"
  if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    err "Container '${container_name}' is not running."
    return 1
  fi
  info "✓ Container '${container_name}' is running."
  return 0
}

if ! check_container "$NAVIDROME_CONTAINER"; then
  exit 3
fi

if ! check_container "$FILEBROWSER_CONTAINER"; then
  exit 3
fi

###############################################################################
# Helper function to execute SQL and capture errors
###############################################################################
exec_sql() {
  local sql="$1"
  local error_output
  local result
  
  error_output=$(mktemp)
  trap 'rm -f "$error_output"' RETURN
  
  result=$(docker exec "$NAVIDROME_CONTAINER" sqlite3 /data/navidrome.db "$sql" 2>"$error_output")
  local exit_code=$?
  
  if [[ $exit_code -ne 0 ]]; then
    err "SQL execution failed with exit code $exit_code"
    if [[ -s "$error_output" ]]; then
      err "SQLite error output:"
      cat "$error_output" >&2
    fi
    return $exit_code
  fi
  
  echo "$result"
  return 0
}

###############################################################################
# Validate Navidrome user exists and extract user ID
###############################################################################
info "Validating Navidrome user '${USERNAME}' exists..."

NAVIDROME_USER_ID=$(exec_sql "SELECT id FROM user WHERE user_name = '${USERNAME}';" || echo "")

if [[ -z "$NAVIDROME_USER_ID" ]]; then
  err "Navidrome user '${USERNAME}' does not exist."
  err "Please create the user in Navidrome first, then run this script."
  exit 4
fi

info "✓ Found Navidrome user '${USERNAME}' with ID: ${NAVIDROME_USER_ID}"

###############################################################################
# Create physical library directory
###############################################################################
LIBRARY_PATH="/extra-libraries/${USERNAME}"
PHYSICAL_LIBRARY_PATH="${NAVIDROME_EXTRA_LIBRARIES_PATH}/${USERNAME}"
LIBRARY_NAME="${USERNAME}_library"

info "Creating library directory: ${PHYSICAL_LIBRARY_PATH}"

if [[ -d "$PHYSICAL_LIBRARY_PATH" ]]; then
  warn "Directory already exists: ${PHYSICAL_LIBRARY_PATH}"
else
  mkdir -p "$PHYSICAL_LIBRARY_PATH"
  
  # Set ownership to match PUID:PGID if available
  if [[ -n "${PUID:-}" ]] && [[ -n "${PGID:-}" ]]; then
    chown "${PUID}:${PGID}" "$PHYSICAL_LIBRARY_PATH" 2>/dev/null || \
      warn "Could not set ownership on ${PHYSICAL_LIBRARY_PATH} (may require sudo)"
  fi
  
  info "✓ Directory created successfully."
fi

###############################################################################
# Create or retrieve library in Navidrome database
###############################################################################
info "Creating/retrieving library: ${LIBRARY_NAME}"

# Check if library already exists
EXISTING_LIBRARY=$(exec_sql "SELECT id FROM library WHERE path = '${LIBRARY_PATH}' OR name = '${LIBRARY_NAME}';" || echo "")

if [[ -n "$EXISTING_LIBRARY" ]]; then
  warn "Library with path '${LIBRARY_PATH}' or name '${LIBRARY_NAME}' already exists."
  LIBRARY_ID="$EXISTING_LIBRARY"
  info "Using existing library ID: ${LIBRARY_ID}"
else
  # Insert new library
  info "Inserting new library into Navidrome database..."
  
  exec_sql "INSERT INTO library (name, path, remote_path, last_scan_at, updated_at, created_at, last_scan_started_at, full_scan_in_progress, total_songs, total_albums, total_artists, total_folders, total_files, total_missing_files, total_size, total_duration, default_new_users) VALUES ('${LIBRARY_NAME}', '${LIBRARY_PATH}', '', '0000-00-00 00:00:00', datetime('now'), datetime('now'), '0000-00-00 00:00:00', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);" >/dev/null
  
  if [[ $? -ne 0 ]]; then
    err "Failed to create library in database."
    exit 5
  fi

  info "Library created, retrieving ID..."
  
  # Get the library ID
  LIBRARY_ID=$(exec_sql "SELECT id FROM library WHERE path = '${LIBRARY_PATH}';" || echo "")
  
  if [[ -z "$LIBRARY_ID" ]]; then
    # Try by name instead
    LIBRARY_ID=$(exec_sql "SELECT id FROM library WHERE name = '${LIBRARY_NAME}';" || echo "")
  fi
  
  if [[ -z "$LIBRARY_ID" ]]; then
    err "Failed to retrieve library ID after creation."
    info "Debugging: Current libraries in database:"
    exec_sql "SELECT id, name, path FROM library;" || true
    exit 6
  fi

  info "✓ Library created with ID: ${LIBRARY_ID}"
fi

###############################################################################
# Link library to Navidrome user
###############################################################################
info "Linking library to Navidrome user..."

# Check if user_library table exists
TABLE_CHECK=$(exec_sql "SELECT name FROM sqlite_master WHERE type='table' AND name='user_library';" || echo "")

if [[ -z "$TABLE_CHECK" ]]; then
  err "Table 'user_library' does not exist in the database."
  info "Available tables:"
  exec_sql "SELECT name FROM sqlite_master WHERE type='table';" || true
  exit 7
fi

# Check if link already exists
EXISTING_LINK=$(exec_sql "SELECT user_id FROM user_library WHERE user_id = '${NAVIDROME_USER_ID}' AND library_id = '${LIBRARY_ID}';" || echo "")

if [[ -n "$EXISTING_LINK" ]]; then
  warn "Library ${LIBRARY_ID} is already linked to user ${NAVIDROME_USER_ID}"
else
  exec_sql "INSERT INTO user_library (user_id, library_id) VALUES ('${NAVIDROME_USER_ID}', '${LIBRARY_ID}');"
  
  if [[ $? -ne 0 ]]; then
    err "Failed to link library to user."
    exit 8
  fi
  
  info "✓ Library linked to user successfully."
fi

###############################################################################
# Create FileBrowser user with database access
###############################################################################
info "Creating FileBrowser user '${USERNAME}'..."

# FileBrowser scope: ./extra-libraries/<username>
FB_SCOPE="./extra-libraries/${USERNAME}"
DB_FILE="${DB_FILE:-/database/filebrowser.db}"

# Stop FileBrowser container to release database lock
info "Stopping FileBrowser container temporarily..."
docker stop "$FILEBROWSER_CONTAINER" >/dev/null 2>&1

# Ensure we restart it on exit (even if script fails)
trap "info 'Restarting FileBrowser container...'; docker start '$FILEBROWSER_CONTAINER' >/dev/null 2>&1" EXIT

# Wait for container to fully stop
sleep 2

# Check if user already exists in FileBrowser
info "Checking if FileBrowser user '${USERNAME}' exists..."

# Run a temporary container with the filebrowser CLI to check users
USER_EXISTS=$(docker run --rm \
  --volumes-from "$FILEBROWSER_CONTAINER" \
  filebrowser/filebrowser:v2.52.0 \
  users ls -d "$DB_FILE" 2>/dev/null | \
  awk '{print $2}' | grep -x "$USERNAME" || echo "")

if [[ -n "$USER_EXISTS" ]]; then
  warn "FileBrowser user '${USERNAME}' already exists. Updating password and scope..."
  
  docker run --rm \
    --volumes-from "$FILEBROWSER_CONTAINER" \
    filebrowser/filebrowser:v2.52.0 \
    users update "$USERNAME" \
    --password "$PASSWORD" \
    --scope "$FB_SCOPE" \
    -d "$DB_FILE" >/dev/null 2>&1
  
  if [[ $? -eq 0 ]]; then
    info "✓ FileBrowser user updated successfully."
  else
    err "Failed to update FileBrowser user."
    exit 9
  fi
else
  # Create new user
  info "Creating new FileBrowser user..."
  
  docker run --rm \
    --volumes-from "$FILEBROWSER_CONTAINER" \
    filebrowser/filebrowser:v2.52.0 \
    users add "$USERNAME" "$PASSWORD" \
    --scope "$FB_SCOPE" \
    -d "$DB_FILE" >/dev/null 2>&1
  
  if [[ $? -eq 0 ]]; then
    info "✓ FileBrowser user '${USERNAME}' created successfully."
  else
    err "Failed to create FileBrowser user."
    exit 9
  fi
fi

# Remove trap and restart container explicitly
trap - EXIT
info "Restarting FileBrowser container..."
docker start "$FILEBROWSER_CONTAINER" >/dev/null 2>&1

# Wait for FileBrowser to be ready
sleep 3
info "✓ FileBrowser container restarted successfully."

###############################################################################
# Summary
###############################################################################
echo
echo "========================================"
echo "   Library & User Creation Summary"
echo "========================================"
echo "Username:                ${USERNAME}"
echo "Navidrome User ID:       ${NAVIDROME_USER_ID}"
echo ""
echo "Library Name:            ${LIBRARY_NAME}"
echo "Library Path (internal): ${LIBRARY_PATH}"
echo "Library Path (host):     ${PHYSICAL_LIBRARY_PATH}"
echo "Library ID:              ${LIBRARY_ID}"
echo ""
echo "FileBrowser Access:      ${FB_SCOPE}"
echo "========================================"
echo
info "Setup completed successfully!"
info "User '${USERNAME}' can now:"
info "  - Access the new library in Navidrome"
info "  - Upload files via FileBrowser to: ${FB_SCOPE}"
echo