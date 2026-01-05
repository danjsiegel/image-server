#!/bin/bash
# SD Card Monitor - watches for SD card insertion and triggers copy

set -e

# Configuration
SOURCE_MOUNT="/media/$USER"
INTERNAL_IMAGES="/home/$USER/images"
EXTERNAL_IMAGES="/mnt/external-storage/images"
MIN_FREE_SPACE_GB=10
LOG_FILE="/home/$USER/image-server.log"
LOCK_FILE="/tmp/sd_card_copy.lock"

# Ensure log file has secure permissions
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if another copy is in progress
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$PID" ] && ps -p "$PID" > /dev/null 2>&1; then
        log "Copy already in progress (PID: $PID), skipping..."
        exit 0
    else
        # Stale lock file - try to remove it (may need sudo if created by root)
        sudo rm -f "$LOCK_FILE" 2>/dev/null || rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
fi

# Create lock file
echo $$ > "$LOCK_FILE" 2>/dev/null || sudo sh -c "echo $$ > $LOCK_FILE" || {
    log "Warning: Could not create lock file"
}

# Wait for mount to complete (udev triggers before mount)
sleep 2

# Find the SD card mount point - try multiple times
SD_MOUNT=""
for i in {1..10}; do
    SD_MOUNT=$(findmnt -n -o TARGET --source /dev/sdc1 2>/dev/null || findmnt -n -o TARGET --source /dev/mmcblk0p1 2>/dev/null || echo "")
    
    if [ -z "$SD_MOUNT" ]; then
        # Try to find any mounted SD card in /media
        SD_MOUNT=$(lsblk -o MOUNTPOINT | grep '/media' | head -1 | xargs)
    fi
    
    if [ -n "$SD_MOUNT" ] && [ -d "$SD_MOUNT" ]; then
        break
    fi
    
    sleep 1
done

if [ -z "$SD_MOUNT" ] || [ ! -d "$SD_MOUNT" ]; then
    log "No SD card found mounted after waiting"
    rm -f "$LOCK_FILE"
    exit 0
fi

log "SD card detected at: $SD_MOUNT"

# Check available space on internal drive and choose destination
if [ -d "$INTERNAL_IMAGES" ]; then
    # Get available space in GB (df -BG outputs in GB, extract number)
    AVAILABLE_SPACE=$(df -BG "$INTERNAL_IMAGES" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//' || echo "0")
    
    # Handle case where df might return non-numeric (e.g., if filesystem doesn't exist)
    if ! [[ "$AVAILABLE_SPACE" =~ ^[0-9]+$ ]]; then
        AVAILABLE_SPACE=0
    fi
    
    if [ "$AVAILABLE_SPACE" -lt "$MIN_FREE_SPACE_GB" ]; then
        log "Internal drive low on space (${AVAILABLE_SPACE}GB free < ${MIN_FREE_SPACE_GB}GB), using external drive"
        DEST_BASE="$EXTERNAL_IMAGES"
        # Create external directory if it doesn't exist
        sudo mkdir -p "$EXTERNAL_IMAGES" 2>/dev/null || true
        sudo chown $USER:$USER "$EXTERNAL_IMAGES" 2>/dev/null || true
    else
        log "Using internal drive (${AVAILABLE_SPACE}GB free)"
        DEST_BASE="$INTERNAL_IMAGES"
    fi
else
    # Internal images directory doesn't exist, use it anyway (will be created)
    log "Using internal drive (directory will be created)"
    DEST_BASE="$INTERNAL_IMAGES"
fi

log "Destination: $DEST_BASE"

# Run the copy script
SCRIPT_DIR="/home/$USER/image-server"
"$SCRIPT_DIR/copy_from_sd.sh" "$SD_MOUNT" "$DEST_BASE"

# Eject the SD card - find the device from mount point
SD_DEVICE=$(findmnt -n -o SOURCE --target "$SD_MOUNT" 2>/dev/null | head -1)
if [ -z "$SD_DEVICE" ]; then
    # Fallback: get device from lsblk
    SD_DEVICE=$(lsblk -o NAME,MOUNTPOINT | grep "$SD_MOUNT" | awk '{print "/dev/"$1}' | head -1)
fi

log "Ejecting SD card at $SD_MOUNT (device: $SD_DEVICE)..."
# Try umount first (more reliable), then eject
umount "$SD_MOUNT" 2>/dev/null || sudo umount "$SD_MOUNT" 2>/dev/null || true
if [ -n "$SD_DEVICE" ]; then
    eject "$SD_DEVICE" 2>/dev/null || true
fi

log "SD card processing complete and ejected"

# Remove lock (may need sudo if created by root)
sudo rm -f "$LOCK_FILE" 2>/dev/null || rm -f "$LOCK_FILE" 2>/dev/null || true

# Send notification (if notify-send is available and DISPLAY is set)
if [ -n "$DISPLAY" ] && command -v notify-send > /dev/null; then
    notify-send "Image Server" "SD card processed and ejected successfully" 2>/dev/null || true
fi

