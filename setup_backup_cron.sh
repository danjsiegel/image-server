#!/bin/bash
# Setup cron job for S3 backup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_LOG="$HOME/image-server-backup-cron.log"

# Ensure log file has secure permissions
touch "$CRON_LOG"
chmod 600 "$CRON_LOG" 2>/dev/null || true

# Check if Python virtual environment exists
if [ ! -d "$SCRIPT_DIR/venv" ]; then
    echo "Error: Python virtual environment not found at $SCRIPT_DIR/venv"
    echo "Please run install_dependencies.sh first"
    exit 1
fi

# Check if boto3 is installed
if ! "$SCRIPT_DIR/venv/bin/python3" -c "import boto3" 2>/dev/null; then
    echo "Installing boto3..."
    "$SCRIPT_DIR/venv/bin/pip" install boto3 psycopg2-binary
    echo "✓ boto3 and psycopg2-binary installed"
fi

# Check if database schema exists
if ! "$SCRIPT_DIR/venv/bin/python3" -c "
import psycopg2
import os
creds_file = os.path.expanduser('~/image-server/.db_credentials')
with open(creds_file) as f:
    for line in f:
        if line.startswith('image_server:'):
            password = line.split(':', 1)[1].strip()
            break
conn = psycopg2.connect(host='localhost', database='image_server', user='image_server', password=password)
cursor = conn.cursor()
cursor.execute(\"SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 's3_backups')\")
exists = cursor.fetchone()[0]
cursor.close()
conn.close()
exit(0 if exists else 1)
" 2>/dev/null; then
    echo "Warning: s3_backups table not found"
    echo "Please run ./create_backup_schema.sh first"
    exit 1
fi

# Prompt for schedule
echo "S3 Backup Cron Setup"
echo ""
echo "How often should backups run?"
echo "1. Daily (recommended) - runs at 2 AM"
echo "2. Weekly - runs Sunday at 2 AM"
echo "3. Custom"
read -p "Choice [1-3, default: 1]: " SCHEDULE_CHOICE
SCHEDULE_CHOICE="${SCHEDULE_CHOICE:-1}"

case $SCHEDULE_CHOICE in
    1)
        CRON_SCHEDULE="0 2 * * *"
        SCHEDULE_DESC="Daily at 2 AM"
        ;;
    2)
        CRON_SCHEDULE="0 2 * * 0"
        SCHEDULE_DESC="Weekly on Sunday at 2 AM"
        ;;
    3)
        read -p "Enter cron schedule (minute hour day month weekday): " CRON_SCHEDULE
        SCHEDULE_DESC="Custom: $CRON_SCHEDULE"
        ;;
    *)
        CRON_SCHEDULE="0 2 * * *"
        SCHEDULE_DESC="Daily at 2 AM"
        ;;
esac

# Create cron job
CRON_JOB="$CRON_SCHEDULE cd $SCRIPT_DIR && source backup_config.sh && source venv/bin/activate && python3 backup_to_s3.py >> $CRON_LOG 2>&1"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "backup_to_s3.py"; then
    echo "Cron job already exists. Removing old entry..."
    crontab -l 2>/dev/null | grep -v "backup_to_s3.py" | crontab -
fi

# Add new cron job
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo ""
echo "✓ Cron job installed:"
echo "  Schedule: $SCHEDULE_DESC"
echo "  Log file: $CRON_LOG"
echo ""
echo "Current crontab:"
crontab -l
