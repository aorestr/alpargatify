#!/usr/bin/env bash
# wrapper.sh
#  - Runs your flac-to-aac.sh conversion into a temporary directory (preserving paths)
#  - Then runs a single Docker Compose service: beets, which imports from the temp dir
#
# Usage:
#   ./wrapper.sh [--force] [--dry-run] [--beets-config /abs/path/to/beets_config.yaml] \
#                            /path/to/source /absolute/path/to/music_library_root
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
BEETS_CONFIG="$SCRIPT_DIR/docker/beets/beets_config.yaml"
FORCE="no"
DRY_RUN="no"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--force] [--dry-run] [--beets-config /path/to/beets_config.yaml] /path/to/source /absolute/path/to/music_library_root

Notes:
 - Destination must be the root of your music library (where beets will place files).
 - The converter will write into a temporary directory; beets will read from that temp dir and move files into the destination library.
EOF
}

# Parse args
POSITIONAL=()
while (( "$#" )); do
  case "$1" in
    --force) FORCE="yes"; shift ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    --beets-config) BEETS_CONFIG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

if [ "${#}" -ne 2 ]; then
  echo "Error: source and destination required." >&2
  usage
  exit 2
fi

SRC="$1"
DEST="$2"

# Sanity checks
if [ ! -d "$SRC" ]; then
  echo "Error: source directory does not exist: $SRC" >&2
  exit 3
fi

# Ensure DEST is absolute path
if [[ "$DEST" != /* ]]; then
  echo "Error: destination must be an absolute path (root of your music library)." >&2
  exit 8
fi
mkdir -p "$DEST"

CONVERTER="$SCRIPT_DIR/flac-to-aac.sh"
if [ ! -x "$CONVERTER" ]; then
  echo "Error: converter script not found or not executable at: $CONVERTER" >&2
  exit 4
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker not found in PATH. Docker is required." >&2
  exit 5
fi

# Compose command check (docker compose or docker-compose)
COMPOSE_CMD=""
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "Error: neither 'docker compose' nor 'docker-compose' found. Install Docker Compose." >&2
  exit 6
fi

# Confirm beets config exists (warning if not)
if [ -n "$BEETS_CONFIG" ]; then
  if [ -f "$BEETS_CONFIG" ]; then
    echo "Using beets config: $BEETS_CONFIG"
  else
    echo "Warning: beets_config not found at $BEETS_CONFIG. The beets container will run with its default config." >&2
  fi
fi

echo "=== Settings ==="
echo "Script dir:        $SCRIPT_DIR"
echo "Source (input):    $SRC"
echo "Music library root: $DEST"
echo "Converter:         $CONVERTER"
echo "Beets config:      $BEETS_CONFIG"
echo "Force:             $FORCE"
echo "Dry run:           $DRY_RUN"
echo "Docker compose:    $COMPOSE_CMD"
echo "================"
echo

# Create temporary directory for converter output
TMP_DEST="$(mktemp -d -t beets_import_XXXXXX)"
echo "Temporary converter destination: $TMP_DEST"

# Ensure tempdir cleanup on exit (unless dry-run is requested)
cleanup() {
  if [ "$DRY_RUN" = "yes" ]; then
    echo "Dry-run mode: leaving temporary directory for inspection: $TMP_DEST"
  else
    echo "Cleaning up temporary directory: $TMP_DEST"
    rm -rf "$TMP_DEST" || true
  fi
}
trap cleanup EXIT

# Step 1: run conversion script (converter writes into TMP_DEST, preserving paths)
conv_args=()
[ "$FORCE" = "yes" ] && conv_args+=(--force)
[ "$DRY_RUN" = "yes" ] && conv_args+=(--dry-run)
# converter expected to accept: source dest
conv_args+=( "$SRC" "$TMP_DEST" )

echo "-> STEP 1: running converter (output -> temp dir)"
echo "Running: $CONVERTER ${conv_args[*]}"
"$CONVERTER" "${conv_args[@]}"
echo "-> STEP 1 finished."
echo

# Step 2: run beets import service (single service)
# Compose file must be under docker/ next to script
COMPOSE_FILE="$SCRIPT_DIR/docker/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Error: docker compose file not found at $COMPOSE_FILE" >&2
  exit 7
fi

# Export env vars used by docker-compose
# DEST_PATH = absolute path to your music library root (where beets will put files)
export DEST_PATH="$DEST"
# IMPORT_SRC = absolute path to the temporary converter output
export IMPORT_SRC="$TMP_DEST"
# Pass BEETS_CONFIG path (may be a file on host)
export BEETS_CONFIG="$BEETS_CONFIG"
# Pass DRY_RUN indicator (beets can be configured or entrypoint can read it)
export DRY_RUN="$DRY_RUN"

echo "-> STEP 2: invoking docker compose (beets import)"
pushd "$SCRIPT_DIR/docker" >/dev/null

# Use --abort-on-container-exit so compose stops after the one-shot service finishes
if [ "$COMPOSE_CMD" = "docker compose" ]; then
  docker compose -f docker-compose.yml up --build --abort-on-container-exit
  EXIT_CODE=$?
else
  docker-compose -f docker-compose.yml up --build --abort-on-container-exit
  EXIT_CODE=$?
fi

popd >/dev/null

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "Beets (docker compose) finished with non-zero exit code: $EXIT_CODE" >&2
  exit $EXIT_CODE
fi

echo "-> STEP 2 finished. All done."
exit 0
