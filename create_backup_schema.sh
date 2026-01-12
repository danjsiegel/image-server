#!/bin/bash
# Create the S3 backup tracking table schema

set -e

# Load database credentials
if [ ! -f ~/image-server/.db_credentials ]; then
    echo "Error: Database credentials not found. Run setup_database.sh first."
    exit 1
fi

DB_PASSWORD=$(grep "^image_server:" ~/image-server/.db_credentials | cut -d':' -f2)

echo "Creating S3 backup tracking table schema..."

PGPASSWORD="$DB_PASSWORD" psql -h localhost -U image_server -d image_server -f ~/image-server/create_backup_schema.sql

echo ""
echo "Schema created successfully!"
echo ""
echo "Table structures:"
echo ""
echo "=== s3_backups table ==="
PGPASSWORD="$DB_PASSWORD" psql -h localhost -U image_server -d image_server -c "\d s3_backups"
echo ""
echo "=== s3_backups_deleted table ==="
PGPASSWORD="$DB_PASSWORD" psql -h localhost -U image_server -d image_server -c "\d s3_backups_deleted"