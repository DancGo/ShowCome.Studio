#!/usr/bin/env bash
# =============================================================================
#  rollback.sh — 回滚到上一个备份版本
#  用法：sudo bash rollback.sh [指定备份文件名]
# =============================================================================

set -euo pipefail

APP_DIR="/opt/showcomefu"
SITE_DIR="/var/www/showcomefu"
BACKUP_DIR="/opt/showcomefu-backups"

BACKUP_FILE="${1:-}"

if [[ -z "$BACKUP_FILE" ]]; then
  BACKUP_FILE=$(ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1)
  if [[ -z "$BACKUP_FILE" ]]; then
    echo "❌ 未找到可用备份"
    exit 1
  fi
  echo "📦 将回滚到最新备份: $(basename "$BACKUP_FILE")"
else
  BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILE"
  [[ -f "$BACKUP_FILE" ]] || { echo "❌ 备份文件不存在: $BACKUP_FILE"; exit 1; }
fi

read -rp "确认回滚？[y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

echo "── 回滚中 ──"
cd "$APP_DIR"
tar -xzf "$BACKUP_FILE" --overwrite
npm ci --omit=dev --silent 2>/dev/null || npm install --omit=dev --silent

cp -f "$APP_DIR/index.html"  "$SITE_DIR/"
cp -f "$APP_DIR/admin.html"  "$SITE_DIR/"
cp -f "$APP_DIR/setup.html"  "$SITE_DIR/" 2>/dev/null || true

pm2 reload showcomefu-api --update-env 2>/dev/null || true
nginx -t && systemctl reload nginx

echo "✅ 回滚完成: $(basename "$BACKUP_FILE")"
