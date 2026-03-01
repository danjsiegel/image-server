#!/bin/bash
#
# setup_tailscale_funnel.sh
# Configures nginx for Tailscale Funnel with HTTPS support
# This enables Immich to generate HTTPS share links
#

set -e

# Configuration
IMMICH_DIR="$HOME/immich-app"
NGINX_CONF="$IMMICH_DIR/nginx/immich.conf"
DOCKER_COMPOSE="$IMMICH_DIR/docker-compose.yml"
SSL_DIR="$IMMICH_DIR/nginx/ssl"
SSL_CERT="$SSL_DIR/immich.crt"
SSL_KEY="$SSL_DIR/immich.key"

echo "=============================================="
echo "  Tailscale Funnel Setup for Immich"
echo "=============================================="
echo ""

# Check if Immich directory exists
if [ ! -d "$IMMICH_DIR" ]; then
    echo "ERROR: Immich directory not found at $IMMICH_DIR"
    echo "Please ensure Immich is installed first."
    exit 1
fi

# Get Tailscale domain
echo "Step 0: Getting Tailscale domain..."
TAILSCALE_DOMAIN="${TAILSCALE_FUNNEL_DOMAIN:-}"

if [ -z "$TAILSCALE_DOMAIN" ]; then
    # Try to get from tailscale status
    TAILSCALE_DOMAIN=$(tailscale status --json 2>/dev/null | grep -oP '"HostName":"\K[^"]+' | head -1)
    if [ -z "$TAILSCALE_DOMAIN" ]; then
        TAILSCALE_DOMAIN=$(tailscale ip -4 2>/dev/null | head -1)
    fi
fi

if [ -n "$TAILSCALE_DOMAIN" ]; then
    echo "  Found Tailscale domain: $TAILSCALE_DOMAIN"
    read -p "Use this domain? [Y/n]: " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo "Enter your Tailscale domain (e.g., dell-image-server.tailxxxx.ts.net):"
        read TAILSCALE_DOMAIN
    fi
else
    echo "Enter your Tailscale domain (e.g., dell-image-server.tailxxxx.ts.net):"
    read TAILSCALE_DOMAIN
fi

if [ -z "$TAILSCALE_DOMAIN" ]; then
    echo "ERROR: No Tailscale domain provided"
    exit 1
fi

echo ""
echo "Step 1: Checking nginx configuration..."

# Create nginx config with HTTP→HTTPS redirect and X-Forwarded-Proto fix
cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name $TAILSCALE_DOMAIN;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $TAILSCALE_DOMAIN;

    ssl_certificate /etc/nginx/ssl/immich.crt;
    ssl_certificate_key /etc/nginx/ssl/immich.key;

    client_max_body_size 50000M;

    # Immich mobile app discovery endpoint
    location = /.well-known/immich {
        proxy_pass http://immich-server:2283;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://immich-server:2283;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        # CRITICAL: Force Immich to generate HTTPS share links
        proxy_set_header X-Forwarded-Proto https;
        proxy_cache_bypass $http_upgrade;
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
    }
}
EOF

echo "  ✓ Updated nginx config with:"
echo "    - HTTP→HTTPS redirect (port 80)"
echo "    - X-Forwarded-Proto https header"

# Update docker-compose.yml to map port 80
echo ""
echo "Step 2: Updating docker-compose.yml for port 80..."

if [ -f "$DOCKER_COMPOSE" ]; then
    # Use python to update docker-compose
    python3 << PYTHON_SCRIPT
import yaml

with open('$DOCKER_COMPOSE', 'r') as f:
    data = yaml.safe_load(f)

if 'nginx' in data.get('services', {}):
    # Update ports to include 80:80
    ports = data['services']['nginx'].get('ports', [])
    ports_str = [str(p) for p in ports]
    
    # Remove existing port mappings
    ports = []
    
    # Add 80:80 for HTTP redirect
    if '80:80' not in ports_str:
        ports.append('80:80')
    
    # Add 443:443 for HTTPS
    if '443:443' not in ports_str:
        ports.append('443:443')
    
    data['services']['nginx']['ports'] = ports
    
    with open('$DOCKER_COMPOSE', 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
    
    print("  ✓ Updated docker-compose.yml with ports 80:80 and 443:443")
else:
    print("  WARNING: docker-compose.yml not found")
PYTHON_SCRIPT
else
    echo "  WARNING: docker-compose.yml not found at $DOCKER_COMPOSE"
fi

echo ""
echo "Step 3: Checking SSL certificates..."
# Generate self-signed SSL cert if needed
if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
    echo "  Generating self-signed SSL certificate..."
    mkdir -p "$SSL_DIR"
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=$TAILSCALE_DOMAIN" \
        2>/dev/null
        
    echo "  ✓ Self-signed certificate generated"
else
    echo "  ✓ SSL certificate already exists"
fi

echo ""
echo "Step 4: Restarting containers..."
cd "$IMMICH_DIR"

# Check if nginx container exists
if docker ps -a --format '{{.Names}}' | grep -q "immich-nginx"; then
    # Restart nginx only
    docker restart immich-nginx
    echo "  ✓ Nginx container restarted"
else
    # Start nginx (and any other stopped containers)
    docker compose up -d nginx
    echo "  ✓ Nginx container started"
fi

echo ""
echo "=============================================="
echo "  Setup Complete!"
echo "=============================================="
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Enable Tailscale Funnel:"
echo "   sudo tailscale funnel --bg 443"
echo ""
echo "2. Verify Funnel is working:"
echo "   tailscale funnel status"
echo ""
echo "3. Set External Domain in Immich:"
echo "   Go to Administration → Settings → Server Settings"
echo "   Set 'External Domain' to: https://$TAILSCALE_DOMAIN"
echo ""
echo "4. Test share links:"
echo "   - Create a share link in Immich"
echo "   - Verify it generates an HTTPS URL"
echo ""
