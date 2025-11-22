#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Config and source path (allow override from environment)
CONFIG_PATH=${BEETS_CONFIG_PATH:-/config.yaml}
IMPORT_SRC_PATH=${IMPORT_SRC_PATH:-/import}
DRY_RUN=${DRY_RUN:-no}

# Run beets import.
# We instruct beets to import the IMPORT_SRC_PATH directory.
# -c config file path
# --move causes beets to move files into the library directory (not copy)
# --yes answers confirmations
# If DRY_RUN=yes, use --pretend so beets does not actually move files.
BEET_CMD=(beet -c "$CONFIG_PATH" import)
if [ "$DRY_RUN" = "yes" ]; then
  BEET_CMD+=(--pretend)
else
  BEET_CMD+=(--move)
fi
BEET_CMD+=("$IMPORT_SRC_PATH")

echo "Running: $(printf "%s " "${BEET_CMD[@]}" | tr '\n' ' ')"
set +e
"${BEET_CMD[@]}"
EXIT_CODE=$?
set -e

echo "Beets finished with exit code $EXIT_CODE"

exit "$EXIT_CODE"
