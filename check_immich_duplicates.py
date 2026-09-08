#!/usr/bin/env python3
"""
Check if filenames exist in Immich library
Reads filenames from a file (one per line) and prints duplicates to stdout.
Uses a cache file to avoid fetching all assets multiple times.
"""

import os
import sys
import json
import tempfile
import time
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
import ssl

CACHE_FILE = os.path.join(tempfile.gettempdir(), 'immich_assets_cache.json')
CACHE_TTL = 300


def get_immich_url():
    url = os.environ.get('IMMICH_URL')
    if url:
        return url
    config_file = os.path.expanduser('~/image-server/.immich_url')
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            return f.read().strip()
    return "http://localhost:2283"


def get_api_key():
    api_key = os.environ.get('IMMICH_API_KEY')
    if api_key:
        return api_key
    config_file = os.path.expanduser('~/image-server/.immich_api_key')
    if os.path.exists(config_file):
        with open(config_file, 'r') as f:
            return f.read().strip()
    return None


def api_request(url, api_key, method='GET', data=None):
    headers = {
        'x-api-key': api_key,
        'Content-Type': 'application/json'
    }
    req = Request(url, headers=headers, method=method)
    if data:
        req.data = json.dumps(data).encode('utf-8')
    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
    try:
        with urlopen(req, timeout=30, context=ssl_context) as response:
            if response.status == 204:
                return None
            return json.loads(response.read().decode('utf-8'))
    except (HTTPError, URLError):
        return None


def fetch_all_assets(base_url, api_key):
    assets = []
    page = 1
    size = 1000

    while True:
        payload = {
            'size': size,
            'page': page,
            'withStacked': False
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

    return assets


def get_cached_assets():
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, 'r') as f:
                cache = json.load(f)
            if time.time() - cache.get('timestamp', 0) < CACHE_TTL:
                return cache.get('assets', [])
        except Exception:
            pass
    return None


def save_cached_assets(assets):
    with open(CACHE_FILE, 'w') as f:
        json.dump({
            'timestamp': time.time(),
            'assets': assets
        }, f)


def main():
    if len(sys.argv) < 2:
        print("Usage: check_immich_duplicates.py <file_with_filenames>")
        sys.exit(1)

    filepath = sys.argv[1]
    with open(filepath, 'r') as f:
        filenames = [line.strip() for line in f if line.strip()]

    if not filenames:
        sys.exit(0)

    api_key = get_api_key()
    if not api_key:
        sys.exit(0)

    url = get_immich_url()

    assets = get_cached_assets()
    if assets is None:
        assets = fetch_all_assets(url, api_key)
        save_cached_assets(assets)

    existing = {
        asset.get('originalFileName', '').lower()
        for asset in assets
        if asset.get('originalFileName')
    }

    for filename in filenames:
        if filename.lower() in existing:
            print(filename)


if __name__ == '__main__':
    main()
