#!/bin/bash
# Setup cron job for metadata processing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_LOG="/home/$USER/image-server-cron.log"
# Ensure log file has secure permissions
touch "$CRON_LOG"
chmod 600 "$CRON_LOG" 2>/dev/null || true

CRON_JOB="*/30 * * * * cd $SCRIPT_DIR && source venv/bin/activate && python3 process_new_images.py >> $CRON_LOG 2>&1"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "process_new_images.py"; then
    echo "Cron job already exists. Removing old entry..."
    crontab -l 2>/dev/null | grep -v "process_new_images.py" | crontab -
fi

# Add new cron job
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "Cron job installed:"
echo "  Runs every 30 minutes"
echo "  Processes new images for metadata extraction"
echo ""
echo "Current crontab:"
crontab -l

