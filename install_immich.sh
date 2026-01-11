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
DB_URL="postgresql://image_server:$DB_PASSWORD@$HOST_IP:5432/immich"
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
echo "=== Optional: Nginx Reverse Proxy with HTTPS ==="

# Check for environment variables
SETUP_NGINX="${SETUP_NGINX:-}"
NGINX_DOMAIN="${NGINX_DOMAIN:-}"
NGINX_SSL_TYPE="${NGINX_SSL_TYPE:-}"

if [ -z "$SETUP_NGINX" ]; then
    read -p "Set up nginx reverse proxy with HTTPS? (y/n) " SETUP_NGINX
fi

if [ "$SETUP_NGINX" = "y" ] || [ "$SETUP_NGINX" = "Y" ]; then
    # Export variables for Python script
    export SETUP_NGINX NGINX_DOMAIN
    
    # Get domain/hostname before modifying docker-compose
    if [ -z "$NGINX_DOMAIN" ]; then
        echo ""
        echo "Enter your domain name or Tailscale hostname:"
        read -p "Domain (e.g., yourmachinea.tail012354.ts.net): " NGINX_DOMAIN
        export NGINX_DOMAIN
    fi
    
    if [ -n "$NGINX_DOMAIN" ]; then
        # SSL certificate choice (do this first so certs exist when creating config)
        if [ -z "$NGINX_SSL_TYPE" ]; then
            echo ""
            echo "SSL certificate options:"
            echo "1. Let's Encrypt (requires publicly accessible domain)"
            echo "2. Self-signed (for Tailscale/testing)"
            read -p "Choice [1 or 2]: " NGINX_SSL_TYPE
        fi
        
        # Create SSL directory and generate certificates if needed
        mkdir -p "$IMMICH_DIR/nginx/ssl"
        
        if [ "$NGINX_SSL_TYPE" = "1" ]; then
            echo ""
            echo "Setting up Let's Encrypt certificate..."
            
            # Install certbot on host
            if ! command -v certbot &> /dev/null; then
                sudo apt-get update
                sudo apt-get install -y certbot
            fi
            
            # Temporarily add HTTP server block for Let's Encrypt validation
            # We'll need port 80 for validation
            python3 << PYTHON_LE
import yaml
import os

with open('docker-compose.yml', 'r') as f:
    data = yaml.safe_load(f)

# Temporarily add port 80 to nginx for Let's Encrypt
if 'nginx' in data.get('services', {}):
    ports = data['services']['nginx'].get('ports', [])
    if '80:80' not in [str(p) for p in ports]:
        ports.append('80:80')
        data['services']['nginx']['ports'] = ports

with open('docker-compose.yml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
PYTHON_LE
            
            # Update nginx config to include HTTP server for Let's Encrypt
            nginx_conf_dir="$IMMICH_DIR/nginx"
            # HTTP block removed - using HTTPS only
            
            # Restart nginx with port 80
            cd "$IMMICH_DIR"
            docker compose up -d nginx
            
            # Use Tailscale Funnel or direct access for validation
            echo ""
            echo "For Let's Encrypt validation with Tailscale:"
            echo "Option 1: Use Tailscale Funnel (recommended)"
            echo "  Run: tailscale funnel --bg 80"
            echo "  Then run certbot (will be done automatically)"
            echo ""
            echo "Option 2: Make server publicly accessible on port 80"
            echo ""
            read -p "Have you enabled Tailscale Funnel or made port 80 accessible? (y/n) " FUNNEL_READY
            
            if [ "$FUNNEL_READY" = "y" ] || [ "$FUNNEL_READY" = "Y" ]; then
                # Create certbot webroot directory
                sudo mkdir -p /var/www/certbot
                
                # Get certificate
                sudo certbot certonly --webroot \
                    -w /var/www/certbot \
                    -d "$NGINX_DOMAIN" \
                    --email "${USER}@${NGINX_DOMAIN}" \
                    --agree-tos \
                    --non-interactive || {
                    echo "⚠ Certbot failed. You may need to:"
                    echo "  1. Enable Tailscale Funnel: tailscale funnel --bg 80"
                    echo "  2. Or make your server publicly accessible on port 80"
                    echo "  3. Then re-run this script"
                    NGINX_SSL_TYPE="2"
                }
                
                if [ "$NGINX_SSL_TYPE" != "2" ] && [ -f "/etc/letsencrypt/live/$NGINX_DOMAIN/fullchain.pem" ]; then
                    # Copy certificates to nginx directory
                    sudo cp /etc/letsencrypt/live/$NGINX_DOMAIN/fullchain.pem "$nginx_conf_dir/ssl/immich.crt"
                    sudo cp /etc/letsencrypt/live/$NGINX_DOMAIN/privkey.pem "$nginx_conf_dir/ssl/immich.key"
                    sudo chown $USER:$USER "$nginx_conf_dir/ssl/"*.{crt,key}
                    
                    # Update nginx config to use Let's Encrypt certs
                    sed -i "s|ssl_certificate /etc/nginx/ssl/immich.crt;|ssl_certificate /etc/letsencrypt/live/$NGINX_DOMAIN/fullchain.pem;|" "$nginx_conf_dir/immich.conf"
                    sed -i "s|ssl_certificate_key /etc/nginx/ssl/immich.key;|ssl_certificate_key /etc/letsencrypt/live/$NGINX_DOMAIN/privkey.pem;|" "$nginx_conf_dir/immich.conf"
                    
                    # Mount Let's Encrypt directory in docker-compose
                    python3 << PYTHON_CERT
import yaml

with open('docker-compose.yml', 'r') as f:
    data = yaml.safe_load(f)

if 'nginx' in data.get('services', {}):
    volumes = data['services']['nginx'].get('volumes', [])
    # Remove old ssl mount, add Let's Encrypt mount
    volumes = [v for v in volumes if '/etc/nginx/ssl' not in str(v)]
    volumes.append('/etc/letsencrypt:/etc/letsencrypt:ro')
    data['services']['nginx']['volumes'] = volumes
    
    with open('docker-compose.yml', 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
PYTHON_CERT
                    
                    # Set up auto-renewal
                    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * certbot renew --quiet --deploy-hook 'cd $IMMICH_DIR && docker compose restart nginx'") | crontab -
                    
                    echo "✓ Let's Encrypt certificate installed and auto-renewal configured"
                    docker compose restart nginx
                else
                    echo "⚠ Falling back to self-signed certificate"
                    NGINX_SSL_TYPE="2"
                fi
            else
                echo "⚠ Skipping Let's Encrypt setup. Using self-signed certificate."
                NGINX_SSL_TYPE="2"
            fi
        fi
        
        if [ "$NGINX_SSL_TYPE" = "2" ]; then
            # Generate SSL certificates
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$IMMICH_DIR/nginx/ssl/immich.key" \
                -out "$IMMICH_DIR/nginx/ssl/immich.crt" \
                -subj "/C=US/ST=State/L=City/O=Organization/CN=$NGINX_DOMAIN"
            echo "✓ SSL certificates generated"
        fi
        
        echo ""
        echo "Nginx will be added to docker-compose.yml"
        echo "Re-running docker-compose modification to add nginx service..."
        
        # Re-run Python script to add nginx service (certs now exist)
        python3 << PYTHON_SCRIPT
import yaml
import os

with open('docker-compose.yml', 'r') as f:
    data = yaml.safe_load(f)

# Add nginx service if not already present
if 'nginx' not in data.get('services', {}):
    nginx_conf_dir = os.path.expanduser('~/immich-app/nginx')
    os.makedirs(nginx_conf_dir, exist_ok=True)
    os.makedirs(os.path.join(nginx_conf_dir, 'ssl'), exist_ok=True)
    
    nginx_domain = os.environ.get('NGINX_DOMAIN', '')
    
    # Create nginx config file
    # Build config with proper $ escaping for nginx variables
    # Include SSL certificate paths (will be added if certificates exist)
    ssl_cert_exists = os.path.exists(os.path.join(nginx_conf_dir, 'ssl', 'immich.crt'))
    ssl_lines = []
    if ssl_cert_exists:
        ssl_lines = [
            '    ssl_certificate /etc/nginx/ssl/immich.crt;',
            '    ssl_certificate_key /etc/nginx/ssl/immich.key;',
            ''
        ]
    
    nginx_conf_lines = [
        'server {',
        '    listen 443 ssl http2;',
        f'    server_name {nginx_domain};',
    ]
    nginx_conf_lines.extend(ssl_lines)
    nginx_conf_lines.extend([
        '    client_max_body_size 50000M;',
        '',
        '    # Immich mobile app discovery endpoint',
        '    location = /.well-known/immich {',
        '        proxy_pass http://immich-server:2283;',
        '        proxy_http_version 1.1;',
        '        proxy_set_header Host $host;',
        '        proxy_set_header X-Real-IP $remote_addr;',
        '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;',
        '        proxy_set_header X-Forwarded-Proto $scheme;',
        '    }',
        '',
        '    location / {',
        '        proxy_pass http://immich-server:2283;',
        '        proxy_http_version 1.1;',
        '        proxy_set_header Upgrade $http_upgrade;',
        "        proxy_set_header Connection 'upgrade';",
        '        proxy_set_header Host $host;',
        '        proxy_set_header X-Real-IP $remote_addr;',
        '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;',
        '        proxy_set_header X-Forwarded-Proto $scheme;',
        '        proxy_cache_bypass $http_upgrade;',
        '        proxy_connect_timeout 600;',
        '        proxy_send_timeout 600;',
        '        proxy_read_timeout 600;',
        '    }',
        '}'
    ])
    nginx_conf = '\n'.join(nginx_conf_lines)
    
    with open(os.path.join(nginx_conf_dir, 'immich.conf'), 'w') as f:
        f.write(nginx_conf)
    
    # Add nginx service to docker-compose
    data['services']['nginx'] = {
        'image': 'nginx:alpine',
        'container_name': 'immich-nginx',
        'ports': ['443:443'],
        'volumes': [
            f'{nginx_conf_dir}/immich.conf:/etc/nginx/conf.d/default.conf:ro',
            f'{nginx_conf_dir}/ssl:/etc/nginx/ssl:ro'
        ],
        'depends_on': ['immich-server'],
        'restart': 'unless-stopped'
    }
    
    with open('docker-compose.yml', 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
    
    print("✓ Added nginx service to docker-compose.yml")
PYTHON_SCRIPT
        
        echo "✓ Nginx reverse proxy configured in docker-compose"
        echo "  Access at: https://$NGINX_DOMAIN (after starting containers)"
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
    echo "3. Access at: https://$NGINX_DOMAIN (or http://localhost:2283)"
else
    echo "3. Access at: http://localhost:2283 or http://$(hostname -I | awk '{print $1}'):2283"
fi
echo "4. Create your admin account"
echo "5. Set up external library in Immich UI: Administration -> External Libraries"
echo "   - Add import path: /mnt/images"
echo ""
echo "Note: If PostgreSQL fails to start, check /etc/postgresql/16/main/postgresql.conf"
echo "      and remove any vchord.so references if VectorChord isn't installed."
