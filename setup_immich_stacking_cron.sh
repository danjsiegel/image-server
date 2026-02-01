#!/bin/bash
# Setup cron job for automatic RAW+JPEG stacking
# This catches manual uploads via Immich UI that weren't processed by SD card workflow

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_LOG="$HOME/image-server-stacking.log"

echo "Setting up Immich auto-stacking cron job..."

# Check if API key exists
if [ ! -f "$SCRIPT_DIR/.immich_api_key" ]; then
    echo "WARNING: No Immich API key found at $SCRIPT_DIR/.immich_api_key"
    echo "Stacking will not work without an API key."
    echo "Create one in Immich UI → Account Settings → API Keys"
    exit 1
fi

# Check if venv exists
if [ ! -f "$SCRIPT_DIR/venv/bin/python3" ]; then
    echo "ERROR: Python virtual environment not found at $SCRIPT_DIR/venv"
    echo "Run: cd $SCRIPT_DIR && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt"
    exit 1
fi

# Create log file with secure permissions
touch "$CRON_LOG"
chmod 600 "$CRON_LOG"

# Build cron command
CRON_CMD="cd $SCRIPT_DIR && source venv/bin/activate && python3 immich_auto_stack.py >> $CRON_LOG 2>&1"

# Check if cron job already exists
CRON_EXISTS=$(crontab -l 2>/dev/null | grep -c "immich_auto_stack.py" || echo "0")

if [ "$CRON_EXISTS" -gt 0 ]; then
    echo "Cron job already exists. Updating..."
    # Remove old entries
    crontab -l 2>/dev/null | grep -v "immich_auto_stack.py" | crontab - || true
fi

# Add new cron job (runs every 2 hours)
# This is frequent enough to catch manual uploads without being too aggressive
(crontab -l 2>/dev/null; echo "0 */2 * * * $CRON_CMD") | crontab -

echo "✓ Cron job installed!"
echo ""
echo "Schedule: Every 2 hours"
echo "Log file: $CRON_LOG"
echo ""
echo "To view logs: tail -f $CRON_LOG"
echo "To test manually: cd $SCRIPT_DIR && source venv/bin/activate && python3 immich_auto_stack.py"
echo ""
echo "To remove: crontab -e (then delete the line with immich_auto_stack.py)"
