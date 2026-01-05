#!/bin/bash
# Install dependencies on the Dell laptop
# Just installs packages - no configuration

set -e

echo "Installing dependencies for image server..."
echo ""

# Update package list
sudo apt-get update

# Install required packages
echo "Installing system packages..."
sudo apt-get install -y \
    exiftool \
    python3 \
    python3-pip \
    udev \
    usbutils

# Install Python packages
echo ""
echo "Installing Python packages..."
# Try apt first (preferred), fallback to pip with --break-system-packages
if apt-cache show python3-psycopg2 > /dev/null 2>&1; then
    sudo apt-get install -y python3-psycopg2
else
    pip3 install --break-system-packages psycopg2-binary
fi
pip3 install --break-system-packages duckdb

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Installed packages:"
echo "  - exiftool: $(exiftool -ver 2>/dev/null || echo 'check installation')"
echo "  - python3: $(python3 --version)"
echo "  - postgresql: $(psql --version 2>/dev/null || echo 'check installation')"
echo ""
echo "Next steps:"
echo "  1. Verify exiftool works: exiftool -ver"
echo "  2. Test metadata extraction on a sample image"
echo "  3. Set up PostgreSQL database (when ready)"
echo ""

