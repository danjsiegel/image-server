#!/bin/bash
# Immich Upgrade Script
# Usage: ./upgrade_immich.sh [version]
# Examples:
#   ./upgrade_immich.sh           # Upgrade to latest release
#   ./upgrade_immich.sh v1.123.0  # Upgrade to specific version

set -e

IMMICH_DIR="${HOME}/immich-app"
BACKUP_DIR="${HOME}/immich-backups"
LOG_FILE="${HOME}/immich-upgrade.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# Parse arguments
TARGET_VERSION="${1:-release}"

log "=========================================="
log "Immich Upgrade Script"
log "Target version: $TARGET_VERSION"
log "=========================================="

# Check we're in the right place
if [ ! -f "$IMMICH_DIR/docker-compose.yml" ]; then
    error "docker-compose.yml not found in $IMMICH_DIR"
fi

cd "$IMMICH_DIR"

# Get current version
CURRENT_VERSION=$(grep "^IMMICH_VERSION=" .env 2>/dev/null | cut -d'=' -f2 || echo "unknown")
log "Current version: $CURRENT_VERSION"

# Create backup directory
mkdir -p "$BACKUP_DIR"
BACKUP_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_PATH="$BACKUP_DIR/backup_$BACKUP_TIMESTAMP"
mkdir -p "$BACKUP_PATH"

# Step 1: Backup configuration
log "Step 1: Backing up configuration..."
cp .env "$BACKUP_PATH/.env.backup"
cp docker-compose.yml "$BACKUP_PATH/docker-compose.yml.backup"
if [ -d nginx ]; then
    cp -r nginx "$BACKUP_PATH/nginx.backup"
fi
log "✓ Configuration backed up to $BACKUP_PATH"

# Step 2: Backup database (optional but recommended)
log "Step 2: Backing up database..."
DB_BACKUP_FILE="$BACKUP_PATH/immich_db_$BACKUP_TIMESTAMP.sql"

# Get DB credentials from .env
DB_USER=$(grep "^DB_USERNAME=" .env | cut -d'=' -f2)
DB_NAME=$(grep "^DB_DATABASE_NAME=" .env | cut -d'=' -f2)
DB_PASS=$(grep "^DB_PASSWORD=" .env | cut -d'=' -f2)

if command -v pg_dump &> /dev/null; then
    PGPASSWORD="$DB_PASS" pg_dump -h localhost -U "$DB_USER" -d "$DB_NAME" > "$DB_BACKUP_FILE" 2>/dev/null && \
        log "✓ Database backed up to $DB_BACKUP_FILE" || \
        warn "Database backup failed (non-critical, continuing...)"
else
    warn "pg_dump not found, skipping database backup"
fi

# Step 3: Check for breaking changes
log "Step 3: Checking release notes..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "IMPORTANT: Check release notes before upgrading!"
echo "https://github.com/immich-app/immich/releases"
echo ""
echo "Look for:"
echo "  - Breaking changes"
echo "  - Database migrations"
echo "  - New required environment variables"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Have you reviewed the release notes? Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Upgrade cancelled by user"
    exit 0
fi

# Step 4: Update version in .env
log "Step 4: Updating version..."
if [ "$TARGET_VERSION" != "release" ]; then
    # Set specific version
    if grep -q "^IMMICH_VERSION=" .env; then
        sed -i "s/^IMMICH_VERSION=.*/IMMICH_VERSION=$TARGET_VERSION/" .env
    else
        echo "IMMICH_VERSION=$TARGET_VERSION" >> .env
    fi
    log "✓ Set IMMICH_VERSION=$TARGET_VERSION"
else
    # Use 'release' tag (latest stable)
    if grep -q "^IMMICH_VERSION=" .env; then
        sed -i "s/^IMMICH_VERSION=.*/IMMICH_VERSION=release/" .env
    else
        echo "IMMICH_VERSION=release" >> .env
    fi
    log "✓ Set IMMICH_VERSION=release (latest stable)"
fi

# Step 5: Pull new images
log "Step 5: Pulling new Docker images..."
docker compose pull
log "✓ Images pulled"

# Step 6: Stop services
log "Step 6: Stopping Immich services..."
docker compose down
log "✓ Services stopped"

# Step 7: Start services with new version
log "Step 7: Starting Immich with new version..."
docker compose up -d
log "✓ Services started"

# Step 8: Wait for health checks
log "Step 8: Waiting for services to be healthy..."
sleep 10

MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if docker compose ps | grep -q "unhealthy\|starting"; then
        echo -n "."
        sleep 5
        WAITED=$((WAITED + 5))
    else
        break
    fi
done
echo ""

# Step 9: Verify
log "Step 9: Verifying upgrade..."
echo ""
docker compose ps
echo ""

# Check if server is responding
if curl -s -o /dev/null -w "%{http_code}" https://localhost/api/server/ping -k 2>/dev/null | grep -q "200"; then
    log "✓ Immich server is responding"
else
    warn "Server may still be starting up. Check logs with: docker compose logs -f"
fi

# Get new version
NEW_VERSION=$(docker compose exec -T immich-server cat /app/package.json 2>/dev/null | grep '"version"' | head -1 | cut -d'"' -f4 || echo "unknown")
log "New version: $NEW_VERSION"

log "=========================================="
log "Upgrade complete!"
log "=========================================="
echo ""
echo "Post-upgrade checklist:"
echo "  1. Open Immich in browser and verify it works"
echo "  2. Check Administration → Jobs for any pending migrations"
echo "  3. Test photo upload"
echo "  4. Test library scan: cd ~/image-server && source venv/bin/activate && python3 trigger_immich_scan.py"
echo ""
echo "If something is wrong, rollback with:"
echo "  cd $IMMICH_DIR"
echo "  cp $BACKUP_PATH/.env.backup .env"
echo "  docker compose pull"
echo "  docker compose up -d"
echo ""
echo "Backup location: $BACKUP_PATH"
