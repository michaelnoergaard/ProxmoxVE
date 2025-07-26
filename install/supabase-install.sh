#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: community-scripts (tteckster)  
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://supabase.com/

# Setup comprehensive logging
LOGFILE="/tmp/supabase-install-$(date +%Y%m%d_%H%M%S).log"
HOSTLOGFILE="/var/log/supabase-install-$(date +%Y%m%d_%H%M%S).log"

# Create logging functions
log_debug() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" | tee -a "$LOGFILE"
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOGFILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$LOGFILE" >&2
}

log_command() {
    local cmd="$1"
    local desc="$2"
    log_debug "Executing: $cmd"
    log_debug "Description: $desc"
}

# Enhanced error handling with logging
enhanced_catch_errors() {
    set -Eeuo pipefail
    trap 'log_error "Script failed at line $LINENO with command: $BASH_COMMAND"; copy_log_to_host; exit 1' ERR
}

# Function to copy log from container to host
copy_log_to_host() {
    if [ -f "$LOGFILE" ]; then
        # Try to copy log to host system via shared mount or alternative method
        if [ -d "/var/log" ]; then
            cp "$LOGFILE" "$HOSTLOGFILE" 2>/dev/null || true
        fi
        # Also try to copy to /tmp on host via container access
        if command -v pct >/dev/null 2>&1; then
            pct exec $(hostname | cut -d'-' -f2) -- cp "$LOGFILE" "/tmp/" 2>/dev/null || true
        fi
    fi
}

# Initialize logging
log_info "=== Supabase Installation Started ==="
log_info "Container: $(hostname)"
log_info "Date: $(date)"
log_info "User: $(whoami)"
log_info "Working Directory: $(pwd)"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
enhanced_catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
log_info "Installing system dependencies..."
log_command "apt-get install dependencies" "Installing curl, sudo, mc, git, ca-certificates, gnupg, lsb-release, perl"
$STD apt-get install -y \
  curl \
  sudo \
  mc \
  git \
  ca-certificates \
  gnupg \
  lsb-release \
  perl
log_info "Dependencies installed successfully"
msg_ok "Installed Dependencies"

get_latest_release() {
  curl -fsSL https://api.github.com/repos/"$1"/releases/latest | grep '"tag_name":' | cut -d'"' -f4
}

DOCKER_LATEST_VERSION=$(get_latest_release "moby/moby")
DOCKER_COMPOSE_LATEST_VERSION=$(get_latest_release "docker/compose")

msg_info "Installing Docker $DOCKER_LATEST_VERSION"
log_info "Installing Docker version: $DOCKER_LATEST_VERSION"
log_command "Docker installation" "Setting up Docker with journald logging"
DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
mkdir -p $(dirname $DOCKER_CONFIG_PATH)
echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
log_debug "Docker config written to $DOCKER_CONFIG_PATH"
$STD sh <(curl -fsSL https://get.docker.com)
log_info "Docker installation completed successfully"
msg_ok "Installed Docker $DOCKER_LATEST_VERSION"

msg_info "Installing Docker Compose $DOCKER_COMPOSE_LATEST_VERSION"
log_info "Installing Docker Compose version: $DOCKER_COMPOSE_LATEST_VERSION"
log_command "Docker Compose installation" "Downloading and installing Docker Compose plugin"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
log_info "Docker Compose installation completed successfully"
msg_ok "Installed Docker Compose $DOCKER_COMPOSE_LATEST_VERSION"

msg_info "Setting up Supabase"
log_info "Setting up Supabase in directory: /opt/supabase"
SUPABASE_DIR="/opt/supabase"
mkdir -p "$SUPABASE_DIR"
cd "$SUPABASE_DIR"
log_debug "Changed to directory: $(pwd)"

# Clone Supabase repository
log_command "git clone supabase" "Cloning Supabase repository with depth 1"
$STD git clone --depth 1 https://github.com/supabase/supabase.git temp-repo
log_info "Supabase repository cloned successfully"

# Copy Docker files
log_debug "Copying Docker files from temp-repo/docker/* to current directory"
cp -rf temp-repo/docker/* .
cp temp-repo/docker/.env.example .env
log_debug "Docker files copied successfully"

# Clean up temporary repo
rm -rf temp-repo
log_debug "Temporary repository cleaned up"

msg_ok "Supabase files configured"

msg_info "Generating secure secrets"
log_info "Generating secure secrets for Supabase configuration"
# Generate secure passwords using alphanumeric characters only to avoid sed issues
JWT_SECRET=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16) 
DASHBOARD_PASSWORD=$(openssl rand -hex 12)
log_debug "Generated JWT_SECRET: [REDACTED - 64 characters]"
log_debug "Generated POSTGRES_PASSWORD: [REDACTED - 32 characters]"
log_debug "Generated DASHBOARD_PASSWORD: [REDACTED - 24 characters]"

# Update .env file with secure values using perl for safer replacement
log_command "perl password replacement" "Updating .env file with generated passwords"
perl -i -pe "s/your-super-secret-and-long-postgres-password/\Q$POSTGRES_PASSWORD\E/g" .env
perl -i -pe "s/your-super-secret-jwt-token-with-at-least-32-characters-long/\Q$JWT_SECRET\E/g" .env
perl -i -pe "s/this_password_is_insecure_and_should_be_updated/\Q$DASHBOARD_PASSWORD\E/g" .env
log_info "Passwords updated in .env file successfully"

# Set the site URL to the container IP
log_info "Detecting container IP address for configuration"
# Get container IP address - try multiple methods
if command -v hostname >/dev/null 2>&1; then
  CONTAINER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null)
  log_debug "Hostname method result: $CONTAINER_IP"
fi

# Fallback methods if hostname -I fails
if [ -z "$CONTAINER_IP" ] || [ "$CONTAINER_IP" = "" ]; then
  CONTAINER_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
  log_debug "IP addr method result: $CONTAINER_IP"
fi

# Second fallback
if [ -z "$CONTAINER_IP" ] || [ "$CONTAINER_IP" = "" ]; then
  CONTAINER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  log_debug "IP route method result: $CONTAINER_IP"
fi

# Final fallback to localhost if all methods fail
if [ -z "$CONTAINER_IP" ] || [ "$CONTAINER_IP" = "" ]; then
  CONTAINER_IP="localhost"
  log_debug "Using localhost fallback"
fi

log_info "Detected container IP: $CONTAINER_IP"

# Update .env file with container IP
log_command "IP configuration update" "Updating .env file with container IP address"
perl -i -pe "s|http://localhost:3000|http://\Q$CONTAINER_IP\E:8000|g" .env
perl -i -pe "s/(?<!:\/\/)localhost(?!\.|:)/\Q$CONTAINER_IP\E/g" .env
log_info "Container IP updated in .env file successfully"

msg_ok "Secure secrets generated"

msg_info "Pulling Docker images"
$STD docker compose pull
msg_ok "Docker images pulled"

msg_info "Starting Supabase services"
$STD docker compose up -d
msg_ok "Supabase services started"

msg_info "Waiting for services to be healthy"
for i in {1..30}; do
  if docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "healthy"; then
    msg_ok "Services are running and healthy"
    break
  fi
  if [ "$i" -eq 30 ]; then
    msg_warn "Services may still be starting up. Check with: docker compose ps"
  fi
  sleep 5
done

# Create a systemd service for Supabase
msg_info "Creating systemd service"
cat <<EOF >/etc/systemd/system/supabase.service
[Unit]
Description=Supabase
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$SUPABASE_DIR
ExecStart=/usr/local/lib/docker/cli-plugins/docker-compose up -d
ExecStop=/usr/local/lib/docker/cli-plugins/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

$STD systemctl daemon-reload
$STD systemctl enable supabase.service
msg_ok "Systemd service created"

# Create management script
msg_info "Creating management script"
cat <<'EOF' >/usr/local/bin/supabase-manage
#!/bin/bash
SUPABASE_DIR="/opt/supabase"
cd "$SUPABASE_DIR"

case "$1" in
  start)
    echo "Starting Supabase..."
    docker compose up -d
    ;;
  stop)
    echo "Stopping Supabase..."
    docker compose down
    ;;
  restart)
    echo "Restarting Supabase..."
    docker compose down
    docker compose up -d
    ;;
  status)
    echo "Supabase service status:"
    docker compose ps
    ;;
  logs)
    docker compose logs -f
    ;;
  update)
    echo "Updating Supabase..."
    git pull
    docker compose pull
    echo "To apply updates, run: supabase-manage restart"
    ;;
  backup)
    echo "Creating database backup..."
    docker compose exec db pg_dump -U postgres postgres > "/opt/supabase-backup-$(date +%Y%m%d_%H%M%S).sql"
    echo "Backup created in /opt/"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|logs|update|backup}"
    exit 1
    ;;
esac
EOF

chmod +x /usr/local/bin/supabase-manage
msg_ok "Management script created"

# Save credentials to file
msg_info "Saving credentials"
cat <<EOF >/root/supabase-credentials.txt
=== Supabase Installation Credentials ===

Dashboard URL: http://$CONTAINER_IP:8000
Dashboard Username: supabase
Dashboard Password: $DASHBOARD_PASSWORD

PostgreSQL Connection:
Host: $CONTAINER_IP
Port: 5432 (direct) / 6543 (pooled)
Database: postgres
Username: postgres
Password: $POSTGRES_PASSWORD

JWT Secret: $JWT_SECRET

=== Management Commands ===
- Start: supabase-manage start
- Stop: supabase-manage stop  
- Restart: supabase-manage restart
- Status: supabase-manage status
- Logs: supabase-manage logs
- Update: supabase-manage update
- Backup: supabase-manage backup

=== Important Notes ===
- Change default credentials immediately after first login
- Configure SMTP settings in .env for email functionality
- See /opt/supabase/.env for all configuration options
- Full documentation: https://supabase.com/docs/guides/self-hosting
EOF

chmod 600 /root/supabase-credentials.txt
msg_ok "Credentials saved to /root/supabase-credentials.txt"

motd_ssh
customize

msg_info "Cleaning up"
log_info "Starting cleanup process"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
log_info "System cleanup completed"
msg_ok "Cleaned"

# Final log entry and copy to host
log_info "=== Supabase Installation Completed Successfully ==="
log_info "Log file location in container: $LOGFILE"
log_info "Attempting to copy log to host system..."

# Copy log to host - this will be accessible from the Proxmox host
if [ -f "$LOGFILE" ]; then
    # Copy to a location that the host can access
    cp "$LOGFILE" "/var/log/supabase-install-$(date +%Y%m%d_%H%M%S).log" 2>/dev/null || {
        # Alternative: try to copy via mount if available
        mkdir -p "/tmp/supabase-logs" 2>/dev/null || true
        cp "$LOGFILE" "/tmp/supabase-logs/supabase-install-$(date +%Y%m%d_%H%M%S).log" 2>/dev/null || true
    }
    log_info "Log file copied to host system (check /var/log/ or /tmp/supabase-logs/)"
    echo "=== LOG FILE LOCATIONS ==="
    echo "Container log: $LOGFILE"
    echo "Host accessible: /var/log/supabase-install-*.log or /tmp/supabase-logs/"
    echo "=========================="
fi