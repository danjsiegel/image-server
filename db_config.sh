#!/bin/bash
# Database configuration - source this file to get DB connection info

# Load database credentials
CREDS_FILE="$HOME/image-server/.db_credentials"
if [ -f "$CREDS_FILE" ]; then
    IMAGE_SERVER_PASSWORD=$(grep "^image_server:" "$CREDS_FILE" | cut -d':' -f2)
    export IMAGE_SERVER_PASSWORD
    export DB_CHECK=true
else
    export DB_CHECK=false
fi

export DB_HOST="localhost"
export DB_PORT="5432"
export DB_NAME="image_server"
export DB_USER="image_server"

