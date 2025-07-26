#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: community-scripts (tteckster)  
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://supabase.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  sudo \
  mc \
  git \
  ca-certificates \
  gnupg \
  lsb-release \
  perl
msg_ok "Installed Dependencies"

get_latest_release() {
  curl -fsSL https://api.github.com/repos/"$1"/releases/latest | grep '"tag_name":' | cut -d'"' -f4
}

DOCKER_LATEST_VERSION=$(get_latest_release "moby/moby")
DOCKER_COMPOSE_LATEST_VERSION=$(get_latest_release "docker/compose")

msg_info "Installing Docker $DOCKER_LATEST_VERSION"
DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
mkdir -p $(dirname $DOCKER_CONFIG_PATH)
echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
$STD sh <(curl -fsSL https://get.docker.com)
msg_ok "Installed Docker $DOCKER_LATEST_VERSION"

msg_info "Installing Docker Compose $DOCKER_COMPOSE_LATEST_VERSION"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
msg_ok "Installed Docker Compose $DOCKER_COMPOSE_LATEST_VERSION"

msg_info "Setting up Supabase"
SUPABASE_DIR="/opt/supabase"
mkdir -p "$SUPABASE_DIR"
cd "$SUPABASE_DIR"

# Clone Supabase repository
$STD git clone --depth 1 https://github.com/supabase/supabase.git temp-repo

# Copy Docker files
cp -rf temp-repo/docker/* .
cp temp-repo/docker/.env.example .env

# Clean up temporary repo
rm -rf temp-repo

msg_ok "Supabase files configured"

msg_info "Generating secure secrets"
# Generate secure passwords using alphanumeric characters only to avoid sed issues
JWT_SECRET=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 16) 
DASHBOARD_PASSWORD=$(openssl rand -hex 12)

# Update .env file with secure values using perl for safer replacement
perl -i -pe "s/your-super-secret-and-long-postgres-password/\Q$POSTGRES_PASSWORD\E/g" .env
perl -i -pe "s/your-super-secret-jwt-token-with-at-least-32-characters-long/\Q$JWT_SECRET\E/g" .env
perl -i -pe "s/this_password_is_insecure_and_should_be_updated/\Q$DASHBOARD_PASSWORD\E/g" .env

# Set the site URL to the container IP
CONTAINER_IP=$(get_current_ip)
sed -i "s|http://localhost:3000|http://$CONTAINER_IP:8000|g" .env
sed -i "s|localhost|$CONTAINER_IP|g" .env

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
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"