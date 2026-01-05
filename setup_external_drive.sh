#!/bin/bash
# Set up external drive with mergerfs for automatic failover
# Uses internal drive first, automatically uses external when internal gets full

set -e

EXTERNAL_DEVICE="${1:-/dev/sdb1}"
EXTERNAL_MOUNT="${2:-/mnt/external-storage}"
INTERNAL_IMAGES="$HOME/images"
UNIFIED_MOUNT="$HOME/images-unified"

echo "=== Setting up automatic failover storage with mergerfs ==="
echo ""
echo "This will create a unified filesystem that:"
echo "  - Uses internal drive (~/images) first"
echo "  - Automatically switches to external drive when internal gets full"
echo "  - Provides seamless failover - no manual intervention needed"
echo ""
echo "External device: $EXTERNAL_DEVICE"
echo "External mount: $EXTERNAL_MOUNT"
echo "Unified mount: $UNIFIED_MOUNT"
echo ""

# Check if device exists
if [ ! -e "$EXTERNAL_DEVICE" ]; then
    echo "⚠ Error: Device $EXTERNAL_DEVICE not found"
    echo "Available devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
    exit 1
fi

# Install mergerfs if not present
if ! command -v mergerfs &> /dev/null; then
    echo "Installing mergerfs..."
    sudo apt-get update
    sudo apt-get install -y mergerfs
fi

# Mount external drive
if ! mountpoint -q "$EXTERNAL_MOUNT" 2>/dev/null; then
    echo "Mounting external drive..."
    sudo mkdir -p "$EXTERNAL_MOUNT"
    
    # Get filesystem type
    FSTYPE=$(sudo blkid -s TYPE -o value "$EXTERNAL_DEVICE" || echo "")
    
    if [ -z "$FSTYPE" ] || [ "$FSTYPE" = "" ]; then
        echo "⚠ No filesystem detected on $EXTERNAL_DEVICE"
        echo "The drive should already be formatted. Exiting."
        exit 1
    fi
    
    # Get UUID for fstab entry
    UUID=$(sudo blkid -s UUID -o value "$EXTERNAL_DEVICE")
    
    # Mount the drive
    sudo mount "$EXTERNAL_DEVICE" "$EXTERNAL_MOUNT"
    
    # Add to fstab for auto-mount on boot
    FSTAB_ENTRY="UUID=$UUID $EXTERNAL_MOUNT $FSTYPE defaults,nofail 0 2"
    if ! grep -q "$EXTERNAL_MOUNT" /etc/fstab; then
        echo "Adding to /etc/fstab for auto-mount on boot..."
        echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    fi
else
    echo "✓ External drive already mounted at $EXTERNAL_MOUNT"
fi

# Create images directories on both drives
echo "Setting up directory structure..."
mkdir -p "$INTERNAL_IMAGES"
sudo mkdir -p "$EXTERNAL_MOUNT/images"
sudo chown $USER:$USER "$EXTERNAL_MOUNT/images"

# Create unified mount point with mergerfs
# mergerfs policy: "eplfs" = existing path, least free space
# This means: use internal drive first, only use external when internal is getting full
if ! mountpoint -q "$UNIFIED_MOUNT" 2>/dev/null; then
    echo "Creating unified filesystem with mergerfs..."
    mkdir -p "$UNIFIED_MOUNT"
    
    # Create mergerfs mount
    # eplfs policy: existing path, least free space (prefers internal, fails over to external)
    sudo mergerfs -o defaults,allow_other,use_ino,fsname=mergerfs,category.create=eplfs,minfreespace=10G "$INTERNAL_IMAGES:$EXTERNAL_MOUNT/images" "$UNIFIED_MOUNT"
    
    # Add to fstab for auto-mount on boot
    MERGERFS_ENTRY="$INTERNAL_IMAGES:$EXTERNAL_MOUNT/images $UNIFIED_MOUNT fuse.mergerfs defaults,allow_other,use_ino,fsname=mergerfs,category.create=eplfs,minfreespace=10G 0 0"
    if ! grep -q "$UNIFIED_MOUNT" /etc/fstab; then
        echo "Adding mergerfs to /etc/fstab for auto-mount on boot..."
        echo "$MERGERFS_ENTRY" | sudo tee -a /etc/fstab
    fi
else
    echo "✓ Unified filesystem already mounted at $UNIFIED_MOUNT"
fi

# Update ~/images to point to unified mount
if [ -L "$HOME/images" ]; then
    echo "Removing existing symlink..."
    rm "$HOME/images"
elif [ -d "$HOME/images" ] && [ "$(ls -A $HOME/images 2>/dev/null)" ]; then
    echo ""
    echo "⚠ Found existing images in $HOME/images"
    echo "Moving to unified mount (will be on internal drive first)..."
    mkdir -p "$UNIFIED_MOUNT"
    rsync -av "$HOME/images/" "$UNIFIED_MOUNT/"
    mv "$HOME/images" "$HOME/images.backup"
    echo "✓ Images moved. Original backed up to ~/images.backup"
fi

# Create symlink to unified mount
if [ ! -e "$HOME/images" ]; then
    echo "Creating symlink: $HOME/images -> $UNIFIED_MOUNT"
    ln -s "$UNIFIED_MOUNT" "$HOME/images"
fi

# Update Immich docker-compose to use unified mount
if [ -f "$HOME/immich-app/docker-compose.yml" ]; then
    echo ""
    echo "Updating Immich docker-compose.yml..."
    cd "$HOME/immich-app"
    python3 << PYTHON
import yaml
import os

with open('docker-compose.yml', 'r') as f:
    data = yaml.safe_load(f)

if 'immich-server' in data.get('services', {}):
    volumes = data['services']['immich-server'].get('volumes', [])
    # Update the images mount to use unified mount
    unified_mount = os.path.expanduser('~/images-unified')
    new_mount = f'{unified_mount}:/mnt/images:ro'
    volumes = [v for v in volumes if '/mnt/images' not in str(v)]
    volumes.append(new_mount)
    data['services']['immich-server']['volumes'] = volumes
    
    with open('docker-compose.yml', 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
    print("✓ Updated Immich to use unified storage")
PYTHON
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Storage configuration:"
echo "  Internal drive: $INTERNAL_IMAGES (used first)"
echo "  External drive: $EXTERNAL_MOUNT/images (used when internal is full)"
echo "  Unified mount: $UNIFIED_MOUNT (automatic failover)"
echo "  Symlink: $HOME/images -> $UNIFIED_MOUNT"
echo ""
echo "Storage information:"
echo "Combined storage (what you'll see in ~/images):"
df -h "$UNIFIED_MOUNT" 2>/dev/null || df -h "$HOME/images"
echo ""
echo "Individual drives:"
df -h "$EXTERNAL_MOUNT" 2>/dev/null
df -h "$(df $HOME/images | tail -1 | awk '{print $1}')" 2>/dev/null | grep -v Filesystem || echo "Internal drive: $(df -h / | tail -1)"
echo ""
echo "How it works:"
echo "  - Files are written to internal drive first"
echo "  - When internal drive has <10GB free, new files go to external drive"
echo "  - All files appear in $HOME/images regardless of which drive they're on"
echo "  - Both drives auto-mount on boot"
echo ""
echo "Storage reporting:"
echo "  - 'df -h ~/images' shows COMBINED space from both drives"
echo "  - System storage indicator may still show only internal drive (this is normal)"
echo "  - To see actual combined space: df -h ~/images-unified"
echo ""
echo "To check which drive a file is on:"
echo "  df -h ~/images/path/to/file.jpg"
