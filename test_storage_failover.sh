#!/bin/bash
# Test script for storage failover functionality
# Tests that sd_card_monitor.sh correctly chooses internal vs external drive

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERNAL_IMAGES="/home/$USER/images"
EXTERNAL_IMAGES="/mnt/external-storage/images"
MIN_FREE_SPACE_GB=10

echo "=== Testing Storage Failover Logic ==="
echo ""

# Test 1: Check if internal images directory exists
echo "Test 1: Checking internal images directory..."
if [ -d "$INTERNAL_IMAGES" ]; then
    echo "✓ Internal images directory exists: $INTERNAL_IMAGES"
else
    echo "⚠ Internal images directory does not exist (will be created on first use)"
fi

# Test 2: Check available space on internal drive
echo ""
echo "Test 2: Checking available space on internal drive..."
if [ -d "$INTERNAL_IMAGES" ]; then
    AVAILABLE_SPACE=$(df -BG "$INTERNAL_IMAGES" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//' || echo "0")
    
    # Handle case where df might return non-numeric
    if ! [[ "$AVAILABLE_SPACE" =~ ^[0-9]+$ ]]; then
        AVAILABLE_SPACE=0
    fi
    
    echo "  Available space: ${AVAILABLE_SPACE}GB"
    echo "  Minimum required: ${MIN_FREE_SPACE_GB}GB"
    
    if [ "$AVAILABLE_SPACE" -lt "$MIN_FREE_SPACE_GB" ]; then
        echo "  → Would use EXTERNAL drive (${AVAILABLE_SPACE}GB < ${MIN_FREE_SPACE_GB}GB)"
        EXPECTED_DEST="$EXTERNAL_IMAGES"
    else
        echo "  → Would use INTERNAL drive (${AVAILABLE_SPACE}GB >= ${MIN_FREE_SPACE_GB}GB)"
        EXPECTED_DEST="$INTERNAL_IMAGES"
    fi
else
    echo "  → Would use INTERNAL drive (directory will be created)"
    EXPECTED_DEST="$INTERNAL_IMAGES"
fi

# Test 3: Check if external drive is mounted
echo ""
echo "Test 3: Checking external drive..."
if mountpoint -q "/mnt/external-storage" 2>/dev/null; then
    echo "✓ External drive is mounted at /mnt/external-storage"
    
    if [ -d "$EXTERNAL_IMAGES" ]; then
        echo "✓ External images directory exists: $EXTERNAL_IMAGES"
    else
        echo "⚠ External images directory does not exist (will be created if needed)"
    fi
    
    EXTERNAL_SPACE=$(df -BG "/mnt/external-storage" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//' || echo "0")
    echo "  Available space on external: ${EXTERNAL_SPACE}GB"
else
    echo "⚠ External drive is not mounted"
    echo "  If internal drive is full, copy will fail"
    echo "  Mount it with: sudo mount /dev/sdb1 /mnt/external-storage"
fi

# Test 4: Simulate the logic from sd_card_monitor.sh
echo ""
echo "Test 4: Simulating failover logic..."
if [ -d "$INTERNAL_IMAGES" ]; then
    AVAILABLE_SPACE=$(df -BG "$INTERNAL_IMAGES" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//' || echo "0")
    if ! [[ "$AVAILABLE_SPACE" =~ ^[0-9]+$ ]]; then
        AVAILABLE_SPACE=0
    fi
    
    if [ "$AVAILABLE_SPACE" -lt "$MIN_FREE_SPACE_GB" ]; then
        CHOSEN_DEST="$EXTERNAL_IMAGES"
        echo "  Logic result: Would copy to EXTERNAL drive"
    else
        CHOSEN_DEST="$INTERNAL_IMAGES"
        echo "  Logic result: Would copy to INTERNAL drive"
    fi
else
    CHOSEN_DEST="$INTERNAL_IMAGES"
    echo "  Logic result: Would copy to INTERNAL drive (directory will be created)"
fi

echo ""
echo "=== Test Summary ==="
echo "Expected destination: $CHOSEN_DEST"
echo ""
echo "To test with actual SD card:"
echo "  1. Insert SD card"
echo "  2. Check log: tail -f ~/image-server.log"
echo "  3. Verify files are copied to: $CHOSEN_DEST"

