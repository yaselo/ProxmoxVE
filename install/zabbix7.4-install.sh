#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.zabbix.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Keep PostgreSQL setup helper unchanged (you can override PG_VERSION earlier if needed)
PG_VERSION="17" setup_postgresql

# Install a specific Zabbix version (fixed to 7.4) and force Debian 13 repo files
ZABBIX_VER="7.4"
DEBIAN_TARGET="debian13"

msg_info "Installing Zabbix ${ZABBIX_VER} for ${DEBIAN_TARGET}"
cd /tmp

DEB_FILE="/tmp/zabbix-release_${ZABBIX_VER}-1+${DEBIAN_TARGET}_all.deb"
ZABBIX_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VER}/release/debian/pool/main/z/zabbix-release/$(basename "$DEB_FILE")"

if ! curl -fsSL "$ZABBIX_URL" -o "$DEB_FILE"; then
  # fallback to latest debian13 release package if specific named file not found
  FALLBACK_DEB="/tmp/zabbix-release_latest+${DEBIAN_TARGET}_all.deb"
  if curl -fsSL "$(curl -fsSL https://repo.zabbix.com/zabbix/ |
    grep -oP '(?<=href=\")[0-9]+\.[0-9]+(?=/\")' | sort -V | tail -n1 |
    xargs -I{} echo "https://repo.zabbix.com/zabbix/{}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+${DEBIAN_TARGET}_all.deb")" -o "$FALLBACK_DEB"; then
    DEB_FILE="$FALLBACK_DEB"
  else
    echo "Failed to download Zabbix release package for version ${ZABBIX_VER} and fallback. Aborting."
    exit 1
  fi
fi

$STD dpkg -i "$DEB_FILE"
$STD apt update

# --- Detect compatible PHP and PostgreSQL versions available in apt and choose packages accordingly ---
msg_info "Detecting available PHP and PostgreSQL versions (to ensure compatibility on Debian 13)"

# Detect PHP candidate version from apt (e.g. 8.2, 8.4...)
PHP_CANDIDATE=$(apt-cache policy php | awk '/Candidate:/ {print $2}')
if [ -z "$PHP_CANDIDATE" ] || [ "$PHP_CANDIDATE" = "(none)" ]; then
  # another try: find any php package candidate
  PHP_CANDIDATE=$(apt-cache policy 'php*' 2>/dev/null | grep -m1 -oP '\d+\.\d+' || true)
fi
# If local php binary exists, prefer its running version
if command -v php >/dev/null 2>&1; then
  PHP_LOCAL_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
  [ -n "$PHP_LOCAL_VER" ] && PHP_CANDIDATE="$PHP_LOCAL_VER"
fi

# Normalize to major.minor (e.g. 8.2)
PHP_VER=$(echo "$PHP_CANDIDATE" | grep -oP '^\d+\.\d+' || true)

# Prepare a list of php-pgsql candidates to try (prefer detected version, then common versions)
declare -a PHP_TRY_ORDER
if [ -n "$PHP_VER" ]; then
  PHP_TRY_ORDER+=("$PHP_VER")
fi
PHP_TRY_ORDER+=("8.4" "8.3" "8.2" "8.1" "8.0")

SELECTED_PHP_PGSQL=""
for v in "${PHP_TRY_ORDER[@]}"; do
  pkg="php${v}-pgsql"
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    SELECTED_PHP_PGSQL="$pkg"
    SELECTED_PHP_VERSION="$v"
    break
  fi
done

# If nothing found, fallback to generic 'php-pgsql' package (some systems provide it)
if [ -z "$SELECTED_PHP_PGSQL" ]; then
  if apt-cache show php-pgsql >/dev/null 2>&1; then
    SELECTED_PHP_PGSQL="php-pgsql"
    SELECTED_PHP_VERSION="unknown"
  else
    echo "Warning: no php-*-pgsql package available in apt indexes. The frontend may require manual PHP installation."
  fi
fi

# Detect PostgreSQL candidate available from apt (gives like 15,16,17)
PG_CANDIDATE=$(apt-cache policy postgresql | awk '/Candidate:/ {print $2}')
if [ -z "$PG_CANDIDATE" ] || [ "$PG_CANDIDATE" = "(none)" ]; then
  # look for 'postgresql-' packages
  PG_CANDIDATE=$(apt-cache search '^postgresql-[0-9]+' 2>/dev/null | head -n1 | grep -oP '\d+' || true)
fi
PG_MAJOR=$(echo "$PG_CANDIDATE" | grep -oP '^\d+' || true)

# Inspect Zabbix package metadata to see any explicit php/postgresql dependencies (best-effort)
ZBX_FRONTEND_DEPS=$(apt-cache show zabbix-frontend-php 2>/dev/null | awk '/Depends:/{print; exit}' || true)
ZBX_SERVER_DEPS=$(apt-cache show zabbix-server-pgsql 2>/dev/null | awk '/Depends:/{print; exit}' || true)

# Report detection results
echo "Detected PHP candidate: ${PHP_CANDIDATE:-none}"
echo "Selected PHP package for PostgreSQL integration: ${SELECTED_PHP_PGSQL:-none}"
echo "Detected PostgreSQL candidate: ${PG_CANDIDATE:-none}"
echo "Zabbix frontend package Depends: ${ZBX_FRONTEND_DEPS:-(no info)}"
echo "Zabbix server package Depends: ${ZBX_SERVER_DEPS:-(no info)}"

msg_ok "Detection complete"

# Install Zabbix server, frontend and the php pgsql package chosen above
# The install list: zabbix-server-pgsql zabbix-frontend-php <php_pgsql> zabbix-apache-conf zabbix-sql-scripts
INSTALL_PKGS=(zabbix-server-pgsql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts)
[ -n "$SELECTED_PHP_PGSQL" ] && INSTALL_PKGS+=("$SELECTED_PHP_PGSQL")

$STD apt install -y "${INSTALL_PKGS[@]}"
msg_ok "Installed Zabbix ${ZABBIX_VER} and chosen PHP/PostgreSQL integration packages"

# --- Agent selection (unchanged) ---
while true; do
  read -rp "Which agent do you want to install? [1=agent (classic), 2=agent2 (modern), default=1]: " AGENT_CHOICE
  case "$AGENT_CHOICE" in
  2)
    AGENT_PKG="zabbix-agent2"
    break
    ;;
  "" | 1)
    AGENT_PKG="zabbix-agent"
    break
    ;;
  *)
    echo "Invalid choice. Please enter 1 or 2."
    ;;
  esac
done
msg_ok "Selected $AGENT_PKG"

if [ "$AGENT_PKG" = "zabbix-agent2" ]; then
  echo "Choose plugins for Zabbix Agent2:"
  echo "1) PostgreSQL only (default, recommended)"
  echo "2) All plugins (may cause issues)"
  read -rp "Choose option [1-2]: " PLUGIN_CHOICE

  case "$PLUGIN_CHOICE" in
  2)
    $STD apt install -y zabbix-agent2 zabbix-agent2-plugin-*
    ;;
  *)
    $STD apt install -y zabbix-agent2 zabbix-agent2-plugin-postgresql
    ;;
  esac

  if [ -f /etc/zabbix/zabbix_agent2.d/plugins.d/nvidia.conf ]; then
    sed -i 's|^Plugins.NVIDIA.System.Path=.*|# Plugins.NVIDIA.System.Path=/usr/libexec/zabbix/zabbix-agent2-plugin-nvidia-gpu|' \
      /etc/zabbix/zabbix_agent2.d/plugins.d/nvidia.conf
  fi
else
  $STD apt install -y zabbix-agent
fi

msg_info "Setting up PostgreSQL"
DB_NAME=zabbixdb
DB_USER=zabbix
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | cut -c1-13)
$STD sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';"
$STD sudo -u postgres psql -c "CREATE DATABASE $DB_NAME WITH OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;"
$STD sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
$STD sudo -u postgres psql -c "ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';"
$STD sudo -u postgres psql -c "ALTER ROLE $DB_USER SET timezone TO 'UTC'"
{
  echo "Zabbix-Credentials"
  echo "Zabbix Database User: $DB_USER"
  echo "Zabbix Database Password: $DB_PASS"
  echo "Zabbix Database Name: $DB_NAME"
} >>~/zabbix.creds

zcat /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz | sudo -u $DB_USER psql $DB_NAME &>/dev/null
sed -i "s/^DBName=.*/DBName=$DB_NAME/" /etc/zabbix/zabbix_server.conf
sed -i "s/^DBUser=.*/DBUser=$DB_USER/" /etc/zabbix/zabbix_server.conf
sed -i "s/^# DBPassword=.*/DBPassword=$DB_PASS/" /etc/zabbix/zabbix_server.conf
msg_ok "Set up PostgreSQL"

msg_info "Configuring Fping"
if command -v fping >/dev/null 2>&1; then
  FPING_PATH=$(command -v fping)
  sed -i "s|^#\?FpingLocation=.*|FpingLocation=$FPING_PATH|" /etc/zabbix/zabbix_server.conf
fi

if command -v fping6 >/dev/null 2>&1; then
  FPING6_PATH=$(command -v fping6)
  sed -i "s|^#\?Fping6Location=.*|Fping6Location=$FPING6_PATH|" /etc/zabbix/zabbix_server.conf
fi
msg_ok "Configured Fping"

msg_info "Starting Services"
if [ "$AGENT_PKG" = "zabbix-agent2" ]; then
  AGENT_SERVICE="zabbix-agent2"
else
  AGENT_SERVICE="zabbix-agent"
fi

systemctl restart zabbix-server
systemctl enable -q --now zabbix-server $AGENT_SERVICE apache2
msg_ok "Started Services"

motd_ssh
customize

msg_info "Cleaning up"
rm -rf "$DEB_FILE"
$STD apt -y autoremove
$STD apt -y autoclean
$STD apt -y clean
msg_ok "Cleaned"
