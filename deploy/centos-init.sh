#!/usr/bin/env bash
# =============================================================================
#  兽可梦 ShowCome — CentOS 服务器首次环境初始化脚本
#  适用：CentOS 7/8/9 / RHEL / Rocky Linux / AlmaLinux
#  用法：sudo bash centos-init.sh [选项]
#  选项：
#    --domain     域名（如 showcomefu.com）
#    --with-mysql 安装并配置 MySQL 8
#    --skip-ssl   跳过 SSL 申请
#    --email      SSL 证书邮箱
#    --help       显示帮助
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[✓]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}── $* ──${RESET}"; }

[[ $EUID -ne 0 ]] && err "请以 root 身份运行：sudo bash centos-init.sh"

# ─── 参数 ──
DOMAIN=""
EMAIL=""
WITH_MYSQL=false
SKIP_SSL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain)     DOMAIN="$2"; shift 2 ;;
    --email)      EMAIL="$2"; shift 2 ;;
    --with-mysql) WITH_MYSQL=true; shift ;;
    --skip-ssl)   SKIP_SSL=true; shift ;;
    --help)       sed -n '3,14p' "$0" | sed 's/^#  //'; exit 0 ;;
    *) err "未知参数: $1" ;;
  esac
done

APP_DIR="/opt/showcomefu"
SITE_DIR="/var/www/showcomefu"

echo -e "\n${CYAN}${BOLD}  ╔═══════════════════════════════════════════╗"
echo "  ║  ShowCome CentOS 环境初始化 v1.1.0       ║"
echo -e "  ╚═══════════════════════════════════════════╝${RESET}\n"

# ─── 1. 系统更新 ──
step "1. 系统更新 & 基础工具"
yum update -y -q
yum install -y -q \
  curl wget git unzip vim net-tools \
  epel-release yum-utils

log "系统更新完成"

# ─── 2. 防火墙 ──
step "2. 配置防火墙"
if systemctl is-active firewalld &>/dev/null; then
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --reload
  log "firewalld 已配置"
else
  warn "firewalld 未运行，请手动配置防火墙"
fi

# ─── 3. 安装 Node.js 20 ──
step "3. 安装 Node.js 20"
if ! command -v node &>/dev/null || [[ "$(node -v)" < "v18" ]]; then
  curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
  yum install -y -q nodejs
fi
log "Node.js $(node -v) / npm $(npm -v)"

# 安装 PM2
if ! command -v pm2 &>/dev/null; then
  npm install -g pm2 --silent
  log "PM2 已安装"
fi

# ─── 4. 安装 Nginx ──
step "4. 安装 Nginx"
if ! command -v nginx &>/dev/null; then
  yum install -y -q nginx
fi
systemctl enable nginx --quiet
systemctl start nginx

# 配置站点
mkdir -p "$SITE_DIR"

if [[ -n "$DOMAIN" ]]; then
  cat > /etc/nginx/conf.d/showcomefu.conf << NGINX_EOF
# ShowCome Nginx 配置 — $(date '+%Y-%m-%d')

limit_req_zone \$binary_remote_addr zone=general:10m rate=20r/s;
limit_req_zone \$binary_remote_addr zone=admin_zone:10m rate=5r/s;

upstream showcomefu_api {
    server 127.0.0.1:3000;
    keepalive 16;
}

server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    root $SITE_DIR;
    index index.html;
    charset utf-8;

    access_log /var/log/nginx/showcomefu_access.log;
    error_log  /var/log/nginx/showcomefu_error.log warn;

    add_header X-Frame-Options          "SAMEORIGIN" always;
    add_header X-Content-Type-Options   "nosniff" always;
    add_header X-XSS-Protection         "1; mode=block" always;
    add_header Referrer-Policy          "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_types text/html text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1000;

    # 前台
    location / {
        limit_req zone=general burst=30 nodelay;
        try_files \$uri \$uri/ /index.html;
    }

    # 静态资源缓存
    location ~* \.(js|css|png|jpg|jpeg|gif|webp|svg|ico|woff|woff2|ttf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # 初始化向导
    location = /setup {
        try_files /setup.html =404;
    }

    # 后台管理
    location ^~ /admin {
        limit_req zone=admin_zone burst=10 nodelay;
        try_files \$uri \$uri/ /admin.html;
    }

    # API 反向代理
    location /api/ {
        proxy_pass         http://showcomefu_api/api/;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
        proxy_connect_timeout 10s;
    }

    # 禁止访问敏感文件
    location ~ /\. { deny all; return 404; }
    location ~ \.(env|sh|sql|log|lock|git)$ { deny all; return 404; }

    # 健康检查
    location = /health {
        access_log off;
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }
}
NGINX_EOF

  nginx -t && systemctl reload nginx
  log "Nginx 站点配置完成：$DOMAIN"
else
  warn "未指定域名，跳过 Nginx 站点配置"
fi

# ─── 5. MySQL（可选） ──
if [[ "$WITH_MYSQL" = true ]]; then
  step "5. 安装 MySQL 8"
  if ! command -v mysql &>/dev/null; then
    yum install -y -q mysql-server || {
      rpm -Uvh https://dev.mysql.com/get/mysql80-community-release-el$(rpm -E %{rhel})-1.noarch.rpm 2>/dev/null
      yum install -y -q mysql-community-server
    }
  fi
  systemctl enable mysqld --quiet
  systemctl start mysqld
  log "MySQL 已安装并启动"
  warn "请运行 mysql_secure_installation 完成安全初始化"
  warn "然后通过 /setup 页面配置数据库连接"
fi

# ─── 6. SSL 证书 ──
if [[ "$SKIP_SSL" = false && -n "$DOMAIN" && -n "$EMAIL" ]]; then
  step "6. 申请 SSL 证书"
  if ! command -v certbot &>/dev/null; then
    yum install -y -q certbot python3-certbot-nginx
  fi
  certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" \
    --email "$EMAIL" --agree-tos --non-interactive --redirect \
    && log "SSL 证书申请成功" \
    || warn "SSL 申请失败，请手动执行: certbot --nginx -d $DOMAIN"
fi

# ─── 7. 创建应用目录 ──
step "7. 初始化应用目录"
mkdir -p "$APP_DIR"
mkdir -p /opt/showcomefu-backups

# ─── 8. 配置 PM2 开机自启 ──
step "8. 配置 PM2 自启"
pm2 startup systemd -u root --hp /root 2>/dev/null | tail -1 | bash 2>/dev/null || true
log "PM2 自启配置完成"

# ─── 9. 日志轮转 ──
step "9. 配置日志轮转"
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
log "日志轮转已配置"

# ─── 完成 ──
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✅ 环境初始化完成！${RESET}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${RESET}"
echo ""
echo "  下一步："
echo "  1. 将代码部署到 $APP_DIR（通过 Jenkins 自动或手动 git clone）"
echo "  2. cd $APP_DIR && npm install --omit=dev"
echo "  3. pm2 start server.js --name showcomefu-api"
echo "  4. 访问 http://${DOMAIN:-你的IP}/setup 完成系统初始化"
echo ""
