#!/bin/bash
# Security hardening script for image server
# Sets up firewall, SSH security, fail2ban, and automatic updates

set -e

echo "=== Security Hardening Setup ==="
echo ""
echo "This script will:"
echo "1. Configure UFW firewall"
echo "2. Harden SSH configuration (key-based auth recommended)"
echo "3. Install and configure fail2ban"
echo "4. Configure automatic security updates"
echo ""

# Check if running as root for certain operations
if [ "$EUID" -ne 0 ]; then 
    echo "Some operations require sudo. You'll be prompted for your password."
    echo ""
fi

# 1. Firewall (UFW)
echo "=== 1. Configuring Firewall (UFW) ==="
if command -v ufw &> /dev/null; then
    echo "UFW is installed"
    
    # Check if already enabled
    if sudo ufw status | grep -q "Status: active"; then
        echo "✓ Firewall is already enabled"
    else
        echo "Configuring firewall..."
        
        # Default policies
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        
        # Allow SSH (important - don't lock yourself out!)
        sudo ufw allow ssh
        
        # Allow Tailscale interface (if exists)
        if ip link show tailscale0 &> /dev/null; then
            sudo ufw allow in on tailscale0
            echo "✓ Allowed Tailscale interface"
        fi
        
        # Allow Docker containers to reach PostgreSQL on host
        if command -v docker &> /dev/null; then
            # Get Docker bridge network subnets and allow them to reach PostgreSQL
            for subnet in $(docker network ls -q | xargs -I {} docker network inspect {} -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -v '^$'); do
                sudo ufw allow from "$subnet" to any port 5432 comment "Docker to PostgreSQL"
                echo "✓ Allowed Docker subnet $subnet to PostgreSQL"
            done
            # Also allow the common Docker bridge range as fallback
            if ! sudo ufw status | grep -q "172.18.0.0/16"; then
                sudo ufw allow from 172.18.0.0/16 to any port 5432 comment "Docker to PostgreSQL"
                echo "✓ Allowed Docker bridge 172.18.0.0/16 to PostgreSQL"
            fi
        fi
        
        # Enable firewall
        echo ""
        echo "Enabling firewall..."
        echo "y" | sudo ufw enable
        
        echo "✓ Firewall configured and enabled"
    fi
    
    echo ""
    echo "Current firewall status:"
    sudo ufw status verbose
else
    echo "Installing UFW..."
    sudo apt-get update
    sudo apt-get install -y ufw
    
    # Configure firewall
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    
    if ip link show tailscale0 &> /dev/null; then
        sudo ufw allow in on tailscale0
    fi
    
    # Allow Docker containers to reach PostgreSQL on host
    if command -v docker &> /dev/null; then
        for subnet in $(docker network ls -q | xargs -I {} docker network inspect {} -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | grep -v '^$'); do
            sudo ufw allow from "$subnet" to any port 5432 comment "Docker to PostgreSQL"
        done
        sudo ufw allow from 172.18.0.0/16 to any port 5432 comment "Docker to PostgreSQL"
    fi
    
    echo "y" | sudo ufw enable
    echo "✓ UFW installed and configured"
fi

echo ""

# 2. SSH Security
echo "=== 2. SSH Security Configuration ==="
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

# Backup SSH config
if [ ! -f "$SSH_CONFIG_BACKUP" ]; then
    sudo cp "$SSH_CONFIG" "$SSH_CONFIG_BACKUP"
    echo "✓ Backed up SSH config to $SSH_CONFIG_BACKUP"
fi

# Check if password authentication is currently enabled
PASSWORD_AUTH=$(sudo grep -E "^PasswordAuthentication|^#PasswordAuthentication" "$SSH_CONFIG" | tail -1)

echo ""
echo "Current SSH password authentication setting:"
echo "$PASSWORD_AUTH"
echo ""

# Check if SSH keys are set up
if [ -f ~/.ssh/authorized_keys ] && [ -s ~/.ssh/authorized_keys ]; then
    KEY_COUNT=$(wc -l < ~/.ssh/authorized_keys)
    echo "✓ SSH keys found: $KEY_COUNT key(s) in ~/.ssh/authorized_keys"
    HAS_KEYS=true
else
    echo "⚠ Warning: No SSH keys found in ~/.ssh/authorized_keys"
    HAS_KEYS=false
fi

echo ""
read -p "Disable password authentication and require SSH keys? (recommended if you have SSH keys set up) [y/N]: " DISABLE_PASSWORD

if [ "$DISABLE_PASSWORD" = "y" ] || [ "$DISABLE_PASSWORD" = "Y" ]; then
    if [ "$HAS_KEYS" = false ]; then
        echo ""
        echo "⚠ WARNING: No SSH keys detected!"
        echo "Disabling password auth without SSH keys will lock you out!"
        read -p "Are you sure you want to continue? [y/N]: " CONFIRM
        if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
            echo "Skipping SSH password auth disable"
            DISABLE_PASSWORD="n"
        fi
    fi
    
    if [ "$DISABLE_PASSWORD" = "y" ] || [ "$DISABLE_PASSWORD" = "Y" ]; then
        # Disable password authentication
        sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
        sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
        
        # Ensure root login is restricted
        if ! sudo grep -q "^PermitRootLogin" "$SSH_CONFIG"; then
            echo "PermitRootLogin no" | sudo tee -a "$SSH_CONFIG" > /dev/null
        else
            sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
        fi
        
        echo "✓ SSH configured for key-based authentication only"
        echo "  Password authentication: disabled"
        echo "  Root login: disabled"
        SSH_CHANGED=true
    fi
else
    echo "Keeping password authentication enabled (less secure but safer if keys not set up)"
    SSH_CHANGED=false
fi

# Restart SSH if config changed
if [ "$SSH_CHANGED" = true ]; then
    echo ""
    echo "Testing SSH configuration..."
    if sudo sshd -t; then
        echo "✓ SSH configuration is valid"
        echo ""
        echo "⚠ IMPORTANT: SSH config will be reloaded."
        echo "   Make sure your SSH keys are working before closing this session!"
        echo "   If you get locked out, restore from: $SSH_CONFIG_BACKUP"
        echo ""
        read -p "Reload SSH service now? (recommended) [Y/n]: " RELOAD_SSH
        if [ "$RELOAD_SSH" != "n" ] && [ "$RELOAD_SSH" != "N" ]; then
            sudo systemctl reload sshd
            echo "✓ SSH service reloaded"
        else
            echo "⚠ SSH config changes not applied. Run 'sudo systemctl reload sshd' when ready"
        fi
    else
        echo "✗ SSH configuration has errors - not reloading"
        echo "   Please review $SSH_CONFIG"
    fi
fi

echo ""

# 3. Fail2ban
echo "=== 3. Installing Fail2ban ==="
if command -v fail2ban-client &> /dev/null; then
    echo "✓ Fail2ban is already installed"
    
    # Check if SSH jail is active
    if sudo fail2ban-client status sshd &> /dev/null; then
        echo "✓ SSH jail is configured"
    else
        echo "⚠ SSH jail not found (may need configuration)"
    fi
else
    echo "Installing fail2ban..."
    sudo apt-get update
    sudo apt-get install -y fail2ban
    
    # Enable and start fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
    
    echo "✓ Fail2ban installed and started"
fi

echo ""

# 4. Automatic Security Updates
echo "=== 4. Configuring Automatic Security Updates ==="
if command -v unattended-upgrades &> /dev/null; then
    echo "✓ unattended-upgrades is installed"
else
    echo "Installing unattended-upgrades..."
    sudo apt-get update
    sudo apt-get install -y unattended-upgrades
    echo "✓ unattended-upgrades installed"
fi

# Enable automatic security updates
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
    if grep -q "APT::Periodic::Update-Package-Lists \"1\";" /etc/apt/apt.conf.d/20auto-upgrades; then
        echo "✓ Automatic updates already configured"
    else
        echo "Configuring automatic updates..."
        cat | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
        echo "✓ Automatic updates configured"
    fi
else
    echo "Configuring automatic updates..."
    cat | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    echo "✓ Automatic updates configured"
fi

echo ""

# Summary
echo "=== Security Hardening Complete ==="
echo ""
echo "Summary:"
echo "✓ Firewall (UFW) configured"
if [ "$SSH_CHANGED" = true ]; then
    echo "✓ SSH hardened (key-based auth only)"
else
    echo "  SSH password auth: enabled (consider disabling if you have SSH keys)"
fi
echo "✓ Fail2ban installed"
echo "✓ Automatic security updates configured"
echo ""
echo "=== Verification Steps ==="
echo ""
echo "1. Check firewall status:"
echo "   sudo ufw status verbose"
echo ""
echo "2. Check SSH configuration:"
echo "   sudo sshd -T | grep -E 'passwordauthentication|pubkeyauthentication|permitrootlogin'"
echo ""
echo "3. Check fail2ban status:"
echo "   sudo fail2ban-client status sshd"
echo ""
echo "4. Check automatic updates:"
echo "   cat /etc/apt/apt.conf.d/20auto-upgrades"
echo ""
echo "5. Test SSH access from another terminal (before closing this one!):"
echo "   ssh your-server-hostname"
echo ""
echo "⚠ IMPORTANT: If you disabled password authentication, make sure SSH keys work!"
echo "   Test from another terminal before closing this session."
echo ""
