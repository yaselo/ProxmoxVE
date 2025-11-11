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

# 保持原脚本行为：使用 PG_VERSION helper（默认 17）
PG_VERSION="17" setup_postgresql

# 固定为 Zabbix 7.4，目标 Debian 13 仓库
ZABBIX_VER="7.4"
DEBIAN_TARGET="debian13"

msg_info "Installing Zabbix ${ZABBIX_VER}"
cd /tmp

# 优先用固定命名的 7.4 deb 包，找不到时回退到 latest+debian13
DEB_FILE="/tmp/zabbix-release_${ZABBIX_VER}-1+${DEBIAN_TARGET}_all.deb"
ZABBIX_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VER}/release/debian/pool/main/z/zabbix-release/$(basename "$DEB_FILE")"

if ! curl -fsSL "$ZABBIX_URL" -o "$DEB_FILE"; then
  FALLBACK_DEB="/tmp/zabbix-release_latest+${DEBIAN_TARGET}_all.deb"
  if curl -fsSL "$(curl -fsSL https://repo.zabbix.com/zabbix/ |
    grep -oP '(?<=href=\" )[0-9]+\.[0-9]+(?=/\")' 2>/dev/null || true)" >/dev/null 2>&1; then
    # 正常情况上面的命令可能不会返回；直接尝试官方 latest 包
    curl -fsSL "https://repo.zabbix.com/zabbix/${ZABBIX_VER}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+${DEBIAN_TARGET}_all.deb" -o "$FALLBACK_DEB" >/dev/null 2>&1 || true
  fi
  if [ -f "$FALLBACK_DEB" ]; then
    DEB_FILE="$FALLBACK_DEB"
  else
    # 最后尝试从 repo.zabbix.com 自动解析最新小版本并下载 latest 包
    LATEST_VER=$(curl -fsSL https://repo.zabbix.com/zabbix/ | grep -oP '(?<=href=")[0-9]+\.[0-9]+(?=/")' | sort -V | tail -n1)
    if [ -n "$LATEST_VER" ]; then
      curl -fsSL "https://repo.zabbix.com/zabbix/${LATEST_VER}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest+${DEBIAN_TARGET}_all.deb" -o "$FALLBACK_DEB" || true
    fi
    if [ -f "$FALLBACK_DEB" ]; then
      DEB_FILE="$FALLBACK_DEB"
    else
      echo "Failed to download Zabbix release package for version ${ZABBIX_VER} and fallback. Aborting."
      exit 1
    fi
  fi
fi

$STD dpkg -i "$DEB_FILE"
$STD apt update

# 明确安装数据库服务：优先安装 postgresql-17（与原脚本 PG_VERSION 一致），若不可用回退 meta-package
msg_info "Ensuring PostgreSQL ${PG_VERSION} is installed"
if apt-cache show "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
  $STD apt install -y "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" "postgresql-contrib-${PG_VERSION}"
else
  $STD apt install -y postgresql postgresql-client postgresql-contrib
fi

# 启用并启动 PostgreSQL 服务，保证后续 psql 命令可用
$STD systemctl enable --now postgresql || true
if ! systemctl is-active --quiet postgresql; then
  echo "Warning: postgresql service is not active; attempting to start"
  $STD systemctl start postgresql || {
    echo "Failed to start postgresql. Aborting."
    exit 1
  }
fi
msg_ok "PostgreSQL installed and running"

# 选择与 Zabbix 7.4 兼容的 PHP/pgsql 包（原脚本使用 php8.4-pgsql，优先保留）
msg_info "Installing Zabbix server, frontend and compatible PHP/Postgres integration package"

# 优先尝试 php8.4-pgsql（与原脚本一致），若不可用则选择可用的最高版本 phpX.Y-pgsql，最后回退到 php-pgsql
PREFERRED_PHP_PGSQL="php8.4-pgsql"
if apt-cache show "$PREFERRED_PHP_PGSQL" >/dev/null 2>&1; then
  PHP_PGSQL_PKG="$PREFERRED_PHP_PGSQL"
else
  # 查找 apt 中可用的 php*-pgsql，选择最高版本（按字符串排序近似）
  PHP_CANDIDATES=$(apt-cache search '^php[0-9]+\.[0-9]+-pgsql' 2>/dev/null | awk '{print $1}' || true)
  if [ -n "$PHP_CANDIDATES" ]; then
    PHP_PGSQL_PKG=$(echo "$PHP_CANDIDATES" | sort -rV | head -n1)
  else
    if apt-cache show php-pgsql >/dev/null 2>&1; then
      PHP_PGSQL_PKG="php-pgsql"
    else
      PHP_PGSQL_PKG=""
      echo "Warning: no php-*-pgsql package found in apt. You may need to install PHP manually for the frontend."
    fi
  fi
fi

# 安装 Zabbix server/frontend/所需 PHP pgsql 集成包
INSTALL_PKGS=(zabbix-server-pgsql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts)
[ -n "$PHP_PGSQL_PKG" ] && INSTALL_PKGS+=("$PHP_PGSQL_PKG")

$STD apt install -y "${INSTALL_PKGS[@]}"
msg_ok "Installed Zabbix and PHP/Postgres integration (${PHP_PGSQL_PKG:-none})"

# Agent 选择逻辑保持与原脚本一致
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

# 数据库名/用户名/密码逻辑与原脚本保持完全一致
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

# 导入 schema（与原脚本一致）
zcat /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz | sudo -u $DB_USER psql $DB_NAME &>/dev/null
sed -i "s/^DBName=.*/DBName=$DB_NAME/" /etc/zabbix/zabbix_server.conf
sed -i "s/^DBUser=.*/DBUser=$DB_USER/" /etc/zabbix/zabbix_server.conf
sed -i "s/^# DBPassword=.*/DBPassword=$DB_PASS/" /etc/zabbix/zabbix_server.conf
msg_ok "Set up PostgreSQL"

# fping 配置保持不变
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

# 启动/启用服务（与原脚本一致）
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
rm -rf /tmp/zabbix-release_*+${DEBIAN_TARGET}_all.deb
$STD apt -y autoremove
$STD apt -y autoclean
$STD apt -y clean
msg_ok "Cleaned"
