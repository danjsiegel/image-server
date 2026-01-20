#!/usr/bin/env python3
"""
Backup images to S3 Glacier Deep Archive
- Uploads new files to S3
- Syncs deletions safely (only for mounted paths)
- Stores metadata on S3 objects and in PostgreSQL
"""

import os
import sys
import hashlib
import logging
import boto3
import psycopg2
from datetime import datetime
from pathlib import Path
from botocore.exceptions import ClientError, NoCredentialsError

# Set up logging
LOG_FILE = os.path.expanduser('~/image-server-backup.log')
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

# Image extensions to backup
IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.raw', '.cr2', '.nef', '.arw', '.dng', '.tif', '.tiff', '.png', '.raf'}
IMAGE_EXTENSIONS.update({ext.upper() for ext in IMAGE_EXTENSIONS})

# Directories to exclude (Immich-generated content)
# Note: 'upload' is NOT excluded because UI-uploaded files go into ~/immich-library/upload/
EXCLUDE_DIRS = {'thumbs', 'encoded-video', 'profiles', 'backups'}


def get_db_connection():
    """Get PostgreSQL connection"""
    creds_file = os.path.expanduser('~/image-server/.db_credentials')
    
    try:
        with open(creds_file, 'r') as f:
            for line in f:
                if line.startswith('image_server:'):
                    password = line.split(':', 1)[1].strip()
                    conn = psycopg2.connect(
                        host='localhost',
                        port=5432,
                        database='image_server',
                        user='image_server',
                        password=password
                    )
                    return conn
        raise ValueError("Database credentials not found")
    except Exception as e:
        logger.error(f"Failed to connect to database: {e}")
        raise


def get_s3_client(region):
    """Get S3 client (uses credentials from ~/.aws/credentials)"""
    try:
        return boto3.client('s3', region_name=region)
    except NoCredentialsError:
        logger.error("AWS credentials not found in ~/.aws/credentials")
        raise


def calculate_md5(filepath):
    """Calculate MD5 checksum of file"""
    hash_md5 = hashlib.md5()
    try:
        with open(filepath, 'rb') as f:
            for chunk in iter(lambda: f.read(4096), b""):
                hash_md5.update(chunk)
        return hash_md5.hexdigest()
    except Exception as e:
        logger.warning(f"Failed to calculate MD5 for {filepath}: {e}")
        return None


def get_s3_key(filepath, source_type, source_path):
    """Generate S3 key from file path and source type"""
    filepath_str = str(filepath)
    source_path_resolved = str(Path(source_path).resolve())
    filepath_resolved = str(Path(filepath_str).resolve())
    
    # Get relative path from source directory
    try:
        relative_path = os.path.relpath(filepath_resolved, source_path_resolved)
    except ValueError:
        # Paths on different drives (Windows) or absolute paths that don't share common prefix
        # Fall back to using filename with source type
        relative_path = Path(filepath_str).name
    
    # Ensure we have a valid relative path (not going outside source directory)
    if relative_path.startswith('..'):
        # Fallback: use just the filename
        relative_path = Path(filepath_str).name
    
    # Normalize path separators
    normalized_path = str(relative_path).replace('\\', '/')
    
    return f"{source_type}/{normalized_path}"


def file_in_database(cursor, filepath):
    """Check if file is already in database"""
    cursor.execute("SELECT id, s3_key, status FROM s3_backups WHERE file_path = %s", (str(filepath),))
    return cursor.fetchone()


def upload_file_to_s3(s3_client, bucket, filepath, s3_key, source_type, dry_run=False):
    """Upload file to S3 with metadata tags"""
    try:
        file_size = os.path.getsize(filepath)
        md5 = calculate_md5(filepath)
        
        # Metadata tags
        tags = {
            'source_type': source_type,
            'upload_date': datetime.now().isoformat(),
            'file_size': str(file_size),
            'original_path': str(filepath)
        }
        
        if dry_run:
            logger.info(f"[DRY RUN] Would upload: {filepath} -> s3://{bucket}/{s3_key} (size: {file_size}, md5: {md5})")
            return file_size, md5
        
        # Convert tags dict to S3 tag format
        tag_set = [{'Key': k, 'Value': v} for k, v in tags.items()]
        
        # Upload file
        with open(filepath, 'rb') as f:
            s3_client.upload_fileobj(
                f,
                bucket,
                s3_key,
                ExtraArgs={
                    'Tagging': '&'.join([f"{tag['Key']}={tag['Value']}" for tag in tag_set]),
                    'Metadata': tags
                }
            )
        
        logger.info(f"Uploaded: {filepath} -> s3://{bucket}/{s3_key}")
        return file_size, md5
    except ClientError as e:
        logger.error(f"Failed to upload {filepath}: {e}")
        raise
    except Exception as e:
        logger.error(f"Unexpected error uploading {filepath}: {e}")
        raise


def insert_into_database(cursor, conn, filepath, s3_key, source_type, file_size, md5, status='uploaded'):
    """Insert or update record in database"""
    try:
        cursor.execute("""
            INSERT INTO s3_backups (file_path, s3_key, source_type, file_size, md5_checksum, status, uploaded_at)
            VALUES (%s, %s, %s, %s, %s, %s, NOW())
            ON CONFLICT (file_path) 
            DO UPDATE SET 
                s3_key = EXCLUDED.s3_key,
                file_size = EXCLUDED.file_size,
                md5_checksum = EXCLUDED.md5_checksum,
                status = EXCLUDED.status,
                uploaded_at = EXCLUDED.uploaded_at
        """, (str(filepath), s3_key, source_type, file_size, md5, status))
        conn.commit()
    except Exception as e:
        logger.error(f"Failed to insert into database: {e}")
        conn.rollback()
        raise


def find_image_files(base_dir):
    """Find all image files in directory, excluding Immich-generated directories"""
    base_path = Path(base_dir)
    
    if not base_path.exists():
        return
    
    for filepath in base_path.rglob('*'):
        if not filepath.is_file():
            continue
        
        # Check extension
        if filepath.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        
        # Skip if in excluded directory
        if any(excluded in filepath.parts for excluded in EXCLUDE_DIRS):
            continue
        
        yield filepath


def scan_and_upload(s3_client, bucket, cursor, conn, source_type, source_path, dry_run=False):
    """Scan source path and upload new files"""
    if not os.path.exists(source_path):
        logger.info(f"Source path does not exist (skipping): {source_path}")
        return
    
    source_path_resolved = str(Path(source_path).resolve())
    logger.info(f"Scanning {source_type}: {source_path}")
    uploaded_count = 0
    error_count = 0
    skipped_count = 0
    
    for filepath in find_image_files(source_path):
        try:
            # Check if already in database
            db_record = file_in_database(cursor, filepath)
            if db_record and db_record[2] == 'uploaded':
                skipped_count += 1
                continue  # Already uploaded
            
            # Generate S3 key
            s3_key = get_s3_key(filepath, source_type, source_path_resolved)
            
            # Upload to S3 (or simulate in dry-run)
            file_size, md5 = upload_file_to_s3(s3_client, bucket, filepath, s3_key, source_type, dry_run)
            
            if not dry_run:
                # Insert into database
                insert_into_database(cursor, conn, filepath, s3_key, source_type, file_size, md5, 'uploaded')
            uploaded_count += 1
            
        except Exception as e:
            logger.error(f"Error processing {filepath}: {e}")
            error_count += 1
            if not dry_run:
                # Try to mark as error in database
                try:
                    s3_key = get_s3_key(filepath, source_type, source_path_resolved)
                    cursor.execute("""
                        INSERT INTO s3_backups (file_path, s3_key, source_type, status)
                        VALUES (%s, %s, %s, 'error')
                        ON CONFLICT (file_path) DO UPDATE SET status = 'error'
                    """, (str(filepath), s3_key, source_type))
                    conn.commit()
                except:
                    conn.rollback()
    
    logger.info(f"Completed {source_type}: {uploaded_count} would upload, {skipped_count} skipped, {error_count} errors")


def sync_deletions(s3_client, bucket, cursor, conn, source_type, source_path, dry_run=False):
    """Sync deletions: delete from S3 if file no longer exists locally"""
    if not os.path.exists(source_path):
        logger.info(f"Source path not accessible (skipping deletion sync): {source_path}")
        return
    
    source_path_resolved = str(Path(source_path).resolve())
    logger.info(f"Syncing deletions for {source_type}: {source_path}")
    deleted_count = 0
    error_count = 0
    
    # Get all files for this source type from database that are in the source path
    cursor.execute("""
        SELECT file_path, s3_key 
        FROM s3_backups 
        WHERE source_type = %s AND status = 'uploaded' AND file_path LIKE %s
    """, (source_type, f"{source_path_resolved}%"))
    db_files = cursor.fetchall()
    
    for db_file_path, s3_key in db_files:
        filepath = Path(db_file_path)
        if not filepath.exists():
            # File no longer exists locally, delete from S3
            if dry_run:
                logger.info(f"[DRY RUN] Would delete from S3 (file removed locally): {db_file_path} -> s3://{bucket}/{s3_key}")
                deleted_count += 1
            else:
                try:
                    # First, get the record data to insert into deleted table
                    cursor.execute("""
                        SELECT file_path, s3_key, source_type, file_size, uploaded_at, md5_checksum, status
                        FROM s3_backups WHERE file_path = %s
                    """, (db_file_path,))
                    record = cursor.fetchone()
                    
                    if record:
                        # Build full S3 path for audit trail
                        s3_full_path = f"s3://{bucket}/{record[1]}"
                        
                        # Insert into deleted table for audit trail
                        cursor.execute("""
                            INSERT INTO s3_backups_deleted 
                            (file_path, s3_key, s3_full_path, source_type, file_size, uploaded_at, md5_checksum, original_status, deleted_at)
                            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NOW())
                        """, (record[0], record[1], s3_full_path, record[2], record[3], record[4], record[5], record[6]))
                        
                        # Delete from S3
                        s3_client.delete_object(Bucket=bucket, Key=s3_key)
                        
                        # Then delete from main table (keeps it clean and performant)
                        cursor.execute("DELETE FROM s3_backups WHERE file_path = %s", (db_file_path,))
                        conn.commit()
                        logger.info(f"Deleted from S3 (file removed locally): {db_file_path} -> {s3_full_path}")
                        deleted_count += 1
                    else:
                        logger.warning(f"Record not found in database for {db_file_path}")
                        conn.rollback()
                except ClientError as e:
                    logger.error(f"Failed to delete {s3_key} from S3: {e}")
                    error_count += 1
                    conn.rollback()
                except Exception as e:
                    logger.error(f"Unexpected error deleting {s3_key}: {e}")
                    error_count += 1
                    conn.rollback()
    
    logger.info(f"Deletion sync complete for {source_type}: {deleted_count} deleted, {error_count} errors")


def main():
    """Main backup function"""
    import argparse
    
    parser = argparse.ArgumentParser(description='Backup images to S3 Glacier Deep Archive')
    parser.add_argument('--dry-run', action='store_true', help='Dry run mode - show what would be done without uploading')
    args = parser.parse_args()
    
    # Load configuration
    config_file = os.path.expanduser('~/image-server/backup_config.sh')
    if os.path.exists(config_file):
        # Source the config file to get environment variables
        import subprocess
        result = subprocess.run(['bash', '-c', f'source {config_file} && env'], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            if '=' in line:
                key, value = line.split('=', 1)
                os.environ[key] = value
    
    # Get configuration from environment
    bucket = os.environ.get('S3_BUCKET')
    region = os.environ.get('S3_REGION', 'us-east-1')
    internal_path = os.path.expanduser(os.environ.get('INTERNAL_IMAGES_PATH', '~/images'))
    external_path = os.environ.get('EXTERNAL_IMAGES_PATH', '/mnt/external-storage/images')
    immich_path = os.path.expanduser(os.environ.get('IMMICH_UPLOAD_PATH', '~/immich-library/upload'))
    
    if not bucket:
        logger.error("S3_BUCKET not set in backup_config.sh")
        sys.exit(1)
    
    logger.info("=" * 60)
    if args.dry_run:
        logger.info("DRY RUN MODE - No files will be uploaded or deleted")
        logger.info("=" * 60)
    logger.info("Starting S3 backup")
    logger.info(f"Bucket: {bucket}")
    logger.info(f"Region: {region}")
    logger.info("=" * 60)
    
    try:
        # Connect to database
        db_conn = get_db_connection()
        db_cursor = db_conn.cursor()
        
        # Connect to S3 (only needed for actual uploads, but we'll create it for dry-run too to verify credentials work)
        s3_client = get_s3_client(region)
        
        # Upload new files
        scan_and_upload(s3_client, bucket, db_cursor, db_conn, 'internal', internal_path, args.dry_run)
        scan_and_upload(s3_client, bucket, db_cursor, db_conn, 'external', external_path, args.dry_run)
        scan_and_upload(s3_client, bucket, db_cursor, db_conn, 'immich_upload', immich_path, args.dry_run)
        
        # Sync deletions (only for accessible paths)
        sync_deletions(s3_client, bucket, db_cursor, db_conn, 'internal', internal_path, args.dry_run)
        sync_deletions(s3_client, bucket, db_cursor, db_conn, 'external', external_path, args.dry_run)
        sync_deletions(s3_client, bucket, db_cursor, db_conn, 'immich_upload', immich_path, args.dry_run)
        
        logger.info("=" * 60)
        if args.dry_run:
            logger.info("Dry run complete - no files were uploaded or deleted")
        else:
            logger.info("Backup complete")
        logger.info("=" * 60)
        
        db_cursor.close()
        db_conn.close()
        
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
