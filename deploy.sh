#!/bin/bash
# Deploy image server scripts to Dell laptop

set -e

REMOTE_HOST="${REMOTE_HOST:-your-server-hostname}"
REMOTE_USER="${REMOTE_USER:-yourusername}"
REMOTE_DIR="/home/$REMOTE_USER/image-server"

echo "Deploying image server scripts to $REMOTE_HOST..."

# Create remote directory
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

# Copy all scripts and config files
echo "Copying files..."
scp install_dependencies.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp install_immich.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp setup_database.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp create_schema.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp create_schema.sql "$REMOTE_HOST:$REMOTE_DIR/"
scp setup_cron.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp copy_from_sd.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp sd_card_monitor.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp udev_sd_card_wrapper.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp udev_sd_card.rules "$REMOTE_HOST:$REMOTE_DIR/"
scp db_config.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp config.sh "$REMOTE_HOST:$REMOTE_DIR/"
scp test_metadata.py "$REMOTE_HOST:$REMOTE_DIR/"
scp process_new_images.py "$REMOTE_HOST:$REMOTE_DIR/"
scp image-server-logrotate "$REMOTE_HOST:$REMOTE_DIR/"

# Make scripts executable
ssh "$REMOTE_HOST" "chmod +x $REMOTE_DIR/*.sh $REMOTE_DIR/*.py 2>/dev/null || true"

echo ""
echo "✓ Files deployed to $REMOTE_HOST:$REMOTE_DIR"
echo ""
echo "Next steps:"
echo "1. SSH to the server: ssh $REMOTE_HOST"
echo "2. Run: $REMOTE_DIR/install_dependencies.sh"
echo "3. Set up udev rules (see README)"
echo ""

