#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: community-scripts (tteckster)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://supabase.com/

APP="Supabase"
var_tags="${var_tags:-database;postgresql;backend}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  msg_info "Updating base system"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Base system updated"

  msg_info "Updating Docker Engine"
  $STD apt-get install --only-upgrade -y docker-ce docker-ce-cli containerd.io
  msg_ok "Docker Engine updated"

  if [[ -f /usr/local/lib/docker/cli-plugins/docker-compose ]]; then
    msg_info "Updating Docker Compose"
    COMPOSE_NEW_VERSION=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_NEW_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    msg_ok "Docker Compose updated"
  fi

  SUPABASE_DIR="/opt/supabase"
  if [[ -d "$SUPABASE_DIR" ]]; then
    msg_info "Updating Supabase"
    cd "$SUPABASE_DIR"
    $STD git pull
    $STD docker compose pull
    msg_warn "To apply updates, restart Supabase with: docker compose down && docker compose up -d"
    msg_ok "Supabase updated"
  fi

  msg_info "Cleaning up"
  $STD apt-get -y autoremove
  $STD apt-get -y autoclean
  msg_ok "Cleanup complete"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${TAB}${NETWORK}${TAB}${GN}Dashboard:${CL} ${TAB}${TAB}http://$(get_current_ip):8000"
echo -e "${TAB}${NETWORK}${TAB}${GN}Default Username:${CL} ${TAB}supabase"
echo -e "${TAB}${NETWORK}${TAB}${GN}Default Password:${CL} ${TAB}this_password_is_insecure_and_should_be_updated"
echo -e "${TAB}${INFO}${TAB}${YW}IMPORTANT: Change default credentials immediately!${CL}"