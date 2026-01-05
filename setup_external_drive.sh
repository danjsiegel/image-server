#!/bin/bash
# Set up external drive for image storage
# The SD card copy script will automatically use this when internal drive is full

set -e

EXTERNAL_DEVICE="${1:-/dev/sdb1}"
EXTERNAL_MOUNT="${2:-/mnt/external-storage}"

echo "=== Setting up external drive for image storage ==="
echo ""
echo "This will mount the external drive so it can be used for automatic failover."
echo "The SD card copy script will automatically use this when internal drive has <10GB free."
echo ""
echo "External device: $EXTERNAL_DEVICE"
echo "External mount: $EXTERNAL_MOUNT"
echo ""

# Check if device exists
if [ ! -e "$EXTERNAL_DEVICE" ]; then
    echo "⚠ Error: Device $EXTERNAL_DEVICE not found"
    echo "Available devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
    exit 1
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
    
    # Add to fstab for auto-mount on boot (with nofail so it doesn't hang if drive isn't connected)
    FSTAB_ENTRY="UUID=$UUID $EXTERNAL_MOUNT $FSTYPE defaults,nofail 0 2"
    if ! grep -q "$EXTERNAL_MOUNT" /etc/fstab; then
        echo "Adding to /etc/fstab for auto-mount on boot..."
        echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    else
        echo "✓ Already in /etc/fstab"
    fi
else
    echo "✓ External drive already mounted at $EXTERNAL_MOUNT"
fi

# Create images directory on external drive
echo "Creating images directory on external drive..."
sudo mkdir -p "$EXTERNAL_MOUNT/images"
sudo chown $USER:$USER "$EXTERNAL_MOUNT/images"
echo "✓ External images directory created: $EXTERNAL_MOUNT/images"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Storage configuration:"
echo "  Internal drive: ~/images (used first)"
echo "  External drive: $EXTERNAL_MOUNT/images (used automatically when internal has <10GB free)"
echo ""
echo "How it works:"
echo "  - SD card copy script checks available space on internal drive"
echo "  - If <10GB free, files are copied to external drive instead"
echo "  - No complex filesystem layers - simple and reliable"
echo ""
echo "Storage information:"
df -h "$EXTERNAL_MOUNT" 2>/dev/null || echo "External drive not mounted"
echo ""
echo "The external drive will auto-mount on boot (with nofail option)."
