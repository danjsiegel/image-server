#!/usr/bin/env python3
"""
Simple test script to extract metadata from an image file
"""

import sys
import os
import json
import subprocess

def extract_metadata(filepath):
    """Extract metadata using exiftool"""
    try:
        result = subprocess.run(
            ['exiftool', '-j', filepath],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            print(f"Error running exiftool: {result.stderr}", file=sys.stderr)
            return None
        
        data = json.loads(result.stdout)[0]
        return data
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return None

def print_relevant_fields(data):
    """Print only the fields we care about"""
    if not data:
        return
    
    print("=== Image Metadata ===")
    print(f"Date Taken: {data.get('DateTimeOriginal', data.get('CreateDate', 'N/A'))}")
    print(f"Camera: {data.get('Make', 'N/A')} {data.get('Model', 'N/A')}")
    print(f"Lens: {data.get('Lens', data.get('LensModel', data.get('LensID', 'N/A')))}")
    print(f"Shutter Speed: {data.get('ShutterSpeed', data.get('ExposureTime', data.get('ShutterSpeedValue', 'N/A')))}")
    print(f"ISO: {data.get('ISO', data.get('ISOValue', 'N/A'))}")
    print(f"Aperture: {data.get('FNumber', data.get('ApertureValue', 'N/A'))}")
    print(f"Focal Length: {data.get('FocalLength', 'N/A')}")
    print(f"Dimensions: {data.get('ImageWidth', 'N/A')} x {data.get('ImageHeight', 'N/A')}")
    print()
    print("=== All Available Fields ===")
    for key in sorted(data.keys()):
        print(f"{key}: {data[key]}")

if __name__ == '__main__':
    # Default to test image if no argument provided
    if len(sys.argv) < 2:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        default_image = os.path.join(script_dir, 'DSCF1949.JPG')
        if os.path.exists(default_image):
            filepath = default_image
            print(f"Using default test image: {filepath}")
        else:
            print("Usage: python3 test_metadata.py [image_file]")
            print(f"Default test image not found: {default_image}")
            sys.exit(1)
    else:
        filepath = sys.argv[1]
    
    data = extract_metadata(filepath)
    
    if data:
        print_relevant_fields(data)
    else:
        sys.exit(1)

