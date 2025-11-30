#!/usr/bin/env bash
# flac-to-aac.sh - macOS: recursively convert .flac -> AAC (.m4a) using afconvert
# - preserves source tree under destination
# - preserves tags (requires metaflac + AtomicParsley; will warn if missing)
# - env/configurable options via AF_OPTS (see below)
# - flags: --help, --force (overwrite), --dry-run
#
# Based on: https://ss64.com/mac/afconvert.html

set -u
set -o pipefail
IFS=$'\n\t'

###############################################################################
# Colors & logging
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
debug(){ if [ "$VERBOSE" = "yes" ]; then printf '%s DEBUG: %s\n' "$(time_stamp)" "$*"; fi }

###############################################################################
# Defaults (change by editing script or via AF_OPTS env)
###############################################################################
# Default chosen: 192 kbps AAC with sample rate
DEFAULT_AF_ARGS=( -f m4af -d "aac" -b 192000 -q 127 )

: "${AF_OPTS:=}"          # optional string of extra/override options
: "${SKIP_EXISTING:=yes}" # yes -> skip existing outputs; no -> overwrite
: "${VERBOSE:=no}"        # yes -> extra debug
: "${DRY_RUN:=no}"        # yes -> don't execute, just show commands

usage() {
  cat <<EOF
flac-to-aac.sh - convert .flac -> AAC (.m4a) (macOS afconvert)

Usage:
  $(basename "$0") [--force] [--dry-run] /path/to/source /path/to/destination

Flags:
  -h, --help      show this help and exit
  --force         overwrite existing destination files (equivalent to SKIP_EXISTING=no)
  --dry-run       show actions without running afconvert (equivalent to DRY_RUN=yes)

Environment:
  AF_OPTS         optional extra afconvert options (whitespace-separated tokens)
                  Example: AF_OPTS='-f mp4f -d "aacf@24000" -b 256000 -q 127' ./flac-to-aac.sh src dest
  SKIP_EXISTING   ${SKIP_EXISTING}
  VERBOSE         ${VERBOSE}
  DRY_RUN         ${DRY_RUN}

Default encoding (change AF_OPTS to override):
  ${DEFAULT_AF_ARGS[*]}
EOF
}

# --- minimal flag parsing ---
declare -a POSITIONAL=()
FORCE_FROM_CLI="no"

while (( "$#" )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE_FROM_CLI="yes"; shift ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    --) shift; break ;;
    -*)
      err "Unknown option: $1"
      usage
      exit 2
      ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

set -- "${POSITIONAL[@]:-}"

if [ "${#}" -ne 2 ]; then
  err "source and destination required."
  usage
  exit 2
fi

SRC="$1"
DEST="$2"

# apply --force
if [ "$FORCE_FROM_CLI" = "yes" ]; then
  SKIP_EXISTING="no"
fi

# normalize yes/no
normalize_bool() {
  case "$1" in
    yes|Yes|YES|y|Y|true|True|TRUE) echo "yes" ;;
    *) echo "no" ;;
  esac
}
SKIP_EXISTING="$(normalize_bool "$SKIP_EXISTING")"
DRY_RUN="$(normalize_bool "$DRY_RUN")"
VERBOSE="$(normalize_bool "$VERBOSE")"

# --- PRECHECKS: macOS and required commands ---
if [ "$(uname -s)" != "Darwin" ]; then
  err "afconvert is macOS-only. This script requires macOS (Darwin)."
  exit 5
elif ! command -v afconvert >/dev/null 2>&1; then
  err "afconvert not found in PATH. Ensure you're on macOS and Xcode (or Command Line Tools) is installed."
  exit 6
fi

# Optional metadata tools
MISSING_META_TOOLS=""
if ! command -v metaflac >/dev/null 2>&1; then MISSING_META_TOOLS="$MISSING_META_TOOLS metaflac"; fi
if ! command -v AtomicParsley >/dev/null 2>&1; then MISSING_META_TOOLS="$MISSING_META_TOOLS AtomicParsley"; fi
if [ -n "$MISSING_META_TOOLS" ]; then
  warn "metadata copying will be skipped or limited because the following tools are missing:$MISSING_META_TOOLS"
fi

# Check for XLD (for splitting images using CUE)
XLD_PRESENT="no"
if command -v xld >/dev/null 2>&1; then
  XLD_PRESENT="yes"
else
  warn "XLD not found. Cue-based splitting will be skipped; single-file conversion only."
fi

# Sanity checks
if [ ! -d "$SRC" ]; then
  err "source directory does not exist: $SRC"
  exit 3
fi
mkdir -p "$DEST" || { err "cannot create destination: $DEST"; exit 4; }
SRC="${SRC%/}"

# Parse AF_OPTS -- split on whitespace into tokens safely
if [ -n "${AF_OPTS}" ]; then
  eval "AF_ARGS=($AF_OPTS)"
  debug "Using custom AF_OPTS: $(printf '%s ' "${AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
  debug "Remember that default is: $(printf '%s ' "${DEFAULT_AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
else
  AF_ARGS=( "${DEFAULT_AF_ARGS[@]}" )
fi

# helper to join arguments into one single-line string for logging
join_args() {
  local IFS=' '
  printf '%s' "$*"
}

info "Settings summary:"
info "  Source:        $SRC"
info "  Destination:   $DEST"
# print AF_ARGS as single-line
debug "  afconvert args: $(printf '%s ' "${AF_ARGS[@]}" | sed -E 's/[[:space:]]+$//')"
info "  SKIP_EXISTING: $SKIP_EXISTING"
info "  DRY_RUN:       $DRY_RUN"
info "  VERBOSE:       $VERBOSE"
info ""

# Helper: convert a single audio file to m4a using afconvert (used for both single .flac and split tracks)
# Arguments:
#   $1 = input file path
#   $2 = destination directory (already created)
convert_to_m4a() {
  local in_file="$1"
  local out_dir="$2"
  local base="$(basename "$in_file")"
  local name="${base%.*}"
  local out_file="$out_dir/$name.m4a"

  if [ -e "$out_file" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      debug "Skipping (exists): $out_file"
      return 0
    else
      rm -f "$out_file" || { warn "could not remove existing $out_file"; return 1; }
    fi
  fi

  info "Converting: ${in_file#$SRC/} -> ${out_file#$DEST/}"
  if [ "$DRY_RUN" = "yes" ]; then
    # Print safe, human-readable command (single line)
    printf '  -> DRY RUN: afconvert'
    for tok in "${AF_ARGS[@]}"; do printf ' %s' "$tok"; done
    printf ' %q %q\n' "$in_file" "$out_file"
    return 0
  fi

  # assemble command array (array preserves tokenization)
  local cmd=(afconvert)
  if [ "${#AF_ARGS[@]}" -gt 0 ]; then
    cmd+=( "${AF_ARGS[@]}" )
  fi
  cmd+=( "$in_file" "$out_file" )

  debug "Running: $(printf '%s ' "${cmd[@]}" | sed -E 's/[[:space:]]+$//')"

  if "${cmd[@]}"; then
    # metadata copy (best-effort; non-fatal)
    if command -v metaflac >/dev/null 2>&1 && command -v AtomicParsley >/dev/null 2>&1; then
      # Try to read tags from source if it's FLAC; otherwise skip metaflac read.
      case "${in_file##*/}" in
        *.flac|*.FLAC)
          TMPD2="$(mktemp -d 2>/dev/null || mktemp -d -t flac2aac_tmp 2>/dev/null || true)"
          if [ -n "$TMPD2" ]; then
            metafile="$TMPD2/meta.txt"
            ap_args=()
            if metaflac --export-tags-to="$metafile" "$in_file" 2>/dev/null; then
              while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                key="${line%%=*}"
                val="${line#*=}"
                case "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" in
                  TITLE) ap_args+=( --title "$val" ) ;;
                  ARTIST) ap_args+=( --artist "$val" ) ;;
                  ALBUM) ap_args+=( --album "$val" ) ;;
                  TRACKNUMBER) ap_args+=( --tracknum "$val" ) ;;
                  DATE|YEAR) ap_args+=( --year "$val" ) ;;
                  GENRE) ap_args+=( --genre "$val" ) ;;
                  COMMENT) ap_args+=( --comment "$val" ) ;;
                  ALBUMARTIST) ap_args+=( --albumArtist "$val" ) ;;
                  COMPOSER) ap_args+=( --composer "$val" ) ;;
                  DISCNUMBER) ap_args+=( --disk "$val" ) ;;
                esac
              done < "$metafile"

              picfile="$TMPD2/cover"
              if metaflac --export-picture-to="$picfile" "$in_file" 2>/dev/null; then
                if command -v file >/dev/null 2>&1; then
                  ftype=$(file --brief --mime-type "$picfile" 2>/dev/null || echo "image/jpeg")
                  case "$ftype" in
                    image/png) picfile_ext="${picfile}.png" ;;
                    image/jpeg) picfile_ext="${picfile}.jpg" ;;
                    image/*) picfile_ext="${picfile}.img" ;;
                    *) picfile_ext="${picfile}.jpg" ;;
                  esac
                  mv "$picfile" "$picfile_ext" 2>/dev/null || true
                else
                  picfile_ext="${picfile}.jpg"
                  mv "$picfile" "$picfile_ext" 2>/dev/null || true
                fi
                ap_args+=( --artwork "$picfile_ext" )
              fi

              if [ "${#ap_args[@]}" -gt 0 ]; then
                debug "Applying metadata with AtomicParsley: $(printf '%s ' "${ap_args[@]}" | sed -E 's/[[:space:]]+$//')"
                if AtomicParsley "$out_file" "${ap_args[@]}" --overWrite >/dev/null 2>&1; then
                  debug "Metadata written to $out_file"
                else
                  warn "AtomicParsley failed to write metadata to $out_file"
                fi
              fi
            fi
            # cleanup
            if [ -n "$TMPD2" ] && [ -d "$TMPD2" ]; then
              rm -rf "$TMPD2" || true
            fi
          fi
          ;;
        *)
          # For non-FLAC sources (e.g. WAV produced by XLD), don't attempt metaflac read.
          debug "Input not FLAC; skipping metaflac-based metadata copy for $in_file"
          ;;
      esac
    else
      debug "metaflac or AtomicParsley not available; skipping metadata copy for $out_file"
    fi

    info "  -> OK"
    return 0
  else
    err "  -> ERROR converting $in_file"
    [ -e "$out_file" ] && rm -f "$out_file"
    return 1
  fi
}

# Convert .flac files (and .flac images with cue -> split to tracks via XLD)
# Use find -print0 and a while loop in same shell (avoid piping into while which creates subshell)
while IFS= read -r -d '' srcfile; do
  # compute relative path
  if [[ "$srcfile" == "$SRC/"* ]]; then
    relpath="${srcfile:$(( ${#SRC} + 1 ))}"
  else
    relpath="$srcfile"
  fi
  dirpart="$(dirname "$relpath")"
  base="$(basename "$relpath")"
  name="${base%.*}"
  if [ "$dirpart" = "." ]; then
    destdir="$DEST"
  else
    destdir="$DEST/$dirpart"
  fi
  mkdir -p "$destdir" || { warn "could not create $destdir"; continue; }
  destfile="$destdir/$name.m4a"

  # === NEW: detect CUE sheet that represents "image" / single-file album ===
  # Two cases to detect a cue for this .flac:
  # 1) a file named "<orig>.flac.cue" exists next to the .flac
  # 2) a file named "<orig_without_ext>.cue" exists next to the .flac
  cue_candidate1="${srcfile%.flac}.cue"           # e.g. album.flac.cue
  cue_candidate2="${srcfile}.cue"                 # e.g. album.cue
  CUE_FILE=""
  if [ -f "$cue_candidate1" ]; then
    CUE_FILE="$cue_candidate1"
    debug "Found cue sheet (case 1): $CUE_FILE"
  elif [ -f "$cue_candidate2" ]; then
    CUE_FILE="$cue_candidate2"
    debug "Found cue sheet (case 2): $CUE_FILE"
  fi

  if [ -n "$CUE_FILE" ] && [ "$XLD_PRESENT" = "yes" ]; then
    # We assume this .flac + CUE is an image and must be split into tracks.
    info "Detected CUE for image: ${relpath} -> splitting into tracks with XLD"
    # create temp dir per file
    TMPD="$(mktemp -d 2>/dev/null || mktemp -d -t flac2aac_tmp 2>/dev/null || true)"
    if [ -z "$TMPD" ]; then
      warn "could not create temp dir; skipping cue split for $srcfile"
      # fallback to normal single-file conversion below
    else
      # Run XLD in the temp dir so outputs are written there
      # Use documented CLI: xld -c <cue> -f <format> <audiofile>
      XLD_LOG="$TMPD/xld.log"
      debug "Running XLD to split: (cd $TMPD && xld -c $CUE_FILE -f wav $srcfile >$XLD_LOG 2>&1)"
      if [ "$DRY_RUN" = "yes" ]; then
        printf '  -> DRY RUN: (cd %s && xld -c %q -f wav %q)\n' "$TMPD" "$CUE_FILE" "$srcfile"
        # cleanup temp dir
        rm -rf "$TMPD" || true
        continue
      fi

      ( cd "$TMPD" && xld -c "$CUE_FILE" -f flac "$srcfile" >"$XLD_LOG" 2>&1 )
      XLD_RC=$?
      if [ $XLD_RC -ne 0 ]; then
        # include a short excerpt of the XLD log to help debugging (but keep messages brief)
        if [ -s "$XLD_LOG" ]; then
          # show last 20 lines of log in debug mode, but always capture a short summary for the warn
          tail -n 20 "$XLD_LOG" | sed -n '1,20p' > "$XLD_LOG.summary" 2>/dev/null || true
          warn "XLD failed (exit $XLD_RC) while splitting $CUE_FILE; falling back to single-file conversion for $srcfile. XLD log (last lines):"
          while IFS= read -r line; do warn "  $line"; done < <(tail -n 10 "$XLD_LOG" 2>/dev/null)
        else
          warn "XLD failed (exit $XLD_RC) while splitting $CUE_FILE; no xld.log produced. Falling back to single-file conversion for $srcfile"
        fi
        rm -rf "$TMPD" || true
        # fall through to normal conversion path below
      else
        # success: convert each produced track in TMPD
        find "$TMPD" -maxdepth 1 -type f \( -iname '*.flac' \) -print0 | while IFS= read -r -d '' trackfile; do
          convert_to_m4a "$trackfile" "$destdir"
        done

        # cleanup temp dir
        rm -rf "$TMPD" || true
        # continue to next source file
        continue
      fi
    fi
  elif [ -n "$CUE_FILE" ] && [ "$XLD_PRESENT" = "no" ]; then
    # CUE exists but XLD not found
    warn "Found cue sheet for $srcfile but XLD not available; performing regular single-file conversion."
    # fall through to single-file conversion below
  fi
  # === END NEW: CUE detection and splitting ===

  # If we reach here, either no CUE was found or splitting failed/fallback -> perform normal single-file conversion

  if [ -e "$destfile" ]; then
    if [ "$SKIP_EXISTING" = "yes" ]; then
      debug "Skipping (exists): $destfile"
      continue
    else
      rm -f "$destfile" || { warn "could not remove existing $destfile"; continue; }
    fi
  fi

  # Normal conversion path for a single .flac file
  convert_to_m4a "$srcfile" "$destdir"

done < <(find "$SRC" -type f -iname '*.flac' -print0)

info "All done."
