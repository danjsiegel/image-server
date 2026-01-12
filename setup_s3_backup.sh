#!/bin/bash
# Setup S3 backup configuration and verify AWS credentials

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup_config.sh"

echo "=== S3 Backup Setup ==="
echo ""

# Check if AWS credentials exist
AWS_CREDENTIALS="$HOME/.aws/credentials"
if [ ! -f "$AWS_CREDENTIALS" ]; then
    echo "Error: AWS credentials not found at $AWS_CREDENTIALS"
    echo ""
    echo "Please create the file with the following format:"
    echo ""
    echo "[default]"
    echo "aws_access_key_id = YOUR_ACCESS_KEY_ID"
    echo "aws_secret_access_key = YOUR_SECRET_ACCESS_KEY"
    echo ""
    echo "Then run this script again."
    exit 1
fi

# Check credentials file permissions
CRED_PERMS=$(stat -c %a "$AWS_CREDENTIALS" 2>/dev/null || stat -f %A "$AWS_CREDENTIALS" 2>/dev/null)
if [ "$CRED_PERMS" != "600" ]; then
    echo "Setting secure permissions on AWS credentials file..."
    chmod 600 "$AWS_CREDENTIALS"
    echo "✓ Credentials file secured (chmod 600)"
fi

echo "✓ AWS credentials file found"
echo ""

# Get configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Prompt for bucket name if not set
if [ -z "$S3_BUCKET" ]; then
    read -p "Enter S3 bucket name: " S3_BUCKET
fi

# Prompt for region if not set
if [ -z "$S3_REGION" ]; then
    read -p "Enter S3 region [us-east-1]: " S3_REGION
    S3_REGION="${S3_REGION:-us-east-1}"
fi

# Update config file
cat > "$CONFIG_FILE" << EOF
#!/bin/bash
# Configuration file for S3 backup
# Source this file in scripts to get configuration variables

# AWS S3 Configuration
export S3_BUCKET="${S3_BUCKET}"
export S3_REGION="${S3_REGION}"

# Source paths
export INTERNAL_IMAGES_PATH="\${INTERNAL_IMAGES_PATH:-$HOME/images}"
export EXTERNAL_IMAGES_PATH="\${EXTERNAL_IMAGES_PATH:-/mnt/external-storage/images}"
export IMMICH_UPLOAD_PATH="\${IMMICH_UPLOAD_PATH:-$HOME/immich-library/upload}"

# AWS credentials (standard AWS CLI format in ~/.aws/credentials)
export AWS_CREDENTIALS_FILE="\${AWS_CREDENTIALS_FILE:-$HOME/.aws/credentials}"

# Log file
export BACKUP_LOG_FILE="\${BACKUP_LOG_FILE:-$HOME/image-server-backup.log}"
EOF

echo "✓ Configuration saved to $CONFIG_FILE"
echo ""

# Test S3 connection
echo "Testing S3 connection..."

# Check for venv
VENV_PYTHON="$SCRIPT_DIR/venv/bin/python3"
if [ -f "$VENV_PYTHON" ]; then
    PYTHON_CMD="$VENV_PYTHON"
    echo "Using virtual environment Python"
elif command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
    echo "Using system Python (venv not found)"
else
    echo "Error: python3 not found"
    echo "Please install python3 or create a virtual environment"
    exit 1
fi

# Check if boto3 is installed, install if needed
if ! $PYTHON_CMD -c "import boto3" 2>/dev/null; then
    echo "Installing boto3..."
    if [ -f "$SCRIPT_DIR/venv/bin/pip" ]; then
        "$SCRIPT_DIR/venv/bin/pip" install boto3 psycopg2-binary
    else
        pip3 install --user boto3 psycopg2-binary
    fi
    echo "✓ boto3 installed"
fi

if [ -n "$PYTHON_CMD" ]; then
    $PYTHON_CMD << PYTHON_TEST
import boto3
import sys
from botocore.exceptions import ClientError, NoCredentialsError

try:
    s3_client = boto3.client('s3', region_name='${S3_REGION}')
    # Try to list bucket (head_bucket would be better but this is simpler)
    s3_client.head_bucket(Bucket='${S3_BUCKET}')
    print("✓ Successfully connected to S3 bucket: ${S3_BUCKET}")
except NoCredentialsError:
    print("✗ Error: AWS credentials not found")
    sys.exit(1)
except ClientError as e:
    error_code = e.response['Error']['Code']
    if error_code == '404':
        print("✗ Error: Bucket '${S3_BUCKET}' not found")
    elif error_code == '403':
        print("✗ Error: Access denied to bucket '${S3_BUCKET}' (check IAM permissions)")
    else:
        print(f"✗ Error: {e}")
    sys.exit(1)
except Exception as e:
    print(f"✗ Error: {e}")
    sys.exit(1)
PYTHON_TEST

    if [ $? -eq 0 ]; then
        echo ""
        echo "=== Setup Complete ==="
        echo ""
        echo "Next steps:"
        echo "1. Create database schema: ./create_backup_schema.sh"
        echo "2. Set up cron job: ./setup_backup_cron.sh"
        echo "3. Test backup manually (dry-run): source backup_config.sh && source venv/bin/activate && python3 backup_to_s3.py --dry-run"
    else
        echo ""
        echo "Setup incomplete - please fix errors above"
        exit 1
    fi
fi
