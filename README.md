# Automated Image Server with SD Card Auto-Processing

A complete setup for turning an old laptop into an automated image server that automatically processes SD cards, extracts metadata, and provides photo management via Immich.

## Features

- **🔄 Auto SD Card Processing**: Automatically detects, copies, and ejects SD cards when inserted
- **📊 Metadata Extraction**: Extracts EXIF data (date, camera, lens, ISO, aperture, etc.) using DuckDB
- **🗄️ PostgreSQL Database**: Stores image metadata and powers Immich
- **📱 Immich Integration**: Self-hosted photo management with mobile app access via Tailscale
- **⏰ Scheduled Processing**: Background metadata extraction via cron (runs every 30 minutes)
- **💾 Persistent Storage**: All data persists across reboots

## Architecture

```
SD Card Insertion
    ↓
udev Rule Triggers
    ↓
sd_card_monitor.sh → copy_from_sd.sh
    ↓
Images Copied to ~/images/YYYY/MM/DD/
    ↓
Cron Job (every 30 min)
    ↓
process_new_images.py (DuckDB → PostgreSQL)
    ↓
Metadata Stored in PostgreSQL
    ↓
Immich Scans External Library
    ↓
Accessible via Mobile App (Tailscale)
```

## Prerequisites

- Ubuntu/Debian-based Linux system
- PostgreSQL 14+ installed
- Python 3.x
- Root/sudo access for udev rules and system configuration
- **Tailscale** (recommended for secure remote access)

### Tailscale Setup (Recommended)

This setup uses **Tailscale** for secure remote access, which allows you to:
- Access Immich from your phone without exposing ports to the internet
- SSH to the server securely from anywhere
- No need for port forwarding or VPN configuration

**Quick Setup:**
1. Install Tailscale on both your server and client devices: https://tailscale.com/download
2. Sign in with the same account on all devices
3. Devices will automatically be on the same secure network
4. Access via Tailscale hostname (e.g., `thatoldlatitude.tail012354.ts.net`) or IP (e.g., `100.101.100.1`)

**Why Tailscale?**
- Zero-configuration VPN
- End-to-end encryption
- Works behind NAT/firewalls
- No need to expose services to the internet
- Free for personal use

**Alternative:** If you prefer not to use Tailscale, you can access Immich via localhost only, or set up your own VPN/port forwarding (not recommended for security).

## Installation

### 1. Clone and Deploy

```bash
# On your local machine
git clone <your-repo>
cd image-server

# Deploy to server (via Tailscale/SSH)
# Set REMOTE_HOST and REMOTE_USER if different from defaults
REMOTE_HOST=your-server-hostname REMOTE_USER=yourusername ./deploy.sh
```

### 2. Install Dependencies

SSH to the server and run:

```bash
ssh your-server-hostname  # or your Tailscale hostname
cd ~/image-server
./install_dependencies.sh
```

This installs:
- PostgreSQL, exiftool, Python packages
- Creates Python virtual environment
- Sets up pgvector extension for Immich

### 3. Set Up Database

```bash
./setup_database.sh
```

Creates:
- `image_server` database for image metadata
- `image_server` user with credentials stored in `~/.db_credentials`

### 4. Create Database Schema

```bash
./create_schema.sh
```

Creates the `images` table with:
- Standard metadata fields (date, camera, lens, ISO, etc.)
- `metadata_json` JSONB column for complete EXIF data
- Indexes for efficient querying

### 5. Set Up SD Card Auto-Processing

**Install udev rules:**
```bash
# IMPORTANT: First, update udev_sd_card.rules with your username!
# Edit the file and replace "yourusername" with your actual username

# Copy udev rules
sudo cp ~/image-server/udev_sd_card.rules /etc/udev/rules.d/99-sd-card-image-server.rules

# Make wrapper executable
chmod +x ~/image-server/udev_sd_card_wrapper.sh

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**Test:**
- Insert an SD card
- Check logs: `tail -f ~/image-server.log`
- Card should auto-copy and eject when complete

### 6. Set Up Metadata Processing (Cron)

```bash
./setup_cron.sh
```

Runs metadata extraction every 30 minutes in the background. The script:
- Only processes new images (idempotent)
- Processes in batches to manage memory
- Updates existing records if metadata was incomplete

### 7. Install and Configure Immich

```bash
./install_immich.sh
```

This comprehensive script:
- Installs Docker and Docker Compose
- Downloads Immich configuration files
- Configures Immich to use existing PostgreSQL database
- Sets up external library mount for existing images
- Configures PostgreSQL network access for Docker
- Creates `immich` database and grants necessary permissions

**After installation:**
1. Log out and back in (or run `newgrp docker`) for docker group to take effect
2. Start Immich: `cd ~/immich-app && docker compose up -d`
3. Access at: `http://localhost:2283` or via Tailscale
4. Create your admin account (first user becomes admin)
5. Set up external library: 
   - Go to Administration → External Libraries
   - Click "Create an external library"
   - Add import path: `/mnt/images`
   - Click "Scan" to import existing images

**Optional: Set up trusted SSL certificate** (recommended for mobile app):
```bash
# Enable HTTPS in Tailscale admin console first: https://login.tailscale.com/admin/dns
./setup_letsencrypt.sh yourmachine.tail0xxxx.ts.net
```

This provides a trusted certificate that works seamlessly with the mobile app. See "Setting Up Trusted SSL Certificate" section below for full details.

### 8. Set Up Auto-Start on Boot

```bash
./setup_autostart.sh
```

Creates systemd service to ensure:
- PostgreSQL starts on boot
- Docker starts on boot
- Immich containers start on boot

## Testing Locally

### Test Metadata Extraction

Use the included test image to verify metadata extraction works:

```bash
cd ~/image-server
source venv/bin/activate
python3 test_metadata.py
# or with a specific image:
python3 test_metadata.py /path/to/image.jpg
```

The test script uses `DSCF1949.JPG` (included in the repo) by default and displays:
- Key metadata fields (date, camera, lens, ISO, etc.)
- All available EXIF fields

### Test SD Card Processing

1. Insert an SD card with test images
2. Monitor logs: `tail -f ~/image-server.log`
3. Verify files copied: `ls -R ~/images/`
4. Check database: 
   ```bash
   PGPASSWORD=$(grep image_server ~/image-server/.db_credentials | cut -d: -f2 | tr -d ' ')
   psql -U image_server -d image_server -h localhost -c "SELECT file_path, date_taken, camera_make, camera_model FROM images LIMIT 5;"
   ```

## File Structure

```
~/images/                    # Main image storage
  ├── 2026/01/04/           # Images organized by date (from SD cards)
  ├── library/               # Immich's library storage
  ├── upload/                # Immich uploads
  ├── thumbs/                # Immich thumbnails
  └── encoded-video/         # Immich transcoded videos

~/image-server/              # Scripts and configuration
  ├── copy_from_sd.sh        # Copies images from SD card
  ├── sd_card_monitor.sh     # Monitors for SD card insertion
  ├── udev_sd_card.rules     # udev rules for auto-detection
  ├── udev_sd_card_wrapper.sh # Wrapper for udev execution
  ├── process_new_images.py  # Extracts metadata and inserts into DB
  ├── install_immich.sh      # Immich installation and configuration
  ├── setup_cron.sh          # Sets up cron job for metadata processing
  ├── setup_autostart.sh     # Configures auto-start on boot
  ├── test_metadata.py       # Test script (uses DSCF1949.JPG)
  └── DSCF1949.JPG           # Test image for metadata extraction
```

## Configuration

### Storage Locations
- **SD Card Copy Destination**: `~/images/` (organized by date: YYYY/MM/DD/)
- **Immich Library**: `~/images/library/`
- **External Images**: Mounted at `/mnt/images` in Immich container (read-only)

### Database
- **Host**: localhost
- **Databases**: 
  - `image_server` (image metadata)
  - `immich` (Immich application data)
- **User**: `image_server`
- **Credentials**: `~/.db_credentials` (not in git)

### Logs
- **Main log**: `~/image-server.log`
- **Cron log**: `~/image-server-cron.log`
- **udev log**: `/tmp/udev_sd_card.log`

Log rotation configured via `/etc/logrotate.d/image-server` (keeps 7 days of logs).

## Accessing Immich

**Local**: `http://localhost:2283` (direct access, only works locally)

**Via Tailscale with HTTPS** (from phone or other devices):
- `https://yourmachine.tail0xxxx.ts.net`
- **Note**: Direct HTTP access on port 2283 is disabled for security. Only HTTPS through nginx is available.

**For Mobile App**:
1. Ensure your phone is connected to Tailscale
2. In the Immich mobile app, enter the server URL: `https://yourmachine.tail0xxxx.ts.net`
3. If using a trusted Tailscale certificate (recommended), the app will connect without warnings
4. If using a self-signed certificate, you'll see a security warning - tap "Advanced" or "Continue" to accept it

The mobile app works great over Tailscale - no need for port forwarding or exposing your server to the internet.

### Setting Up Trusted SSL Certificate (Recommended)

For the best mobile app experience without certificate warnings, set up a trusted SSL certificate using Tailscale's built-in certificate feature:

1. **Enable HTTPS in Tailscale Admin Console**:
   - Go to: https://login.tailscale.com/admin/dns
   - Enable MagicDNS (if not already enabled)
   - Under "HTTPS Certificates", click "Enable HTTPS"
   - Acknowledge the public ledger notice

2. **Run the certificate setup script**:
   ```bash
   cd ~/image-server
   ./setup_letsencrypt.sh yourmachine.tail0xxxx.ts.net
   ```

   This will:
   - Request a Let's Encrypt certificate via Tailscale
   - Install it in nginx
   - Set up automatic renewal (certificates expire every 90 days)
   - Configure proper file permissions

3. **Verify it's working**:
   - Access `https://yourmachine.tail0xxxx.ts.net` in a browser - should show a trusted certificate
   - Mobile app should connect without certificate warnings

**Note**: The certificate auto-renews via cron job. No manual intervention needed.

## How It Works

### SD Card Processing Flow

1. **Detection**: udev rule detects SD card insertion (`/dev/sdc1` or similar)
2. **Wrapper**: `udev_sd_card_wrapper.sh` runs as root, switches to user context
3. **Monitor**: `sd_card_monitor.sh` waits for mount, creates lock file
4. **Copy**: `copy_from_sd.sh` scans `DCIM/` directories, copies new files
5. **Organization**: Files organized by date extracted from filename or current date
6. **Duplicate Check**: Skips files that already exist (by filename) - see below
7. **Eject**: Unmounts and ejects SD card when complete
8. **Notification**: Logs completion (can add desktop notification if needed)

### Duplicate Detection

The copy script performs **recursive duplicate detection** across the entire `~/images/` directory structure. This means:

- **Checks all subdirectories**: Searches `~/images/` recursively, including:
  - `~/images/2026/01/04/` (SD card copies)
  - `~/images/library/` (Immich phone uploads)
  - Any other subdirectories

- **Filename-based matching**: If a file with the same name exists anywhere in `~/images/`, it will be skipped

- **Prevents duplicates**: If you upload a photo from your phone to Immich (stored in `~/images/library/`), and later insert an SD card with the same file, the copy script will detect it and skip copying

**Example:**
```
Phone upload: ~/images/library/DSCF1949.JPG
SD card copy: Finds existing file → Skips copying
Result: No duplicate created
```

**Note**: This is filename-based only, not content-based. Files with different names but same content will both be copied.

### Metadata Extraction Flow

1. **Cron Trigger**: Runs every 30 minutes
2. **Scan**: `process_new_images.py` scans `~/images/` for image files
3. **Filter**: Only processes files not in database or with incomplete metadata
4. **Extract**: Uses `exiftool` to extract EXIF data
5. **Process**: DuckDB processes metadata in batches
6. **Insert**: Inserts/updates PostgreSQL with metadata
7. **Idempotent**: Safe to run multiple times - won't duplicate data

### Immich Integration

- Immich scans the external library (`/mnt/images`) recursively
- Creates thumbnails and indexes for search
- Metadata from PostgreSQL is separate from Immich's database
- Both systems can coexist - Immich for viewing, PostgreSQL for queries

## Troubleshooting

### SD Card Not Detected
- Check udev rules: `cat /etc/udev/rules.d/99-sd-card-image-server.rules`
- Check logs: `cat /tmp/udev_sd_card.log`
- Verify wrapper is executable: `ls -la ~/image-server/udev_sd_card_wrapper.sh`
- Test manually: `~/image-server/sd_card_monitor.sh`

### Immich Can't Connect to Database
- Verify PostgreSQL is running: `systemctl status postgresql@16-main`
- Check pg_hba.conf allows Docker network: `sudo grep 172.17 /etc/postgresql/16/main/pg_hba.conf`
- Verify DB_URL in `~/immich-app/.env`
- Check Immich logs: `docker logs immich_server --tail 50`

### Metadata Not Processing
- Check cron job: `crontab -l`
- Check cron log: `tail ~/image-server-cron.log`
- Manually test: 
  ```bash
  cd ~/image-server
  source venv/bin/activate
  python3 process_new_images.py
  ```
- Verify database connection: Check `~/.db_credentials` exists and is readable

### PostgreSQL Won't Start
- Check for VectorChord issues: `sudo grep vchord /etc/postgresql/16/main/postgresql.conf`
- If VectorChord isn't installed, comment out `shared_preload_libraries` line
- Check logs: `sudo journalctl -u postgresql@16-main -n 50`

## Security Considerations

### Current Security Posture

**✅ Good Practices:**
- Database credentials stored in `~/.db_credentials` with `chmod 600` (owner read/write only)
- `.db_credentials` is in `.gitignore` (not committed to git)
- Tailscale provides encrypted, authenticated access (no exposed ports)
- Immich external library mounted read-only (`:ro` flag)
- PostgreSQL only listens on localhost by default
- Docker network access restricted to specific subnet in `pg_hba.conf`

**⚠️ Areas to Review:**
- **PostgreSQL superuser**: `image_server` user has superuser privileges (required for Immich extensions) - consider if this is acceptable for your use case
- **Root execution**: udev wrapper runs as root (necessary for udev) but switches to user context immediately

### Automatic Security Fixes

The setup scripts automatically handle:
- ✅ **File permissions**: Sets `chmod 600` on `.db_credentials` and Immich `.env` files
- ✅ **PostgreSQL security**: Configures `pg_hba.conf` with `scram-sha-256` authentication (when available), sets proper file permissions
- ✅ **PostgreSQL network**: Verifies PostgreSQL is listening on localhost only (warns if listening on all interfaces)
- ✅ **Configurable paths**: Uses `config.sh` for username/paths (no hardcoded values)

**To customize username**: Edit `config.sh` before running setup scripts, or set `IMAGE_SERVER_USER` environment variable.

4. **Firewall**: Consider enabling UFW firewall (if not using Tailscale exclusively):
   ```bash
   sudo ufw enable
   sudo ufw allow from <tailscale-subnet>
   ```

5. **Regular updates**: Keep system and Docker images updated:
   ```bash
   sudo apt update && sudo apt upgrade
   cd ~/immich-app && docker compose pull
   ```

### For Production Use

- Use stronger database passwords (16+ characters, mixed case, numbers, symbols)
- Consider using PostgreSQL's `scram-sha-256` authentication instead of `md5`
- Set up automated backups
- Monitor logs for suspicious activity
- Consider using Docker secrets or environment variable files with restricted permissions
- Review Immich's security documentation: https://docs.immich.app/

## Future Enhancements

- [ ] Backblaze B2 backup integration
- [ ] Web interface for viewing metadata
- [ ] Automated backup scheduling
- [ ] Email notifications for SD card processing

## License

This project is provided as-is for personal use. Feel free to adapt it for your needs.

## Contributing

Found a bug or have an improvement? Open an issue or submit a PR!

---

**Built with**: PostgreSQL, DuckDB, Immich, Docker, Python, Bash
