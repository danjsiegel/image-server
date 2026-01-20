#!/usr/bin/env python3
"""
Process new images using DuckDB - extract metadata and insert into PostgreSQL
Run this on a schedule (cron) to process images in the background
"""

import os
import sys
import duckdb
import subprocess
import json
from datetime import datetime
from pathlib import Path

def get_pg_connection_string():
    """Get PostgreSQL connection string"""
    creds_file = os.path.expanduser('~/image-server/.db_credentials')
    
    with open(creds_file, 'r') as f:
        for line in f:
            if line.startswith('image_server:'):
                password = line.split(':', 1)[1].strip()
                return f"postgresql://image_server:{password}@localhost:5432/image_server"
    raise ValueError("Database credentials not found")

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
            return None
        
        return json.loads(result.stdout)[0]
    except Exception as e:
        return None

def safe_str(value):
    """Safely convert to string"""
    if value is None:
        return None
    return str(value).strip() or None

def find_image_files(base_dir):
    """Find all image files in directory, excluding Immich-generated directories"""
    image_extensions = {'.jpg', '.jpeg', '.raw', '.cr2', '.nef', '.arw', '.dng', '.tif', '.tiff', '.png', '.raf'}
    base_path = Path(base_dir)
    
    # Directories to exclude (Immich-generated content)
    exclude_dirs = {'library', 'thumbs', 'encoded-video', 'profiles', 'backups'}
    
    for ext in image_extensions:
        for filepath in base_path.rglob(f'*{ext}'):
            # Skip if in excluded directory
            if any(excluded in filepath.parts for excluded in exclude_dirs):
                continue
            yield filepath
        for filepath in base_path.rglob(f'*{ext.upper()}'):
            if any(excluded in filepath.parts for excluded in exclude_dirs):
                continue
            yield filepath

def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='Process images using DuckDB and insert into PostgreSQL')
    parser.add_argument('--dir', default=os.path.expanduser('~/images'), help='Directory to scan for images')
    parser.add_argument('--limit', type=int, default=0, help='Maximum number of images to process per run (0 = no limit)')
    parser.add_argument('--batch-size', type=int, default=50, help='Number of images to process in each batch (default: 50)')
    args = parser.parse_args()
    
    # Connect to DuckDB
    duck_conn = duckdb.connect()
    
    # Install and load postgres extension
    duck_conn.execute("INSTALL postgres;")
    duck_conn.execute("LOAD postgres;")
    
    pg_conn_str = get_pg_connection_string()
    
    # Detach if already attached
    try:
        duck_conn.execute("DETACH pg_db;")
    except:
        pass
    
    # Attach PostgreSQL database
    duck_conn.execute(f"ATTACH '{pg_conn_str}' AS pg_db (TYPE postgres);")
    
    # Get existing files from PostgreSQL using DuckDB
    # Only get files that are missing metadata (for idempotency)
    existing_result = duck_conn.execute("""
        SELECT file_path FROM pg_db.images 
        WHERE date_taken IS NOT NULL AND metadata_json IS NOT NULL
    """).fetchall()
    existing_files = {row[0] for row in existing_result}
    
    # Process images in batches to avoid memory issues
    total_processed = 0
    batch = []
    batch_count = 0
    
    for filepath in find_image_files(args.dir):
        filepath_str = str(filepath.absolute())
        
        # Skip if already processed with complete metadata
        if filepath_str in existing_files:
            continue
        
        if not filepath.exists():
            continue
        
        # Add to current batch
        batch.append(filepath)
        
        # Process batch when it reaches batch size
        if len(batch) >= args.batch_size:
            batch_count += 1
            print(f"Processing batch {batch_count} ({len(batch)} images)...")
            processed = process_batch(duck_conn, batch, existing_files)
            total_processed += processed
            batch = []
            
            # Check limit
            if args.limit > 0 and total_processed >= args.limit:
                break
    
    # Process remaining files in final batch
    if batch:
        batch_count += 1
        print(f"Processing final batch {batch_count} ({len(batch)} images)...")
        processed = process_batch(duck_conn, batch, existing_files)
        total_processed += processed
    
    print(f"✓ Total processed: {total_processed} images")
    
    duck_conn.close()

def process_batch(duck_conn, filepaths, existing_files):
    """Process a batch of images and insert into PostgreSQL"""
    rows = []
    
    for filepath in filepaths:
        filepath_str = str(filepath.absolute())
        
        # Double-check it's not already processed (in case of race condition)
        if filepath_str in existing_files:
            continue
        
        metadata = extract_metadata(filepath_str)
        if not metadata:
            print(f"⚠ Could not extract metadata: {filepath.name}")
            continue
        
        # Extract fields
        date_taken = metadata.get('DateTimeOriginal') or metadata.get('CreateDate')
        if date_taken:
            try:
                date_taken = datetime.strptime(date_taken, '%Y:%m:%d %H:%M:%S')
            except:
                date_taken = None
        
        rows.append((
            filepath_str,
            date_taken,
            safe_str(metadata.get('Make')),
            safe_str(metadata.get('Model')),
            safe_str(metadata.get('Lens') or metadata.get('LensModel') or metadata.get('LensID')),
            safe_str(metadata.get('ShutterSpeed') or metadata.get('ExposureTime') or metadata.get('ShutterSpeedValue')),
            safe_str(metadata.get('ISO') or metadata.get('ISOValue')),
            safe_str(metadata.get('FNumber') or metadata.get('ApertureValue')),
            safe_str(metadata.get('FocalLength')),
            json.dumps(metadata)
        ))
    
    if not rows:
        return 0
    
    # Use DuckDB's postgres_execute to run raw SQL inserts
    # This avoids issues with SERIAL columns by letting PostgreSQL handle id generation
    processed_count = 0
    for row in rows:
        filepath, date_taken, camera_make, camera_model, lens, shutter_speed, iso, aperture, focal_length, metadata_json = row
        
        # Escape single quotes in SQL strings
        def escape_sql(s):
            if s is None:
                return 'NULL'
            s_str = str(s).replace("'", "''")
            return f"'{s_str}'"
        
        date_str = f"'{date_taken}'" if date_taken else 'NULL'
        
        # Build the INSERT SQL - escape the entire SQL string for postgres_execute
        insert_sql = f"""INSERT INTO images (file_path, date_taken, camera_make, camera_model, lens, shutter_speed, iso, aperture, focal_length, metadata_json) VALUES ({escape_sql(filepath)}, {date_str}, {escape_sql(camera_make)}, {escape_sql(camera_model)}, {escape_sql(lens)}, {escape_sql(shutter_speed)}, {escape_sql(iso)}, {escape_sql(aperture)}, {escape_sql(focal_length)}, {escape_sql(metadata_json)}::jsonb) ON CONFLICT (file_path) DO UPDATE SET date_taken = COALESCE(EXCLUDED.date_taken, images.date_taken), camera_make = COALESCE(EXCLUDED.camera_make, images.camera_make), camera_model = COALESCE(EXCLUDED.camera_model, images.camera_model), lens = COALESCE(EXCLUDED.lens, images.lens), shutter_speed = COALESCE(EXCLUDED.shutter_speed, images.shutter_speed), iso = COALESCE(EXCLUDED.iso, images.iso), aperture = COALESCE(EXCLUDED.aperture, images.aperture), focal_length = COALESCE(EXCLUDED.focal_length, images.focal_length), metadata_json = COALESCE(EXCLUDED.metadata_json, images.metadata_json) WHERE images.date_taken IS NULL OR images.metadata_json IS NULL"""
        
        # Escape the SQL string itself for the function call
        escaped_sql = insert_sql.replace("'", "''")
        
        try:
            duck_conn.execute(f"CALL postgres_execute('pg_db', '{escaped_sql}')")
            processed_count += 1
        except Exception as e:
            print(f"Error inserting {os.path.basename(filepath)}: {e}", file=sys.stderr)
    
    print(f"✓ Processed {processed_count} images")
    return processed_count

if __name__ == '__main__':
    main()
