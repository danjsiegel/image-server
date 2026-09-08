#!/bin/bash
# Copy images from SD card - fast copy, metadata extraction happens later

set -e

SOURCE_DIR="$1"
DEST_BASE="$2"

if [ -z "$SOURCE_DIR" ] || [ -z "$DEST_BASE" ]; then
    echo "Usage: $0 <source_directory> <destination_base>"
    exit 1
fi

LOG_FILE="/home/$USER/image-server.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Storage locations
INTERNAL_IMAGES="${INTERNAL_IMAGES:-/home/$USER/images}"
EXTERNAL_IMAGES="${EXTERNAL_IMAGES:-/mnt/external-storage/images}"

# Ensure log file has secure permissions
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Create destination if it doesn't exist
mkdir -p "$DEST_BASE"

log "Starting copy from: $SOURCE_DIR"

# Find DCIM directories (standard camera folder structure)
DCIM_DIRS=$(find "$SOURCE_DIR" -type d -iname "DCIM" 2>/dev/null)

if [ -z "$DCIM_DIRS" ]; then
    log "No DCIM directory found, searching root directory"
    SEARCH_DIR="$SOURCE_DIR"
else
    # Use first DCIM directory found (most cameras have one)
    SEARCH_DIR=$(echo "$DCIM_DIRS" | head -1)
    log "Found DCIM directory: $SEARCH_DIR"
fi

# Determine other storage location for duplicate checking
OTHER_BASE=""
if [ "$DEST_BASE" = "$INTERNAL_IMAGES" ]; then
    OTHER_BASE="$EXTERNAL_IMAGES"
elif [ "$DEST_BASE" = "$EXTERNAL_IMAGES" ]; then
    OTHER_BASE="$INTERNAL_IMAGES"
fi

if [ -n "$OTHER_BASE" ] && [ ! -d "$OTHER_BASE" ]; then
    log "Other storage location not mounted: $OTHER_BASE (skipping cross-check)"
    OTHER_BASE=""
elif [ -n "$OTHER_BASE" ]; then
    log "Other storage location: $OTHER_BASE"
fi

# Collect files to copy
FILES_LIST=$(mktemp)
FNAMES_LIST=$(mktemp)
IMMICH_DUPES_FILE=$(mktemp)

find "$SEARCH_DIR" -type f \( \
    -iname "*.jpg" -o \
    -iname "*.jpeg" -o \
    -iname "*.raw" -o \
    -iname "*.raf" -o \
    -iname "*.cr2" -o \
    -iname "*.nef" -o \
    -iname "*.arw" -o \
    -iname "*.dng" -o \
    -iname "*.tif" -o \
    -iname "*.tiff" -o \
    -iname "*.png" \
\) > "$FILES_LIST"

# Extract basenames for Immich duplicate check
if [ -s "$FILES_LIST" ]; then
    awk -F/ '{print $NF}' "$FILES_LIST" > "$FNAMES_LIST"

    # Check Immich for duplicates (non-fatal if it fails)
    if [ -f "$SCRIPT_DIR/.immich_api_key" ] && [ -f "$SCRIPT_DIR/venv/bin/python3" ]; then
        log "Checking Immich for duplicates..."
        "$SCRIPT_DIR/venv/bin/python3" "$SCRIPT_DIR/check_immich_duplicates.py" "$FNAMES_LIST" > "$IMMICH_DUPES_FILE" 2>/dev/null || true
        DUPLICATE_COUNT=$(wc -l < "$IMMICH_DUPES_FILE" 2>/dev/null || echo 0)
        if [ "$DUPLICATE_COUNT" -gt 0 ]; then
            log "Found $DUPLICATE_COUNT duplicate(s) already in Immich"
        fi
    fi
fi

# Find image files in DCIM subdirectories (common formats)
# Use process substitution to avoid subshell issues with counters
copied=0
skipped=0

while IFS= read -r file; do
    
    filename=$(basename "$file")
    file_abs=$(readlink -f "$file" 2>/dev/null || echo "$file")
    
    # Organize by date from filename or current date
    # Try to extract date from filename (common formats: IMG_YYYYMMDD, DSC_YYYYMMDD, etc.)
    date_dir=""
    if [[ "$filename" =~ ([0-9]{4})([0-9]{2})([0-9]{2}) ]]; then
        year="${BASH_REMATCH[1]}"
        month="${BASH_REMATCH[2]}"
        day="${BASH_REMATCH[3]}"
        date_dir="$year/$month/$day"
    else
        # Fallback to current date
        date_dir="$(date +%Y/%m/%d)"
    fi
    
    dest_dir="$DEST_BASE/$date_dir"
    mkdir -p "$dest_dir"
    
    # Copy file
    dest_file="$dest_dir/$filename"
    
    # Check if file with this name already exists anywhere in destination
    if find "$DEST_BASE" -name "$filename" -type f | grep -q .; then
        log "Skipping (exists): $filename"
        skipped=$((skipped + 1))
        continue
    fi

    # Check if file exists in other storage location
    if [ -n "$OTHER_BASE" ] && [ -d "$OTHER_BASE" ]; then
        if find "$OTHER_BASE" -name "$filename" -type f | grep -q .; then
            log "Skipping (exists in other storage): $filename"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # Check if file exists in Immich
    if [ -f "$IMMICH_DUPES_FILE" ] && grep -qFx "$filename" "$IMMICH_DUPES_FILE"; then
        log "Skipping (exists in Immich): $filename"
        skipped=$((skipped + 1))
        continue
    fi

    # Handle filename conflicts (if file exists in this specific directory)
    counter=1
    while [ -f "$dest_file" ]; do
        name_part="${filename%.*}"
        ext_part="${filename##*.}"
        dest_file="$dest_dir/${name_part}_$counter.$ext_part"
        counter=$((counter + 1))
    done
    
    cp "$file" "$dest_file"
    log "Copied: $filename -> $dest_file"
    copied=$((copied + 1))
done < "$FILES_LIST"

rm -f "$FILES_LIST" "$FNAMES_LIST" "$IMMICH_DUPES_FILE"

log "Copy complete: $copied copied, $skipped skipped"

