#!/bin/bash
# Wrapper script for udev to run sd_card_monitor.sh as the user

# Load configuration - try common locations
CONFIG_FILE=""
# Try to find config.sh in common locations
for path in "/home/$SUDO_USER/image-server/config.sh" "/home/$USER/image-server/config.sh" "$HOME/image-server/config.sh" "/home/*/image-server/config.sh"; do
    if [ -f "$path" ]; then
        CONFIG_FILE="$path"
        break
    fi
done

if [ -n "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    # Fallback if config doesn't exist yet - use current user
    export IMAGE_SERVER_USER="${SUDO_USER:-$USER}"
    export IMAGE_SERVER_HOME="/home/$IMAGE_SERVER_USER"
fi

# Log udev execution
UDEV_LOG="/tmp/udev_sd_card.log"
touch "$UDEV_LOG"
chmod 600 "$UDEV_LOG" 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Udev triggered for device: $1" >> "$UDEV_LOG"

# Export environment variables that might be needed
export USER="$IMAGE_SERVER_USER"
export HOME="$IMAGE_SERVER_HOME"

# Run the monitor script as the specified user using runuser (no password needed)
# Redirect both stdout and stderr to log file to see any errors
runuser -l "$IMAGE_SERVER_USER" -c "$IMAGE_SERVER_HOME/image-server/sd_card_monitor.sh" >> "$UDEV_LOG" 2>&1 &
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Started runuser command (PID: $!)" >> "$UDEV_LOG"

exit 0

