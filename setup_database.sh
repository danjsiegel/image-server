#!/bin/bash
# Simple PostgreSQL database setup
# Creates database and user - you design the schema

set -e

echo "Setting up PostgreSQL database..."
echo ""

# Prompt for database password
read -sp "Enter password for image_server database user: " DB_PASSWORD
echo ""
echo ""

# Create database and user
sudo -u postgres psql <<EOF
-- Create image_server database and user
CREATE USER image_server WITH PASSWORD '$DB_PASSWORD';
CREATE DATABASE image_server OWNER image_server;
GRANT ALL PRIVILEGES ON DATABASE image_server TO image_server;
\q
EOF

# Save password to file (for scripts to use)
echo "image_server:$DB_PASSWORD" > ~/image-server/.db_credentials
chmod 600 ~/image-server/.db_credentials

# Verify permissions
if [ "$(stat -c %a ~/image-server/.db_credentials 2>/dev/null || stat -f %A ~/image-server/.db_credentials 2>/dev/null)" != "600" ]; then
    echo "Warning: Could not set permissions on .db_credentials file"
else
    echo "✓ Database credentials file secured (chmod 600)"
fi

echo "Database created!"
echo ""
echo "Connection info:"
echo "  Database: image_server"
echo "  User: image_server"
echo "  Host: localhost"
echo "  Port: 5432"
echo ""
echo "Connect with: psql -U image_server -d image_server"
echo ""
echo "Next: Design and create your table schema"

