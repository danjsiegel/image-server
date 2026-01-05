#!/bin/bash
# Set up services to start automatically on boot

set -e

echo "=== Setting up auto-start on boot ==="

# Enable PostgreSQL to start on boot
echo "Enabling PostgreSQL..."
sudo systemctl enable postgresql
sudo systemctl start postgresql

# Enable Docker to start on boot
echo "Enabling Docker..."
sudo systemctl enable docker
sudo systemctl start docker

# Create systemd service for Immich
echo "Creating Immich systemd service..."
IMMICH_DIR="$HOME/immich-app"
SERVICE_FILE="/etc/systemd/system/immich.service"

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Immich Photo Management
Requires=docker.service
After=docker.service postgresql.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$IMMICH_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
User=$USER
Group=docker

[Install]
WantedBy=multi-user.target
EOF

# Enable the Immich service
sudo systemctl daemon-reload
sudo systemctl enable immich.service

echo ""
echo "=== Auto-start Configuration Complete ==="
echo ""
echo "Services configured to start on boot:"
echo "  ✓ PostgreSQL (systemd)"
echo "  ✓ Docker (systemd)"
echo "  ✓ Immich (systemd service)"
echo ""
echo "Other services:"
echo "  ✓ udev rules (persistent, no action needed)"
echo "  ✓ Cron jobs (persistent, no action needed)"
echo ""
echo "To check status:"
echo "  systemctl status immich"
echo "  docker compose -f ~/immich-app/docker-compose.yml ps"
echo ""
echo "To manually start/stop Immich:"
echo "  sudo systemctl start immich"
echo "  sudo systemctl stop immich"

