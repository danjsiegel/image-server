#!/bin/bash
# Configuration file for S3 backup
# Source this file in scripts to get configuration variables

# AWS S3 Configuration
export S3_BUCKET="${S3_BUCKET:-}"
export S3_REGION="${S3_REGION:-us-east-1}"

# Source paths
export INTERNAL_IMAGES_PATH="${INTERNAL_IMAGES_PATH:-$HOME/images}"
export EXTERNAL_IMAGES_PATH="${EXTERNAL_IMAGES_PATH:-/mnt/external-storage/images}"
# Immich UI uploads go into ~/immich-library/upload/ (in nested UUID/date structure)
export IMMICH_UPLOAD_PATH="${IMMICH_UPLOAD_PATH:-$HOME/immich-library/upload}"

# AWS credentials (standard AWS CLI format in ~/.aws/credentials)
export AWS_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

# Log file
export BACKUP_LOG_FILE="${BACKUP_LOG_FILE:-$HOME/image-server-backup.log}"
