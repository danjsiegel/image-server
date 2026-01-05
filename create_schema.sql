-- Image metadata table schema

CREATE TABLE IF NOT EXISTS images (
    id SERIAL PRIMARY KEY,
    date_taken TIMESTAMP,
    camera_make TEXT,
    camera_model TEXT,
    lens TEXT,
    shutter_speed TEXT,
    iso TEXT,
    aperture TEXT,
    focal_length TEXT,
    file_path TEXT UNIQUE NOT NULL,
    metadata_json JSONB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_date_taken ON images(date_taken);
CREATE INDEX IF NOT EXISTS idx_camera ON images(camera_make, camera_model);
CREATE INDEX IF NOT EXISTS idx_file_path ON images(file_path);
CREATE INDEX IF NOT EXISTS idx_metadata_json ON images USING GIN(metadata_json);

