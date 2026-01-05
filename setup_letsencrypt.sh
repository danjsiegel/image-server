#!/bin/bash
# Set up Let's Encrypt certificate using Tailscale's built-in cert command
# Follows: https://tailscale.com/kb/1153/enabling-https

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <domain>"
    echo "Example: $0 yourmachine.tail0xxxx.ts.net"
    exit 1
fi

DOMAIN="$1"
IMMICH_DIR="$HOME/immich-app"
NGINX_CONF="$IMMICH_DIR/nginx/immich.conf"
CERT_DIR="/var/lib/tailscale/cert"

echo "=== Setting up Let's Encrypt using Tailscale cert ==="
echo ""
echo "Prerequisites:"
echo "1. Enable HTTPS in Tailscale admin console:"
echo "   - Go to: https://login.tailscale.com/admin/dns"
echo "   - Enable MagicDNS (if not already enabled)"
echo "   - Under 'HTTPS Certificates', click 'Enable HTTPS'"
echo "   - Acknowledge the public ledger notice"
echo ""
read -p "Have you enabled HTTPS in the Tailscale admin console? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Please enable HTTPS in the Tailscale admin console first, then run this script again."
    exit 1
fi

# Get certificate using Tailscale's built-in command
# tailscale cert writes files to the current directory
echo ""
echo "Requesting certificate from Tailscale..."
CURRENT_DIR=$(pwd)
sudo tailscale cert "$DOMAIN" || {
    echo "⚠ Failed to get certificate. Make sure:"
    echo "  1. HTTPS is enabled in Tailscale admin console"
    echo "  2. MagicDNS is enabled"
    echo "  3. You're using the correct domain name"
    exit 1
}

# tailscale cert writes to current directory
CERT_FILE="$CURRENT_DIR/$DOMAIN.crt"
KEY_FILE="$CURRENT_DIR/$DOMAIN.key"

if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "⚠ Certificate files not found"
    echo "   Expected: $CERT_FILE and $KEY_FILE"
    exit 1
fi

# Create cert directory and move certificates there
sudo mkdir -p "$CERT_DIR"
sudo mv "$CERT_FILE" "$CERT_DIR/"
sudo mv "$KEY_FILE" "$CERT_DIR/"

CERT_FILE="$CERT_DIR/$DOMAIN.crt"
KEY_FILE="$CERT_DIR/$DOMAIN.key"

# Set proper permissions (readable by nginx user in container)
sudo chmod 644 "$CERT_FILE"
sudo chmod 600 "$KEY_FILE"
sudo chown root:root "$CERT_FILE" "$KEY_FILE"

# Update nginx config to use Tailscale certificates
echo "Updating nginx configuration..."
sed -i "s|ssl_certificate /etc/nginx/ssl/immich.crt;|ssl_certificate /etc/tailscale/cert/$DOMAIN.crt;|" "$NGINX_CONF"
sed -i "s|ssl_certificate_key /etc/nginx/ssl/immich.key;|ssl_certificate_key /etc/tailscale/cert/$DOMAIN.key;|" "$NGINX_CONF"

# Update docker-compose to mount Tailscale cert directory
cd "$IMMICH_DIR"
python3 << PYTHON
import yaml

with open('docker-compose.yml', 'r') as f:
    data = yaml.safe_load(f)

if 'nginx' in data.get('services', {}):
    volumes = data['services']['nginx'].get('volumes', [])
    # Remove old ssl mount, add Tailscale cert mount
    volumes = [v for v in volumes if '/etc/nginx/ssl' not in str(v) and '/etc/letsencrypt' not in str(v)]
    volumes.append('$CERT_DIR:/etc/tailscale/cert:ro')
    data['services']['nginx']['volumes'] = volumes
    
    with open('docker-compose.yml', 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
    print("✓ Updated docker-compose.yml to use Tailscale certificates")
PYTHON

# Set up auto-renewal (certificates expire in 90 days)
echo "Setting up auto-renewal..."
(crontab -l 2>/dev/null | grep -v "tailscale cert.*$DOMAIN"; \
 echo "0 3 * * * cd $CERT_DIR && sudo tailscale cert $DOMAIN && sudo mv $DOMAIN.crt $CERT_DIR/ && sudo mv $DOMAIN.key $CERT_DIR/ && sudo chmod 644 $CERT_DIR/$DOMAIN.crt && sudo chmod 600 $CERT_DIR/$DOMAIN.key && cd $IMMICH_DIR && docker compose restart nginx") | crontab -

# Restart nginx
docker compose restart nginx

echo ""
echo "✓ Tailscale certificate installed!"
echo "✓ Certificate location: $CERT_FILE"
echo "✓ Auto-renewal configured (runs daily at 3 AM)"
echo ""
echo "Your Immich instance now has a trusted SSL certificate from Tailscale!"
echo "The mobile app should work without certificate warnings."
echo ""
echo "Note: Certificates expire in 90 days. The cron job will auto-renew them."

