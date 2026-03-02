#!/bin/bash
# Install Docker, Immich, and configure it to use existing PostgreSQL

set -e

echo "=== Installing Docker ==="

# Install Docker
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
    
    # Add user to docker group
    sudo usermod -aG docker $USER
    echo "Added $USER to docker group. You may need to log out and back in."
else
    echo "Docker is already installed"
fi

# Install Docker Compose plugin (v2)
if ! docker compose version &> /dev/null; then
    echo "Docker Compose plugin should be included with Docker. If not, install manually."
else
    echo "Docker Compose is available"
fi

echo ""
echo "=== Setting up Immich ==="

# Create Immich directory
IMMICH_DIR="$HOME/immich-app"
mkdir -p "$IMMICH_DIR"
cd "$IMMICH_DIR"

# Download docker-compose.yml
if [ ! -f "docker-compose.yml" ]; then
    echo "Downloading Immich docker-compose.yml..."
    wget -O docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
else
    echo "docker-compose.yml already exists"
fi

# Download .env template
if [ ! -f ".env" ]; then
    echo "Downloading Immich .env template..."
    wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env
else
    echo ".env already exists, backing up..."
    cp .env .env.backup
fi

echo ""
echo "=== Configuring Immich ==="

# Load database credentials
DB_PASSWORD=$(grep "image_server:" ~/image-server/.db_credentials | cut -d: -f2 | tr -d ' ')

if [ -z "$DB_PASSWORD" ]; then
    echo "Error: Could not find database password in ~/image-server/.db_credentials"
    exit 1
fi

# Get host IP for Docker connection
HOST_IP=$(hostname -I | awk '{print $1}')

# Update .env file
echo "Configuring .env file..."

# Set upload location to separate directory (NOT in ~/images mount)
# Immich will store thumbnails, encoded videos, profiles here - separate from source images
sed -i "s|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/home/$USER/immich-library|" .env

# Create immich library directory and required subdirectories
mkdir -p "$HOME/immich-library/{library,thumbs,upload,backups,profile,encoded-video}"
# Create .immich marker files that Immich expects
touch "$HOME/immich-library/library/.immich"
touch "$HOME/immich-library/thumbs/.immich"
touch "$HOME/immich-library/upload/.immich"
touch "$HOME/immich-library/backups/.immich"
touch "$HOME/immich-library/profile/.immich"
touch "$HOME/immich-library/encoded-video/.immich"
echo "✓ Created Immich library directory structure: $HOME/immich-library"

# Configure to use external PostgreSQL
sed -i "s|DB_USERNAME=.*|DB_USERNAME=image_server|" .env
sed -i "s|DB_DATABASE_NAME=.*|DB_DATABASE_NAME=immich|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASSWORD|" .env

# Add DB_URL for external PostgreSQL connection
DB_URL="postgresql://image_server:$DB_PASSWORD@172.17.0.1:5432/immich"
if grep -q "^DB_URL=" .env; then
    sed -i "s|^DB_URL=.*|DB_URL='$DB_URL'|" .env
else
    echo "" >> .env
    echo "# External PostgreSQL database connection" >> .env
    echo "DB_URL='$DB_URL'" >> .env
fi

# Secure .env file permissions
chmod 600 .env
echo "✓ .env configured and secured (chmod 600)"

# Modify docker-compose.yml to remove postgres service
echo ""
echo "Modifying docker-compose.yml..."

# Remove database service and dependency using Python
python3 << PYTHON_SCRIPT
import yaml
import os

with open('docker-compose.yml', 'r') as f:
    data = yaml.safe_load(f)

# Remove database service
if 'database' in data.get('services', {}):
    del data['services']['database']

# Remove database from depends_on in immich-server
if 'immich-server' in data.get('services', {}):
    if 'depends_on' in data['services']['immich-server']:
        deps = data['services']['immich-server']['depends_on']
        if isinstance(deps, list) and 'database' in deps:
            deps.remove('database')

# Configure volume mounts for immich-server
# Uses home directory from environment
if 'immich-server' in data.get('services', {}):
    volumes = data['services']['immich-server'].get('volumes', [])
    
    # Add read-write mount for external library (existing images)
    # Read-write allows Immich to delete files when photos are removed
    images_path = os.path.expanduser('~/images')
    # Remove any existing /mnt/images mount (including read-only ones)
    volumes = [v for v in volumes if '/mnt/images' not in str(v)]
    # Add read-write mount
    volumes.append(f'{images_path}:/mnt/images')
    
    # Update Immich's library/upload volume to point to separate directory (NOT in ~/images)
    # This prevents Immich from writing thumbnails/encoded videos into the main images directory
    immich_library_path = os.path.expanduser('~/immich-library')
    # Find and replace any existing upload volume mounts
    # Immich needs the entire upload directory mounted, not just library subdirectory
    new_volumes = []
    upload_mount_found = False
    for vol in volumes:
        vol_str = str(vol)
        # Check if this is an upload mount (container path contains /usr/src/app/upload)
        if ':/usr/src/app/upload' in vol_str:
            # Replace with entire immich library directory mount
            new_volumes.append(f'{immich_library_path}:/usr/src/app/upload')
            upload_mount_found = True
        else:
            # Keep other volumes (including /mnt/images read-write mount)
            new_volumes.append(vol)
    
    # If no upload mount was found, add it
    if not upload_mount_found:
        new_volumes.append(f'{immich_library_path}:/usr/src/app/upload')
    
    volumes = new_volumes
    
    data['services']['immich-server']['volumes'] = volumes
    
    # Remove port 2283 exposure for security (only accessible via nginx)
    if 'ports' in data['services']['immich-server']:
        ports = data['services']['immich-server']['ports']
        data['services']['immich-server']['ports'] = [
            p for p in ports if ':2283' not in str(p) and '2283:' not in str(p)
        ]
        if not data['services']['immich-server']['ports']:
            del data['services']['immich-server']['ports']

with open('docker-compose.yml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print("✓ docker-compose.yml updated")
PYTHON_SCRIPT

echo ""
echo "=== Database Setup ==="
echo "Creating immich database and granting permissions..."

# Create database and grant superuser (so Immich can create extensions)
sudo -u postgres psql <<EOF
-- Create database if it doesn't exist
SELECT 1 FROM pg_database WHERE datname='immich' 
\gexec
\if :ROW_COUNT = 0
CREATE DATABASE immich OWNER image_server;
\endif

-- Grant superuser so Immich can create extensions
ALTER USER image_server WITH SUPERUSER;
EOF

echo "✓ Database configured"

echo ""
echo "=== PostgreSQL Network Access ==="
echo "Configuring PostgreSQL to allow Docker network connections..."

# Get Docker network subnet
DOCKER_SUBNET=$(docker network inspect bridge 2>/dev/null | grep -A 5 Subnet | grep Subnet | head -1 | awk -F'"' '{print $4}' || echo "172.17.0.0/16")

# Add Docker network to pg_hba.conf if not already there
PG_VERSION=$(psql --version | grep -oP '\d+' | head -1)
PG_HBA_FILE="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"

if ! sudo grep -q "$DOCKER_SUBNET" "$PG_HBA_FILE" 2>/dev/null; then
    # Use scram-sha-256 for better security (if supported) or md5 as fallback
    if [ "$PG_VERSION" -ge 10 ]; then
        AUTH_METHOD="scram-sha-256"
    else
        AUTH_METHOD="md5"
    fi
    
    echo "host all all $DOCKER_SUBNET $AUTH_METHOD" | sudo tee -a "$PG_HBA_FILE"
    echo "✓ Added Docker network to pg_hba.conf with $AUTH_METHOD authentication"
    
    # Verify pg_hba.conf permissions (should be 0640)
    sudo chmod 640 "$PG_HBA_FILE"
    sudo chown postgres:postgres "$PG_HBA_FILE"
    
    sudo systemctl restart postgresql
else
    echo "✓ Docker network already configured in pg_hba.conf"
fi

# Verify PostgreSQL is only listening on localhost (security best practice)
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
if sudo grep -q "^listen_addresses = '\*'" "$PG_CONF" 2>/dev/null; then
    echo "⚠ Warning: PostgreSQL is listening on all interfaces (*)"
    echo "  Consider changing to 'localhost' in $PG_CONF for better security"
elif sudo grep -q "^listen_addresses = 'localhost'" "$PG_CONF" 2>/dev/null || ! sudo grep -q "^listen_addresses" "$PG_CONF" 2>/dev/null; then
    echo "✓ PostgreSQL listening on localhost only (secure)"
fi

echo ""
echo "=== Nginx Reverse Proxy with Tailscale Funnel ==="

# Check for environment variables
SETUP_NGINX="${SETUP_NGINX:-}"
NGINX_DOMAIN="${NGINX_DOMAIN:-}"

if [ -z "$SETUP_NGINX" ]; then
    read -p "Set up nginx reverse proxy with Tailscale Funnel? (y/n) " SETUP_NGINX
fi

if [ "$SETUP_NGINX" = "y" ] || [ "$SETUP_NGINX" = "Y" ]; then
    export SETUP_NGINX NGINX_DOMAIN

    if [ -z "$NGINX_DOMAIN" ]; then
        echo ""
        echo "Enter your Tailscale hostname:"
        read -p "Domain (e.g., yourmachine.tail012345.ts.net): " NGINX_DOMAIN
        export NGINX_DOMAIN
    fi

    if [ -n "$NGINX_DOMAIN" ]; then
        NGINX_CONF_DIR="$IMMICH_DIR/nginx"
        mkdir -p "$NGINX_CONF_DIR"

        echo "Writing nginx config..."
        cat > "$NGINX_CONF_DIR/immich.conf" << NGINXEOF
server {
    listen 8080;
    server_name ${NGINX_DOMAIN};

    client_max_body_size 50000M;

    # Trust Docker bridge gateway so X-Forwarded-For is unwrapped correctly
    set_real_ip_from 172.16.0.0/12;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

    # Block search/faces/people for public users
    location ~ ^/(search|api/search|api/faces|api/people) {
        allow 100.64.0.0/10;
        deny all;

        proxy_pass http://immich-server:2283;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    # Public - share pages and API (Immich handles its own auth on API calls)
    location ~ ^/(share|_app|api|service-worker.js|favicon.ico) {
        proxy_pass http://immich-server:2283;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 600;
        proxy_send_timeout 600;
        proxy_connect_timeout 600;
    }

    # Private - Tailscale VPN only (100.64.0.0/10 is the entire Tailscale address space)
    location / {
        allow 100.64.0.0/10;
        deny all;

        proxy_pass http://immich-server:2283;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 600;
        proxy_send_timeout 600;
        proxy_connect_timeout 600;
    }
}
NGINXEOF
        echo "✓ nginx config written to $NGINX_CONF_DIR/immich.conf"

        # Add nginx service to docker-compose
        python3 << PYTHON_NGINX
import yaml
import os

with open('docker-compose.yml', 'r') as f:
    data = yaml.safe_load(f)

nginx_conf_dir = os.path.expanduser('~/immich-app/nginx')

data['services']['nginx'] = {
    'image': 'nginx:alpine',
    'container_name': 'immich-nginx',
    'ports': ['127.0.0.1:8080:8080'],
    'volumes': [
        f'{nginx_conf_dir}/immich.conf:/etc/nginx/conf.d/default.conf:ro',
    ],
    'depends_on': ['immich-server'],
    'restart': 'unless-stopped'
}

with open('docker-compose.yml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print("✓ Added nginx service to docker-compose.yml")
PYTHON_NGINX

        echo ""
        echo "=== Tailscale Funnel Setup ==="
        echo "Configuring Tailscale Funnel to forward HTTPS traffic to nginx..."
        if command -v tailscale &> /dev/null; then
            sudo tailscale funnel reset 2>/dev/null || true
            sudo tailscale funnel --bg --https=443 http://127.0.0.1:8080
            echo "✓ Tailscale Funnel configured: https://$NGINX_DOMAIN → localhost:8080"
        else
            echo "⚠ Tailscale not found. Run manually after install:"
            echo "  sudo tailscale funnel --bg --https=443 http://127.0.0.1:8080"
        fi

        echo "✓ Nginx reverse proxy configured"
        echo "  Share links available at: https://$NGINX_DOMAIN/share/..."
        echo "  Full UI (VPN only) at:    https://$NGINX_DOMAIN"
    fi
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Immich is configured to:"
echo "  - Use existing PostgreSQL database: immich"
echo "  - Immich library (thumbnails, encoded videos, etc.): /home/$USER/immich-library"
echo "  - Access existing source images via: /mnt/images (read-write, points to ~/images)"
echo ""
echo "Next steps:"
echo "1. Log out and back in (or run: newgrp docker) for docker group to take effect"
echo "2. Start Immich: cd ~/immich-app && docker compose up -d"
if [ "$SETUP_NGINX" = "y" ] || [ "$SETUP_NGINX" = "Y" ]; then
    echo "3. VPN access:    https://$NGINX_DOMAIN"
    echo "   Share links:   https://$NGINX_DOMAIN/share/..."
else
    echo "3. Access at: http://localhost:2283 or http://$(hostname -I | awk '{print $1}'):2283"
fi
echo "4. Create your admin account"
echo "5. Set up external library in Immich UI: Administration -> External Libraries"
echo "   - Add import path: /mnt/images"
echo "6. On shared links: disable 'Show metadata' in the share settings to prevent"
echo "   public users from seeing EXIF data on shared photos"
echo ""
echo "Note: If PostgreSQL fails to start, check /etc/postgresql/16/main/postgresql.conf"
echo "      and remove any vchord.so references if VectorChord isn't installed."
