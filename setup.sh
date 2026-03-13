#!/usr/bin/env bash
# =============================================================================
#  兽可梦 ShowCome — 全自动生产部署脚本
#  适用：Ubuntu 22.04 LTS / Debian 12
#  用法：sudo bash setup.sh [选项]
#  选项：
#    --domain    域名，如 showcomefu.com（必填）
#    --email     SSL 证书邮箱（必填）
#    --admin-pw  Nginx Basic Auth 密码（默认随机生成）
#    --db-pw     MySQL 应用用户密码（默认随机生成）
#    --jwt-sec   JWT 密钥（默认随机生成）
#    --with-api  同时部署 Node.js API 层（默认：仅静态模式）
#    --skip-ssl  跳过 SSL 申请（纯 IP 访问或手动申请）
#    --help      显示此帮助
#
#  示例：
#    sudo bash setup.sh --domain showcomefu.com --email me@mail.com
#    sudo bash setup.sh --domain showcomefu.com --email me@mail.com --with-api
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── 颜色 ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[✓]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}── $* ──────────────────────────────────────────${RESET}"; }
info() { echo -e "${BLUE}[i]${RESET} $*"; }

# ─── 权限检查 ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "请以 root 身份运行：sudo bash setup.sh ..."
[[ "$(uname -s)" != "Linux" ]] && err "此脚本仅支持 Linux"

# ─── 参数解析 ────────────────────────────────────────────────────────────────
DOMAIN=""
EMAIL=""
ADMIN_PW=""
DB_PW=""
JWT_SEC=""
WITH_API=false
SKIP_SSL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain)   DOMAIN="$2"; shift 2 ;;
    --email)    EMAIL="$2"; shift 2 ;;
    --admin-pw) ADMIN_PW="$2"; shift 2 ;;
    --db-pw)    DB_PW="$2"; shift 2 ;;
    --jwt-sec)  JWT_SEC="$2"; shift 2 ;;
    --with-api) WITH_API=true; shift ;;
    --skip-ssl) SKIP_SSL=true; shift ;;
    --help)
      sed -n '3,20p' "$0" | sed 's/^#  //'
      exit 0 ;;
    *) err "未知参数: $1 (--help 查看用法)" ;;
  esac
done

[[ -z "$DOMAIN" ]] && err "请指定域名：--domain showcomefu.com"
[[ -z "$EMAIL" && "$SKIP_SSL" == "false" ]] && err "请指定邮箱：--email me@example.com"

# 生成随机密码/密钥
gen_pass() { tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c "$1"; }
[[ -z "$ADMIN_PW" ]] && ADMIN_PW="$(gen_pass 20)"
[[ -z "$DB_PW" ]]    && DB_PW="$(gen_pass 24)"
[[ -z "$JWT_SEC" ]]  && JWT_SEC="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)"

# ─── 变量 ────────────────────────────────────────────────────────────────────
SITE_DIR="/var/www/showcomefu"
NGINX_CONF="/etc/nginx/sites-available/showcomefu"
API_DIR="/opt/showcomefu-api"
BACKUP_SCRIPT="/usr/local/bin/backup-showcomefu.sh"
LOG_FILE="/var/log/showcomefu-setup.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 带时间戳写日志
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== 部署开始: $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"

# ─── 欢迎横幅 ────────────────────────────────────────────────────────────────
echo -e "
${CYAN}${BOLD}
  ╔═══════════════════════════════════════════╗
  ║   兽可梦 ShowCome  生产部署脚本 v1.0.0   ║
  ╚═══════════════════════════════════════════╝
${RESET}
  域名：${BOLD}$DOMAIN${RESET}
  模式：$([ "$WITH_API" = true ] && echo "${BOLD}静态 + Node.js API + MySQL${RESET}" || echo "${BOLD}纯静态（localStorage）${RESET}")
  SSL ：$([ "$SKIP_SSL" = true ] && echo "跳过" || echo "$EMAIL")
"

confirm() {
  read -rp "$(echo -e "${YELLOW}继续？[y/N]${RESET} ")" ans
  [[ "$ans" =~ ^[Yy]$ ]] || { warn "已取消"; exit 0; }
}
confirm

# ─── 0. 检测系统 ─────────────────────────────────────────────────────────────
step "0. 系统检测"
OS=$(. /etc/os-release && echo "$ID $VERSION_ID")
info "系统：$OS"
info "内核：$(uname -r)"
info "内存：$(free -h | awk '/Mem/{print $2}')"
info "磁盘：$(df -h / | awk 'NR==2{print $4}') 可用"

# Ubuntu/Debian only
[[ "$OS" =~ ubuntu|debian ]] || err "仅支持 Ubuntu / Debian，当前：$OS"

# ─── 1. 系统更新 ─────────────────────────────────────────────────────────────
step "1. 系统更新"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git unzip vim nano htop net-tools \
  ca-certificates gnupg lsb-release \
  logrotate cron ufw fail2ban

log "系统软件包已更新"

# ─── 2. 配置防火墙 ───────────────────────────────────────────────────────────
step "2. 配置防火墙"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose
log "防火墙已配置（仅开放 22/80/443）"

# ─── 3. 配置 fail2ban ────────────────────────────────────────────────────────
step "3. 配置 fail2ban（防暴力破解）"
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/showcomefu_error.log
maxretry = 3
bantime  = 24h

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/showcomefu_error.log
maxretry = 10
EOF
systemctl enable fail2ban --quiet
systemctl restart fail2ban
log "fail2ban 已配置"

# ─── 4. 安装 Nginx ───────────────────────────────────────────────────────────
step "4. 安装 & 配置 Nginx"
apt-get install -y -qq nginx apache2-utils
systemctl enable nginx --quiet

# 删除默认配置
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

# 写入 Nginx 配置
cat > "$NGINX_CONF" << NGINX_EOF
# /etc/nginx/sites-available/showcomefu
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 域名: $DOMAIN

limit_req_zone \$binary_remote_addr zone=general:10m rate=20r/s;
limit_req_zone \$binary_remote_addr zone=admin:10m   rate=5r/s;
limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

# HTTP → 临时可访问，certbot 验证后自动改为强制跳转 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    root $SITE_DIR;
    index index.html;
    charset utf-8;

    access_log /var/log/nginx/showcomefu_access.log;
    error_log  /var/log/nginx/showcomefu_error.log warn;

    # 安全响应头
    add_header X-Frame-Options          "SAMEORIGIN" always;
    add_header X-Content-Type-Options   "nosniff" always;
    add_header X-XSS-Protection         "1; mode=block" always;
    add_header Referrer-Policy          "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy       "geolocation=(), microphone=(), camera=()" always;

    # 连接数限制
    limit_conn conn_limit 20;

    # ── 前台 ──
    location / {
        limit_req zone=general burst=30 nodelay;
        try_files \$uri \$uri/ /index.html;
    }

    # ── 静态资源缓存 ──
    location ~* \.(js|css|png|jpg|jpeg|gif|webp|svg|ico|woff|woff2|ttf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # ── 后台管理（Nginx Basic Auth 第一层保护）──
    location ^~ /admin {
        auth_basic           "ShowCome Admin Area";
        auth_basic_user_file /etc/nginx/.htpasswd;
        limit_req            zone=admin burst=10 nodelay;
        try_files            \$uri \$uri/ /admin.html;
    }

    # ── API 反向代理（仅 with-api 模式启用）──
$([ "$WITH_API" = true ] && cat << 'APIBLOCK'
    location /api/ {
        proxy_pass         http://127.0.0.1:3000/api/;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 30s;
        proxy_connect_timeout 10s;

        # 限流
        limit_req zone=admin burst=20 nodelay;
    }
APIBLOCK
|| echo "    # location /api/ { ... }  # 启用 --with-api 后解开注释")

    # ── 禁止访问隐藏文件和敏感路径 ──
    location ~ /\. { deny all; return 404; }
    location ~ \.(env|sh|sql|log|bak|git)$ { deny all; return 404; }

    # ── 健康检查 ──
    location /health {
        access_log off;
        return 200 '{"status":"ok","domain":"$DOMAIN"}';
        add_header Content-Type application/json;
    }
}
NGINX_EOF

# 创建站点目录
mkdir -p "$SITE_DIR"
chown -R www-data:www-data "$SITE_DIR"
chmod -R 755 "$SITE_DIR"

# 启用站点
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/showcomefu

# 设置 Basic Auth
echo "$ADMIN_PW" | htpasswd -c -i /etc/nginx/.htpasswd admin
chmod 640 /etc/nginx/.htpasswd
chown root:www-data /etc/nginx/.htpasswd

# 测试配置
nginx -t
systemctl reload nginx
log "Nginx 已安装配置（含 Basic Auth）"

# ─── 5. 部署站点文件 ─────────────────────────────────────────────────────────
step "5. 部署站点文件"
# 尝试从脚本同级目录复制 HTML 文件
FILES_FOUND=false

for htmlfile in index.html admin.html; do
  if [[ -f "$SCRIPT_DIR/../$htmlfile" ]]; then
    cp "$SCRIPT_DIR/../$htmlfile" "$SITE_DIR/$htmlfile"
    chown www-data:www-data "$SITE_DIR/$htmlfile"
    chmod 644 "$SITE_DIR/$htmlfile"
    log "已部署：$htmlfile"
    FILES_FOUND=true
  elif [[ -f "$SCRIPT_DIR/$htmlfile" ]]; then
    cp "$SCRIPT_DIR/$htmlfile" "$SITE_DIR/$htmlfile"
    chown www-data:www-data "$SITE_DIR/$htmlfile"
    chmod 644 "$SITE_DIR/$htmlfile"
    log "已部署：$htmlfile"
    FILES_FOUND=true
  fi
done

if [[ "$FILES_FOUND" = false ]]; then
  warn "未找到 index.html / admin.html，需手动上传到 $SITE_DIR"
  warn "命令示例："
  warn "  scp index.html admin.html $(id -un)@$(hostname -I | awk '{print $1}'):$SITE_DIR/"
fi

# ─── 6. SSL 证书 ─────────────────────────────────────────────────────────────
if [[ "$SKIP_SSL" = false ]]; then
  step "6. 申请 Let's Encrypt SSL 证书"
  apt-get install -y -qq certbot python3-certbot-nginx

  # 等待 DNS 生效
  info "正在检查 DNS 解析..."
  RESOLVED_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -1)
  SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  if [[ "$RESOLVED_IP" != "$SERVER_IP" ]]; then
    warn "DNS 解析结果 ($RESOLVED_IP) 与服务器 IP ($SERVER_IP) 不匹配"
    warn "请确认域名 $DOMAIN 已解析到本服务器，然后手动执行："
    warn "  sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN --email $EMAIL --agree-tos --non-interactive"
  else
    log "DNS 解析正常，IP：$RESOLVED_IP"
    certbot --nginx \
      -d "$DOMAIN" -d "www.$DOMAIN" \
      --email "$EMAIL" \
      --agree-tos \
      --non-interactive \
      --redirect \
      && log "SSL 证书申请成功" \
      || warn "SSL 申请失败，请手动执行上方命令"
  fi

  # 验证自动续期
  systemctl list-timers | grep -q certbot && log "certbot 自动续期定时任务已就位" || warn "请检查 certbot.timer"
else
  info "跳过 SSL（--skip-ssl 模式）"
fi

# ─── 7. 安装 Node.js + MySQL（仅 --with-api）────────────────────────────────
if [[ "$WITH_API" = true ]]; then

  step "7a. 安装 Node.js 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
  log "Node.js: $(node -v)  npm: $(npm -v)"

  step "7b. 安装 MySQL 8"
  apt-get install -y -qq mysql-server
  systemctl enable mysql --quiet
  systemctl start mysql

  # 创建数据库和用户（root 无密码初始状态）
  mysql -u root << SQL
CREATE DATABASE IF NOT EXISTS showcomefu
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'showcome'@'localhost' IDENTIFIED BY '$DB_PW';
GRANT ALL PRIVILEGES ON showcomefu.* TO 'showcome'@'localhost';
FLUSH PRIVILEGES;
SQL
  log "MySQL 数据库和用户已创建"

  step "7c. 初始化数据库表"
  if [[ -f "$SCRIPT_DIR/schema.sql" ]]; then
    mysql -u showcome -p"$DB_PW" showcomefu < "$SCRIPT_DIR/schema.sql"
    log "数据库表已初始化（schema.sql）"
  else
    warn "未找到 schema.sql，请手动执行：mysql -u showcome -p'$DB_PW' showcomefu < deploy/schema.sql"
  fi

  step "7d. 部署 Node.js API"
  mkdir -p "$API_DIR"
  cd "$API_DIR"

  # 生成 package.json
  cat > package.json << 'PKGJSON'
{
  "name": "showcomefu-api",
  "version": "1.0.0",
  "description": "ShowCome CMS API Layer",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "nodemon server.js"
  },
  "engines": { "node": ">=20" }
}
PKGJSON

  npm install --silent \
    express \
    mysql2 \
    bcryptjs \
    jsonwebtoken \
    cors \
    helmet \
    express-rate-limit \
    dotenv \
    multer \
    nodemailer \
    express-validator

  # 生成 .env
  cat > .env << ENVEOF
PORT=3000
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=showcomefu
DB_USER=showcome
DB_PASS=$DB_PW
JWT_SECRET=$JWT_SEC
JWT_EXPIRES=12h
FRONTEND_URL=https://$DOMAIN
NODE_ENV=production
ENVEOF
  chmod 600 .env
  log "Node.js 依赖已安装，.env 已生成"

  # 复制 server.js（如果在 deploy/ 目录中）
  if [[ -f "$SCRIPT_DIR/server.js" ]]; then
    cp "$SCRIPT_DIR/server.js" "$API_DIR/server.js"
    log "API server.js 已复制"
  else
    warn "server.js 不存在于 $SCRIPT_DIR，请手动放置"
  fi

  # 安装 PM2 并启动
  npm install -g pm2 --silent
  pm2 start server.js --name "showcomefu-api" --time || true
  pm2 startup systemd -u root --hp /root | tail -1 | bash || true
  pm2 save
  log "PM2 服务已启动"

fi

# ─── 8. 日志轮转 ─────────────────────────────────────────────────────────────
step "8. 配置日志轮转"
cat > /etc/logrotate.d/showcomefu << 'EOF'
/var/log/nginx/showcomefu_*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        nginx -s reopen 2>/dev/null || true
    endscript
}
EOF
log "日志轮转已配置（保留 30 天）"

# ─── 9. 自动备份脚本 ─────────────────────────────────────────────────────────
step "9. 配置自动备份"
cat > "$BACKUP_SCRIPT" << BACKUPEOF
#!/bin/bash
# ShowCome 每日备份脚本
BACKUP_DIR="/home/\$(logname 2>/dev/null || echo deploy)/backups"
DATE=\$(date +%Y%m%d_%H%M%S)

mkdir -p "\$BACKUP_DIR"

# 备份站点文件
tar -czf "\$BACKUP_DIR/site_\$DATE.tar.gz" -C "$SITE_DIR" . 2>/dev/null

# 备份 MySQL（仅 API 模式）
$([ "$WITH_API" = true ] && echo "mysqldump -u showcome -p'$DB_PW' showcomefu 2>/dev/null | gzip > \"\$BACKUP_DIR/db_\$DATE.sql.gz\"" || echo "# MySQL 备份（仅 API 模式）")

# 保留最近 30 个备份
ls -t "\$BACKUP_DIR"/site_*.tar.gz 2>/dev/null | tail -n +31 | xargs -r rm
$([ "$WITH_API" = true ] && echo "ls -t \"\$BACKUP_DIR\"/db_*.sql.gz 2>/dev/null | tail -n +31 | xargs -r rm" || true)

echo "[\$DATE] 备份完成"
BACKUPEOF
chmod +x "$BACKUP_SCRIPT"

# 添加定时任务（每天凌晨 3 点）
(crontab -l 2>/dev/null | grep -v backup-showcomefu; echo "0 3 * * * $BACKUP_SCRIPT >> /var/log/showcomefu-backup.log 2>&1") | crontab -
log "备份脚本已配置（每天 03:00）"

# ─── 10. 系统优化 ────────────────────────────────────────────────────────────
step "10. 系统参数优化"
cat >> /etc/sysctl.conf << 'EOF'
# ShowCome 网络优化
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.core.netdev_max_backlog = 5000
EOF
sysctl -p --quiet
log "内核网络参数已优化"

# ─── 11. 最终验证 ────────────────────────────────────────────────────────────
step "11. 最终验证"

check() {
  local name=$1 cmd=$2
  if eval "$cmd" &>/dev/null; then
    log "$name ✓"
  else
    warn "$name ✗（请手动检查）"
  fi
}

check "Nginx 运行中"          "systemctl is-active nginx"
check "Nginx 配置语法"        "nginx -t"
check "防火墙已启用"          "ufw status | grep -q 'Status: active'"
check "fail2ban 运行中"       "systemctl is-active fail2ban"
check "Basic Auth 文件存在"   "test -f /etc/nginx/.htpasswd"
check "站点目录存在"          "test -d $SITE_DIR"

if [[ "$WITH_API" = true ]]; then
  check "MySQL 运行中"        "systemctl is-active mysql"
  check "PM2 API 进程"        "pm2 list | grep -q 'showcomefu-api'"
  check "API 健康检查"        "curl -s http://127.0.0.1:3000/api/health | grep -q ok"
fi

if [[ "$SKIP_SSL" = false ]]; then
  check "SSL 证书存在"        "test -d /etc/letsencrypt/live/$DOMAIN"
fi

# ─── 输出部署摘要 ────────────────────────────────────────────────────────────
SUMMARY_FILE="/root/showcomefu-deploy-info.txt"
cat > "$SUMMARY_FILE" << SUMMARY
=================================================================
  兽可梦 ShowCome 部署摘要 — $(date '+%Y-%m-%d %H:%M:%S')
=================================================================

🌐 前台地址    https://$DOMAIN
🔧 后台地址    https://$DOMAIN/admin
⚡ API 地址    $([ "$WITH_API" = true ] && echo "https://$DOMAIN/api/" || echo "未启用（localStorage 模式）")

🔑 Nginx Basic Auth
   用户名：admin
   密  码：$ADMIN_PW

🔐 CMS 后台登录（页面内）
   用户名：admin
   密  码：showcome2024
   ⚠️  请登录后台 → 管理员账号 → 立即修改密码！

$([ "$WITH_API" = true ] && echo "🗄️  MySQL
   数据库：showcomefu
   用户名：showcome
   密  码：$DB_PW

🔑 JWT 密钥（妥善保管）
   $JWT_SEC
" || echo "")

📁 重要路径
   站点目录：$SITE_DIR
   Nginx 配置：$NGINX_CONF
   Basic Auth：/etc/nginx/.htpasswd
   备份目录：~/backups/
   部署日志：$LOG_FILE

📋 常用运维命令
   sudo nginx -t && sudo systemctl reload nginx  # 重载 Nginx
   sudo certbot renew --dry-run                  # 测试 SSL 续期
   $BACKUP_SCRIPT                                 # 手动备份
   sudo fail2ban-client status nginx-http-auth   # 查看封禁列表

=================================================================
SUMMARY

chmod 600 "$SUMMARY_FILE"

echo ""
echo -e "${GREEN}${BOLD}=================================================================${RESET}"
echo -e "${GREEN}${BOLD}  🎉 部署完成！${RESET}"
echo -e "${GREEN}${BOLD}=================================================================${RESET}"
cat "$SUMMARY_FILE"
echo ""
echo -e "${YELLOW}${BOLD}⚠️  重要：${RESET}"
echo -e "  1. 以上凭证已保存至 ${BOLD}$SUMMARY_FILE${RESET}（仅 root 可读）"
echo -e "  2. 请立即登录后台修改默认密码"
echo -e "  3. 建议定期执行：${BOLD}sudo apt update && sudo apt upgrade -y${RESET}"
echo ""
