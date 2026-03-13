#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — Jenkins 远程调用的部署脚本（服务器端执行）
#  用法：bash deploy.sh <制品路径>
#  此脚本由 Jenkinsfile 自动调用，也可手动执行
# =============================================================================

set -euo pipefail

APP_DIR="/opt/showcomefu"
SITE_DIR="/var/www/showcomefu"
BACKUP_DIR="/opt/showcomefu-backups"
DATE=$(date +%Y%m%d_%H%M%S)
ARCHIVE="${1:-}"

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo "用法: bash deploy.sh <制品.tar.gz>"
  exit 1
fi

echo "══ ShowCome 部署开始 ══ $(date)"

# 1. 备份
echo "── 备份当前版本 ──"
mkdir -p "$BACKUP_DIR"
if [[ -d "$APP_DIR" && -f "$APP_DIR/server.js" ]]; then
  tar -czf "$BACKUP_DIR/backup-$DATE.tar.gz" \
    -C "$APP_DIR" --exclude='node_modules' --exclude='.env' --exclude='installed.lock' . 2>/dev/null || true
  ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm
  echo "  ✓ 备份: backup-$DATE.tar.gz"
fi

# 2. 解压
echo "── 部署新版本 ──"
mkdir -p "$APP_DIR"
cd "$APP_DIR"
tar -xzf "$ARCHIVE" --overwrite
rm -f "$ARCHIVE"
echo "  ✓ 解压完成"

# 3. 安装依赖
echo "── 安装依赖 ──"
npm ci --omit=dev --silent 2>/dev/null || npm install --omit=dev --silent
echo "  ✓ 依赖安装完成"

# 4. 迁移
echo "── 数据库迁移 ──"
if [[ -f "$APP_DIR/installed.lock" && -f "$APP_DIR/.env" ]]; then
  node migrate.js && echo "  ✓ 迁移完成" || echo "  ⚠ 迁移跳过"
else
  echo "  ⏭ 系统未初始化，跳过迁移"
fi

# 5. 静态文件
echo "── 静态文件 ──"
mkdir -p "$SITE_DIR"
cp -f "$APP_DIR/index.html"  "$SITE_DIR/"
cp -f "$APP_DIR/admin.html"  "$SITE_DIR/"
cp -f "$APP_DIR/setup.html"  "$SITE_DIR/"
chown -R nginx:nginx "$SITE_DIR" 2>/dev/null || true
echo "  ✓ 静态文件已更新"

# 6. 重启服务
echo "── 重启服务 ──"
if command -v pm2 &>/dev/null; then
  pm2 describe showcomefu-api &>/dev/null && \
    pm2 reload showcomefu-api --update-env || \
    pm2 start "$APP_DIR/server.js" --name "showcomefu-api" --time
  pm2 save
  echo "  ✓ API 服务已重启"
fi

nginx -t 2>/dev/null && systemctl reload nginx && echo "  ✓ Nginx 已重载"

echo ""
echo "══ 部署完成 ══ $(date)"
