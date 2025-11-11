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

# 使用 PostgreSQL 16（与您的要求一致），并调用原有 helper（保持原脚本行为）
PG_VERSION="16" setup_postgresql

# 固定为 Zabbix 7.4，目标 Debian 13 仓库（不再包含任何回退下载逻辑）
ZABBIX_VER="7.4"
DEBIAN_TARGET="debian13"

msg_info "Installing Zabbix ${ZABBIX_VER} for ${DEBIAN_TARGET}"
cd /tmp

# 直接使用 7.4 + debian13 的 release deb；如果下载失败则中止（按您的要求删除回退逻辑）
DEB_FILE="/tmp/zabbix-release_${ZABBIX_VER}-1+${DEBIAN_TARGET}_all.deb"
ZABBIX_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VER}/release/debian/pool/main/z/zabbix-release/$(basename "$DEB_FILE")"

if ! curl -fsSL "$ZABBIX_URL" -o "$DEB_FILE"; then
  echo "Failed to download exact Zabbix release package: $ZABBIX_URL"
  echo "This script installs only Zabbix ${ZABBIX_VER} for ${DEBIAN_TARGET}. Aborting."
  exit 1
fi

$STD dpkg -i "$DEB_FILE"
$STD apt update

# 明确安装 PostgreSQL 16（与 PG_VERSION 保持一致并且 7.4 推荐使用 16）
msg_info "Ensuring PostgreSQL ${PG_VERSION} server is installed and running"
if apt-cache show "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
  $STD apt install -y "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" "postgresql-contrib-${PG_VERSION}"
else
  echo "postgresql-${PG_VERSION} package not available in apt. This installer requires PostgreSQL ${PG_VERSION}. Aborting."
  exit 1
fi

$STD systemctl enable --now postgresql || true
if ! systemctl is-active --quiet postgresql; then
  echo "Failed to start postgresql service. Aborting."
  exit 1
fi
msg_ok "PostgreSQL ${PG_VERSION} installed and running"

# 强制使用与 Zabbix 7.4 推荐兼容的 PHP 扩展（这里使用 php8.4-pgsql）
# 按您的要求：不做模糊回退逻辑——如果 php8.4-pgsql 不存在则退出
msg_info "Ensuring PHP package php8.4-pgsql is available (required for Zabbix 7.4 frontend)"
PHP_PGSQL_PKG="php8.4-pgsql"
if ! apt-cache show "$PHP_PGSQL_PKG" >/dev/null 2>&1; then
  echo "Package $PHP_PGSQL_PKG not found in apt. This installer requires php8.4-pgsql for Zabbix 7.4 on Debian13. Aborting."
  exit 1
fi

# 安装 Zabbix server、frontend、PHP-Postgres integration（php8.4-pgsql）、apache conf、sql-scripts
msg_info "Installing Zabbix server, frontend and php8.4-pgsql"
$STD apt install -y zabbix-server-pgsql zabbix-frontend-php "$PHP_PGSQL_PKG" zabbix-apache-conf zabbix-sql-scripts
msg_ok "Installed Zabbix ${ZABBIX_VER} and php integration (${PHP_PGSQL_PKG})"

# Agent 选择逻辑与原脚本一致
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

# 数据库名/用户名/密码逻辑与原脚本保持完全一致（不变）
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

# 导入 schema 并写入 zabbix_server.conf（与原脚本一致）
zcat /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz | sudo -u $DB_USER psql $DB_NAME &>/dev/null
sed -i "s/^DBName=.*/DBName=$DB_NAME/" /etc/zabbix/zabbix_server.conf
sed -i "s/^DBUser=.*/DBUser=$DB_USER/" /etc/zabbix/zabbix_server.conf
sed -i "s/^# DBPassword=.*/DBPassword=$DB_PASS/" /etc/zabbix/zabbix_server.conf
msg_ok "Set up PostgreSQL"

# fping 配置与原脚本一致
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

# 启动服务（与原脚本一致）
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
rm -f "$DEB_FILE"
$STD apt -y autoremove
$STD apt -y autoclean
$STD apt -y clean
msg_ok "Cleaned"
