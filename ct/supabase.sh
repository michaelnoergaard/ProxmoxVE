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

# Override for fork-specific installation
FORK_INSTALL_URL="https://raw.githubusercontent.com/michaelnoergaard/ProxmoxVE/main/install/supabase-install.sh"

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

# Custom build function to use fork-specific installation
custom_build_container() {
  if [ "$VERBOSE" == "yes" ]; then set -x; fi

  NET_STRING="-net0 name=eth0,bridge=$BRG$MAC,ip=$NET$GATE$VLAN$MTU"
  case "$IPV6_METHOD" in
  auto) NET_STRING="$NET_STRING,ip6=auto" ;;
  dhcp) NET_STRING="$NET_STRING,ip6=dhcp" ;;
  static)
    NET_STRING="$NET_STRING,ip6=$IPV6_ADDR"
    [ -n "$IPV6_GATE" ] && NET_STRING="$NET_STRING,gw6=$IPV6_GATE"
    ;;
  none) ;;
  esac
  if [ "$CT_TYPE" == "1" ]; then
    FEATURES="keyctl=1,nesting=1"
  else
    FEATURES="nesting=1"
  fi

  if [ "$ENABLE_FUSE" == "yes" ]; then
    FEATURES="$FEATURES,fuse=1"
  fi

  if [[ $DIAGNOSTICS == "yes" ]]; then
    post_to_api
  fi

  TEMP_DIR=$(mktemp -d)
  pushd "$TEMP_DIR" >/dev/null
  if [ "$var_os" == "alpine" ]; then
    export FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/alpine-install.func)"
  else
    export FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func)"
  fi

  export DIAGNOSTICS="$DIAGNOSTICS"
  export RANDOM_UUID="$RANDOM_UUID"
  export CACHER="$APT_CACHER"
  export CACHER_IP="$APT_CACHER_IP"
  export tz="$timezone"
  export APPLICATION="$APP"
  export app="$NSAPP"
  export PASSWORD="$PW"
  export VERBOSE="$VERBOSE"
  export SSH_ROOT="${SSH}"
  export SSH_AUTHORIZED_KEY
  export CTID="$CT_ID"
  export CTTYPE="$CT_TYPE"
  export ENABLE_FUSE="$ENABLE_FUSE"
  export ENABLE_TUN="$ENABLE_TUN"
  export PCT_OSTYPE="$var_os"
  export PCT_OSVERSION="$var_version"
  export PCT_DISK_SIZE="$DISK_SIZE"
  export PCT_OPTIONS="
    -features $FEATURES
    -hostname $HN
    -tags $TAGS
    $SD
    $NS
    $NET_STRING
    -onboot 1
    -cores $CORE_COUNT
    -memory $RAM_SIZE
    -unprivileged $CT_TYPE
    $PW
  "
  # This executes create_lxc.sh and creates the container and .conf file
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/create_lxc.sh)" $?

  LXC_CONFIG="/etc/pve/lxc/${CTID}.conf"

  # USB passthrough for privileged LXC (CT_TYPE=0)
  if [ "$CT_TYPE" == "0" ]; then
    cat <<EOF >>"$LXC_CONFIG"
# USB passthrough
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.cgroup2.devices.allow: c 188:* rwm
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/serial/by-id  dev/serial/by-id  none bind,optional,create=dir
lxc.mount.entry: /dev/ttyUSB0       dev/ttyUSB0       none bind,optional,create=file
lxc.mount.entry: /dev/ttyUSB1       dev/ttyUSB1       none bind,optional,create=file
lxc.mount.entry: /dev/ttyACM0       dev/ttyACM0       none bind,optional,create=file
lxc.mount.entry: /dev/ttyACM1       dev/ttyACM1       none bind,optional,create=file
EOF
  fi

  # VAAPI passthrough for privileged containers or known apps
  VAAPI_APPS=(
    "immich"
    "Channels"
    "Emby"
    "ErsatzTV"
    "Frigate"
    "Jellyfin"
    "Plex"
    "Scrypted"
    "Tdarr"
    "Unmanic"
    "Ollama"
    "FileFlows"
    "Open WebUI"
  )

  is_vaapi_app=false
  for vaapi_app in "${VAAPI_APPS[@]}"; do
    if [[ "$APP" == "$vaapi_app" ]]; then
      is_vaapi_app=true
      break
    fi
  done

  if ([ "$CT_TYPE" == "0" ] || [ "$is_vaapi_app" == "true" ]) &&
    ([[ -e /dev/dri/renderD128 ]] || [[ -e /dev/dri/card0 ]] || [[ -e /dev/fb0 ]]); then

    echo ""
    msg_custom "⚙️ " "\e[96m" "Configuring VAAPI passthrough for LXC container"
    if [ "$CT_TYPE" != "0" ]; then
      msg_custom "⚠️ " "\e[33m" "Container is unprivileged – VAAPI passthrough may not work without additional host configuration (e.g., idmap)."
    fi
    msg_custom "ℹ️ " "\e[96m" "VAAPI enables GPU hardware acceleration (e.g., for video transcoding in Jellyfin or Plex)."
    echo ""
    read -rp "➤ Automatically mount all available VAAPI devices? [Y/n]: " VAAPI_ALL

    if [[ "$VAAPI_ALL" =~ ^[Yy]$|^$ ]]; then
      if [ "$CT_TYPE" == "0" ]; then
        # PRV Container → alles zulässig
        [[ -e /dev/dri/renderD128 ]] && {
          echo "lxc.cgroup2.devices.allow: c 226:128 rwm" >>"$LXC_CONFIG"
          echo "lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file" >>"$LXC_CONFIG"
        }
        [[ -e /dev/dri/card0 ]] && {
          echo "lxc.cgroup2.devices.allow: c 226:0 rwm" >>"$LXC_CONFIG"
          echo "lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file" >>"$LXC_CONFIG"
        }
        [[ -e /dev/fb0 ]] && {
          echo "lxc.cgroup2.devices.allow: c 29:0 rwm" >>"$LXC_CONFIG"
          echo "lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file" >>"$LXC_CONFIG"
        }
        [[ -d /dev/dri ]] && {
          echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >>"$LXC_CONFIG"
        }
      else
        # UNPRV Container → nur devX für UI
        [[ -e /dev/dri/card0 ]] && echo "dev0: /dev/dri/card0,gid=44" >>"$LXC_CONFIG"
        [[ -e /dev/dri/card1 ]] && echo "dev0: /dev/dri/card1,gid=44" >>"$LXC_CONFIG"
        [[ -e /dev/dri/renderD128 ]] && echo "dev1: /dev/dri/renderD128,gid=104" >>"$LXC_CONFIG"
      fi
    fi

  fi
  if [ "$CT_TYPE" == "1" ] && [ "$is_vaapi_app" == "true" ]; then
    if [[ -e /dev/dri/card0 ]]; then
      echo "dev0: /dev/dri/card0,gid=44" >>"$LXC_CONFIG"
    elif [[ -e /dev/dri/card1 ]]; then
      echo "dev0: /dev/dri/card1,gid=44" >>"$LXC_CONFIG"
    fi
    if [[ -e /dev/dri/renderD128 ]]; then
      echo "dev1: /dev/dri/renderD128,gid=104" >>"$LXC_CONFIG"
    fi
  fi

  # TUN device passthrough
  if [ "$ENABLE_TUN" == "yes" ]; then
    cat <<EOF >>"$LXC_CONFIG"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  fi

  # This starts the container and executes <app>-install.sh
  msg_info "Starting LXC Container"
  pct start "$CTID"

  # wait for status 'running'
  for i in {1..10}; do
    if pct status "$CTID" | grep -q "status: running"; then
      msg_ok "Started LXC Container"
      break
    fi
    sleep 1
    if [ "$i" -eq 10 ]; then
      msg_error "LXC Container did not reach running state"
      exit 1
    fi
  done

  if [ "$var_os" != "alpine" ]; then
    msg_info "Waiting for network in LXC container"
    for i in {1..10}; do
      if pct exec "$CTID" -- ping -c1 -W1 deb.debian.org >/dev/null 2>&1; then
        msg_ok "Network in LXC is reachable"
        break
      fi
      if [ "$i" -lt 10 ]; then
        msg_warn "No network yet in LXC (try $i/10) – waiting..."
        sleep 3
      else
        msg_error "No network in LXC after waiting."
        read -r -p "Set fallback DNS (1.1.1.1/8.8.8.8)? [y/N]: " choice
        case "$choice" in
        [yY]*)
          pct set "$CTID" --nameserver 1.1.1.1
          pct set "$CTID" --nameserver 8.8.8.8
          if pct exec "$CTID" -- ping -c1 -W1 deb.debian.org >/dev/null 2>&1; then
            msg_ok "Network reachable after DNS fallback"
          else
            msg_error "Still no network/DNS in LXC! Aborting customization."
            exit 1
          fi
          ;;
        *)
          msg_error "Aborted by user – no DNS fallback set."
          exit 1
          ;;
        esac
      fi
    done
  fi

  msg_info "Customizing LXC Container"
  : "${tz:=Etc/UTC}"
  if [ "$var_os" == "alpine" ]; then
    sleep 3
    pct exec "$CTID" -- /bin/sh -c 'cat <<EOF >/etc/apk/repositories
http://dl-cdn.alpinelinux.org/alpine/latest-stable/main
http://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF'
    pct exec "$CTID" -- ash -c "apk add bash newt curl openssh nano mc ncurses jq >/dev/null"
  else
    sleep 3
    pct exec "$CTID" -- bash -c "sed -i '/$LANG/ s/^# //' /etc/locale.gen"
    pct exec "$CTID" -- bash -c "locale_line=\$(grep -v '^#' /etc/locale.gen | grep -E '^[a-zA-Z]' | awk '{print \$1}' | head -n 1) && \
    echo LANG=\$locale_line >/etc/default/locale && \
    locale-gen >/dev/null && \
    export LANG=\$locale_line"

    if [[ -z "${tz:-}" ]]; then
      tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Etc/UTC")
    fi
    if pct exec "$CTID" -- test -e "/usr/share/zoneinfo/$tz"; then
      pct exec "$CTID" -- bash -c "tz='$tz'; echo \"\$tz\" >/etc/timezone && ln -sf \"/usr/share/zoneinfo/\$tz\" /etc/localtime"
    else
      msg_warn "Skipping timezone setup – zone '$tz' not found in container"
    fi

    pct exec "$CTID" -- bash -c "apt-get update >/dev/null && apt-get install -y sudo curl mc gnupg2 jq >/dev/null"
  fi
  msg_ok "Customized LXC Container"

  # Use fork-specific installation script
  msg_info "Installing Supabase from fork repository"
  lxc-attach -n "$CTID" -- bash -c "$(curl -fsSL $FORK_INSTALL_URL)" $?
}

start
custom_build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${TAB}${NETWORK}${TAB}${GN}Dashboard:${CL} ${TAB}${TAB}http://$(get_current_ip):8000"
echo -e "${TAB}${NETWORK}${TAB}${GN}Default Username:${CL} ${TAB}supabase"
echo -e "${TAB}${NETWORK}${TAB}${GN}Default Password:${CL} ${TAB}this_password_is_insecure_and_should_be_updated"
echo -e "${TAB}${INFO}${TAB}${YW}IMPORTANT: Change default credentials immediately!${CL}"