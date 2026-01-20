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
done < <(find "$SEARCH_DIR" -type f \( \
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
\))

log "Copy complete: $copied copied, $skipped skipped"

