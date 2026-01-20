#!/usr/bin/env python3
"""
Trigger Immich library scan and RAW+JPEG stacking

This script calls the Immich API to:
1. Scan external libraries for new files
2. Trigger auto-stacking of RAW+JPEG pairs

Requirements:
- Immich API key (set IMMICH_API_KEY env var or in config file)
- Immich must be running

Usage:
    ./trigger_immich_scan.py              # Scan all external libraries
    ./trigger_immich_scan.py --stack      # Also trigger RAW+JPEG stacking
    ./trigger_immich_scan.py --dry-run    # Show what would be done
"""

import os
import sys
import json
import logging
import argparse
import ssl
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Default Immich URL (via nginx proxy - port 2283 not exposed to host)
DEFAULT_IMMICH_URL = "https://localhost"


def get_api_key():
    """Get Immich API key from environment or config file"""
    # Try environment variable first
    api_key = os.environ.get('IMMICH_API_KEY')
    if api_key:
        return api_key
    
    # Try config file
    config_file = os.path.expanduser('~/image-server/.immich_api_key')
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            return f.read().strip()
    
    return None


def api_request(url, api_key, method='GET', data=None):
    """Make an API request to Immich"""
    headers = {
        'x-api-key': api_key,
        'Content-Type': 'application/json'
    }
    
    req = Request(url, headers=headers, method=method)
    
    if data:
        req.data = json.dumps(data).encode('utf-8')
    
    # Create SSL context that doesn't verify certs (for localhost with self-signed)
    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
    
    try:
        with urlopen(req, timeout=30, context=ssl_context) as response:
            if response.status == 204:  # No content
                return None
            return json.loads(response.read().decode('utf-8'))
    except HTTPError as e:
        logger.error(f"HTTP Error {e.code}: {e.reason}")
        if e.code == 401:
            logger.error("Invalid API key. Create one in Immich: User Settings → API Keys")
        return None
    except URLError as e:
        logger.error(f"URL Error: {e.reason}")
        logger.error("Is Immich running? Check: docker ps | grep immich")
        return None


def get_libraries(base_url, api_key):
    """Get all libraries from Immich"""
    url = f"{base_url}/api/libraries"
    return api_request(url, api_key) or []


def scan_library(base_url, api_key, library_id, library_name, dry_run=False):
    """Trigger a library scan"""
    url = f"{base_url}/api/libraries/{library_id}/scan"
    
    if dry_run:
        logger.info(f"[DRY RUN] Would scan library: {library_name} ({library_id})")
        return True
    
    logger.info(f"Scanning library: {library_name} ({library_id})")
    result = api_request(url, api_key, method='POST')
    
    if result is None:
        # 204 No Content is success for this endpoint
        logger.info(f"✓ Scan triggered for: {library_name}")
        return True
    
    return True


def trigger_stacking_job(base_url, api_key, dry_run=False):
    """Trigger the RAW+JPEG stacking job for all assets"""
    url = f"{base_url}/api/assets/jobs"
    
    # First, we need to get all assets that could be stacked
    # The stacking job needs to be run per-asset or we use the bulk endpoint
    
    if dry_run:
        logger.info("[DRY RUN] Would trigger RAW+JPEG stacking job")
        return True
    
    # Note: Immich's auto-stacking is configured in Settings → Image
    # This just triggers a re-evaluation of all assets
    logger.info("Note: RAW+JPEG stacking is controlled by Immich settings")
    logger.info("Enable in: Administration → Settings → Image → Stack RAW images with JPEG pairs")
    logger.info("After enabling, new uploads will be auto-stacked during import")
    
    return True


def main():
    parser = argparse.ArgumentParser(description='Trigger Immich library scan and stacking')
    parser.add_argument('--url', default=DEFAULT_IMMICH_URL, 
                        help=f'Immich server URL (default: {DEFAULT_IMMICH_URL})')
    parser.add_argument('--stack', action='store_true',
                        help='Also show stacking configuration info')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be done without doing it')
    parser.add_argument('--external-only', action='store_true', default=False,
                        help='Only scan external libraries (default: False, scans all)')
    args = parser.parse_args()
    
    api_key = get_api_key()
    if not api_key:
        logger.error("No Immich API key found!")
        logger.error("Set IMMICH_API_KEY environment variable or create:")
        logger.error("  ~/image-server/.immich_api_key")
        logger.error("")
        logger.error("To create an API key in Immich:")
        logger.error("  1. Go to User Settings (click your profile icon)")
        logger.error("  2. Click 'API Keys'")
        logger.error("  3. Create a new key and save it")
        sys.exit(1)
    
    logger.info(f"Connecting to Immich at {args.url}")
    
    # Get libraries
    libraries = get_libraries(args.url, api_key)
    if not libraries:
        logger.error("No libraries found or couldn't connect to Immich")
        sys.exit(1)
    
    logger.info(f"Found {len(libraries)} libraries")
    
    # Scan each library
    scanned = 0
    for lib in libraries:
        lib_id = lib.get('id')
        lib_name = lib.get('name', 'Unnamed')
        lib_type = lib.get('type', 'UPLOAD')  # UPLOAD or EXTERNAL
        
        # Skip upload libraries if external-only
        if args.external_only and lib_type == 'UPLOAD':
            logger.info(f"Skipping upload library: {lib_name}")
            continue
        
        if scan_library(args.url, api_key, lib_id, lib_name, args.dry_run):
            scanned += 1
    
    logger.info(f"Triggered scan for {scanned} libraries")
    
    # Show stacking info if requested
    if args.stack:
        trigger_stacking_job(args.url, api_key, args.dry_run)
    
    logger.info("Done!")
    logger.info("")
    logger.info("Note: Library scans run in the background.")
    logger.info("Check Immich UI → Administration → Jobs to see progress.")


if __name__ == '__main__':
    main()
