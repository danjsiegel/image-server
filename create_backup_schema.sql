-- S3 backup tracking table schema

CREATE TABLE IF NOT EXISTS s3_backups (
    id SERIAL PRIMARY KEY,
    file_path TEXT UNIQUE NOT NULL,
    s3_key TEXT NOT NULL,
    source_type TEXT NOT NULL,  -- 'internal', 'external', or 'immich_upload'
    file_size BIGINT,
    uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_verified_at TIMESTAMP,
    md5_checksum TEXT,
    status TEXT DEFAULT 'uploaded'  -- 'uploaded', 'error'
);

-- Indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_s3_backups_file_path ON s3_backups(file_path);
CREATE INDEX IF NOT EXISTS idx_s3_backups_s3_key ON s3_backups(s3_key);
CREATE INDEX IF NOT EXISTS idx_s3_backups_source_type ON s3_backups(source_type);
CREATE INDEX IF NOT EXISTS idx_s3_backups_status ON s3_backups(status);

-- Deleted backups audit table (keeps main table clean and performant)
CREATE TABLE IF NOT EXISTS s3_backups_deleted (
    id SERIAL PRIMARY KEY,
    file_path TEXT NOT NULL,
    s3_key TEXT NOT NULL,
    source_type TEXT NOT NULL,
    file_size BIGINT,
    uploaded_at TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    md5_checksum TEXT,
    original_status TEXT  -- Store the original status before deletion
);

-- Add s3_full_path column if it doesn't exist (for idempotency - handles existing tables)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 's3_backups_deleted' AND column_name = 's3_full_path'
    ) THEN
        ALTER TABLE s3_backups_deleted ADD COLUMN s3_full_path TEXT;
    END IF;
END $$;

-- For new tables, we want s3_full_path to be NOT NULL, but for existing tables we add it as nullable first
-- Then we can make it NOT NULL after ensuring all rows have values
-- However, since this is a new feature and table is likely empty, we'll keep it simple
-- If there are existing rows, they'll need to be updated (which backup script will handle)

-- Indexes for deleted backups table
CREATE INDEX IF NOT EXISTS idx_s3_backups_deleted_file_path ON s3_backups_deleted(file_path);
CREATE INDEX IF NOT EXISTS idx_s3_backups_deleted_deleted_at ON s3_backups_deleted(deleted_at);
CREATE INDEX IF NOT EXISTS idx_s3_backups_deleted_source_type ON s3_backups_deleted(source_type);
