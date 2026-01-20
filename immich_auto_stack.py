#!/usr/bin/env python3
"""
Auto-stack RAW+JPEG pairs in Immich

Based on https://github.com/tenekev/immich-auto-stack
Simplified for local use with existing API key setup.

Groups photos by:
1. Filename (without extension) - e.g., DSCF001.JPG and DSCF001.RAF
2. Capture datetime

Then stacks them with JPEG as the primary (visible) image.
"""

import os
import sys
import json
import ssl
import logging
from itertools import groupby
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Default Immich URL (via nginx proxy)
DEFAULT_IMMICH_URL = "https://localhost"

# SSL context for self-signed certs
ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE


def get_api_key():
    """Get Immich API key from environment or config file"""
    api_key = os.environ.get('IMMICH_API_KEY')
    if api_key:
        return api_key
    
    config_file = os.path.expanduser('~/image-server/.immich_api_key')
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            return f.read().strip()
    
    return None


def api_request(url, api_key, method='GET', data=None):
    """Make an API request to Immich"""
    headers = {
        'x-api-key': api_key,
        'Content-Type': 'application/json',
        'Accept': 'application/json'
    }
    
    req = Request(url, headers=headers, method=method)
    
    if data:
        req.data = json.dumps(data).encode('utf-8')
    
    try:
        with urlopen(req, timeout=60, context=ssl_context) as response:
            if response.status == 204:
                return None
            return json.loads(response.read().decode('utf-8'))
    except HTTPError as e:
        logger.error(f"HTTP Error {e.code}: {e.reason}")
        try:
            error_body = e.read().decode('utf-8')
            logger.error(f"Response: {error_body}")
        except:
            pass
        return None
    except URLError as e:
        logger.error(f"URL Error: {e.reason}")
        return None


def fetch_all_assets(base_url, api_key):
    """Fetch all assets from Immich using pagination"""
    assets = []
    page = 1
    size = 1000
    
    logger.info("Fetching assets from Immich...")
    
    while True:
        payload = {
            'size': size,
            'page': page,
            'withStacked': True
        }
        
        url = f"{base_url}/api/search/metadata"
        result = api_request(url, api_key, method='POST', data=payload)
        
        if not result:
            break
        
        items = result.get('assets', {}).get('items', [])
        assets.extend(items)
        
        next_page = result.get('assets', {}).get('nextPage')
        if not next_page:
            break
        page = next_page
    
    logger.info(f"Fetched {len(assets)} assets")
    return assets


def get_stack_key(asset):
    """Get grouping key for stacking: (filename_without_ext, datetime)"""
    filename = asset.get('originalFileName', '')
    # Remove extension
    base_name = filename.rsplit('.', 1)[0] if '.' in filename else filename
    
    datetime_val = asset.get('localDateTime', '')
    
    if not base_name or not datetime_val:
        return None
    
    return (base_name, datetime_val)


def is_jpeg(asset):
    """Check if asset is a JPEG (should be stack parent)"""
    filename = asset.get('originalFileName', '').lower()
    return filename.endswith('.jpg') or filename.endswith('.jpeg')


def find_stackable_groups(assets):
    """Find groups of assets that should be stacked"""
    # Filter out assets that are already stacked
    unstacked = [a for a in assets if not a.get('stackCount')]
    
    # Group by stack key
    keyed = [(get_stack_key(a), a) for a in unstacked]
    keyed = [(k, a) for k, a in keyed if k is not None]
    
    # Sort by key for groupby
    keyed.sort(key=lambda x: x[0])
    
    groups = []
    for key, group_iter in groupby(keyed, key=lambda x: x[0]):
        group = [item[1] for item in group_iter]
        if len(group) > 1:
            groups.append((key, group))
    
    return groups


def stack_assets(base_url, api_key, parent_id, child_ids, dry_run=False):
    """Stack assets using Immich API"""
    if dry_run:
        logger.info(f"  [DRY RUN] Would stack {len(child_ids)} children under parent")
        return True
    
    # Try new API first: POST /api/stacks (Immich v1.99+)
    # assetIds should include ALL assets, with primary (JPEG) first
    all_asset_ids = [parent_id] + child_ids
    
    url = f"{base_url}/api/stacks"
    payload = {
        "assetIds": all_asset_ids
    }
    
    result = api_request(url, api_key, method='POST', data=payload)
    
    if result is None:
        # Fallback to old API: PUT /api/assets with stackParentId
        logger.info("  Trying legacy API...")
        url = f"{base_url}/api/assets"
        payload = {
            "ids": child_ids,
            "stackParentId": parent_id
        }
        result = api_request(url, api_key, method='PUT', data=payload)
    
    return result is not None or True


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='Auto-stack RAW+JPEG pairs in Immich')
    parser.add_argument('--url', default=DEFAULT_IMMICH_URL,
                        help=f'Immich server URL (default: {DEFAULT_IMMICH_URL})')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be stacked without making changes')
    args = parser.parse_args()
    
    api_key = get_api_key()
    if not api_key:
        logger.error("No Immich API key found!")
        logger.error("Set IMMICH_API_KEY or create ~/image-server/.immich_api_key")
        sys.exit(1)
    
    logger.info(f"Connecting to Immich at {args.url}")
    if args.dry_run:
        logger.info("DRY RUN MODE - no changes will be made")
    
    # Fetch all assets
    assets = fetch_all_assets(args.url, api_key)
    if not assets:
        logger.error("No assets found or couldn't connect")
        sys.exit(1)
    
    # Find stackable groups
    groups = find_stackable_groups(assets)
    logger.info(f"Found {len(groups)} groups to stack")
    
    if not groups:
        logger.info("Nothing to stack!")
        return
    
    # Stack each group
    stacked = 0
    for i, (key, group) in enumerate(groups):
        base_name, datetime_val = key
        
        # Sort so JPEG is first (will be parent)
        group.sort(key=lambda x: (0 if is_jpeg(x) else 1, x.get('originalFileName', '')))
        
        parent = group[0]
        children = group[1:]
        
        parent_name = parent.get('originalFileName', 'unknown')
        parent_id = parent.get('id')
        child_ids = [c.get('id') for c in children]
        child_names = [c.get('originalFileName', 'unknown') for c in children]
        
        logger.info(f"[{i+1}/{len(groups)}] Stacking: {base_name}")
        logger.info(f"  Parent: {parent_name}")
        for cn in child_names:
            logger.info(f"  Child:  {cn}")
        
        if stack_assets(args.url, api_key, parent_id, child_ids, args.dry_run):
            stacked += 1
    
    logger.info(f"Done! Stacked {stacked} groups")


if __name__ == '__main__':
    main()
