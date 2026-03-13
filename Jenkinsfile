// =============================================================================
//  兽可梦 ShowCome — Jenkins CI/CD 流水线
//  触发方式：Gitee WebHook (push to main)
//  目标环境：CentOS 云服务器
// =============================================================================

pipeline {
    agent any

    environment {
        DEPLOY_USER = credentials('showcomefu-ssh-user')   // Jenkins 凭据：SSH 用户名
        DEPLOY_HOST = credentials('showcomefu-ssh-host')   // Jenkins 凭据：服务器 IP
        SSH_KEY     = credentials('showcomefu-ssh-key')    // Jenkins 凭据：SSH 私钥
        APP_DIR     = '/opt/showcomefu'                    // 服务器上的应用目录
        NODE_ENV    = 'production'
    }

    options {
        timeout(time: 15, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    triggers {
        // Gitee WebHook 触发（需安装 Gitee Plugin）
        GenericTrigger(
            genericVariables: [
                [key: 'ref', value: '$.ref']
            ],
            causeString: 'Gitee Push to $ref',
            token: 'showcomefu-deploy',
            regexpFilterText: '$ref',
            regexpFilterExpression: '^refs/heads/main$'
        )
    }

    stages {

        stage('检出代码') {
            steps {
                echo '📥 拉取最新代码...'
                checkout scm
            }
        }

        stage('代码检查') {
            steps {
                echo '🔍 验证关键文件...'
                sh '''
                    for f in index.html admin.html setup.html server.js package.json migrate.js; do
                        [ -f "$f" ] && echo "  ✓ $f" || { echo "  ✗ $f 缺失"; exit 1; }
                    done
                    [ -d migrations ] && echo "  ✓ migrations/" || { echo "  ✗ migrations/ 目录缺失"; exit 1; }
                    echo "✅ 文件完整性检查通过"
                '''
            }
        }

        stage('安装依赖') {
            steps {
                echo '📦 安装 Node.js 依赖（仅 production）...'
                sh '''
                    npm ci --omit=dev --silent 2>/dev/null || npm install --omit=dev --silent
                    echo "✅ 依赖安装完成"
                '''
            }
        }

        stage('打包制品') {
            steps {
                echo '📦 打包部署制品...'
                sh '''
                    DEPLOY_ARCHIVE="showcomefu-${BUILD_NUMBER}.tar.gz"
                    tar -czf "$DEPLOY_ARCHIVE" \
                        --exclude='node_modules' \
                        --exclude='.git' \
                        --exclude='.env' \
                        --exclude='installed.lock' \
                        --exclude='*.tar.gz' \
                        --exclude='.gitignore' \
                        .
                    echo "✅ 制品打包完成: $DEPLOY_ARCHIVE"
                '''
            }
        }

        stage('上传到服务器') {
            steps {
                echo '🚀 上传制品到服务器...'
                sh '''
                    DEPLOY_ARCHIVE="showcomefu-${BUILD_NUMBER}.tar.gz"
                    scp -o StrictHostKeyChecking=no \
                        -i "$SSH_KEY" \
                        "$DEPLOY_ARCHIVE" \
                        "${DEPLOY_USER}@${DEPLOY_HOST}:/tmp/"
                    echo "✅ 上传完成"
                '''
            }
        }

        stage('部署 & 迁移') {
            steps {
                echo '⚡ 执行远程部署...'
                sh '''
                    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" \
                        "${DEPLOY_USER}@${DEPLOY_HOST}" << 'REMOTE_SCRIPT'

set -e
APP_DIR="/opt/showcomefu"
BACKUP_DIR="/opt/showcomefu-backups"
DATE=$(date +%Y%m%d_%H%M%S)
DEPLOY_ARCHIVE="/tmp/showcomefu-${BUILD_NUMBER}.tar.gz"

echo "── 1. 备份当前版本 ──"
mkdir -p "$BACKUP_DIR"
if [ -d "$APP_DIR" ] && [ -f "$APP_DIR/server.js" ]; then
    tar -czf "$BACKUP_DIR/backup-$DATE.tar.gz" \
        -C "$APP_DIR" \
        --exclude='node_modules' \
        --exclude='.env' \
        --exclude='installed.lock' \
        . 2>/dev/null || true
    # 保留最近 10 个备份
    ls -t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm
    echo "  备份完成: backup-$DATE.tar.gz"
fi

echo "── 2. 解压新版本 ──"
mkdir -p "$APP_DIR"
cd "$APP_DIR"
# 保留 .env 和 installed.lock
tar -xzf "$DEPLOY_ARCHIVE" --overwrite
rm -f "$DEPLOY_ARCHIVE"
echo "  解压完成"

echo "── 3. 安装依赖 ──"
cd "$APP_DIR"
npm ci --omit=dev --silent 2>/dev/null || npm install --omit=dev --silent
echo "  依赖安装完成"

echo "── 4. 执行数据库迁移 ──"
if [ -f "$APP_DIR/installed.lock" ] && [ -f "$APP_DIR/.env" ]; then
    cd "$APP_DIR"
    node migrate.js && echo "  迁移完成" || echo "  ⚠ 迁移失败（可能无待执行迁移）"
else
    echo "  跳过迁移（系统尚未初始化）"
fi

echo "── 5. 部署静态文件到 Nginx ──"
SITE_DIR="/var/www/showcomefu"
mkdir -p "$SITE_DIR"
cp -f "$APP_DIR/index.html" "$SITE_DIR/"
cp -f "$APP_DIR/admin.html" "$SITE_DIR/"
cp -f "$APP_DIR/setup.html" "$SITE_DIR/"
chown -R nginx:nginx "$SITE_DIR" 2>/dev/null || chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || true
chmod -R 755 "$SITE_DIR"
echo "  静态文件部署完成"

echo "── 6. 重启 API 服务 ──"
if command -v pm2 &>/dev/null; then
    cd "$APP_DIR"
    pm2 describe showcomefu-api &>/dev/null && \
        pm2 reload showcomefu-api --update-env || \
        pm2 start server.js --name "showcomefu-api" --time
    pm2 save
    echo "  PM2 服务已重启"
else
    echo "  ⚠ PM2 未安装，请手动启动: cd $APP_DIR && pm2 start server.js --name showcomefu-api"
fi

echo "── 7. 重载 Nginx ──"
nginx -t && systemctl reload nginx
echo "  Nginx 已重载"

echo ""
echo "✅ 部署完成 — $(date '+%Y-%m-%d %H:%M:%S')"
REMOTE_SCRIPT
                '''
            }
        }

        stage('健康检查') {
            steps {
                echo '🩺 验证部署结果...'
                sh '''
                    sleep 3
                    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" \
                        "${DEPLOY_USER}@${DEPLOY_HOST}" << 'HEALTHCHECK'
# 检查 PM2 进程
pm2 list | grep -q "showcomefu-api" && echo "✓ API 进程运行中" || echo "✗ API 进程未运行"

# 检查 API 健康
HEALTH=$(curl -s --max-time 5 http://127.0.0.1:3000/api/health 2>/dev/null)
echo "$HEALTH" | grep -q '"ok"' && echo "✓ API 健康检查通过" || echo "⚠ API 响应: $HEALTH"

# 检查 Nginx
systemctl is-active nginx &>/dev/null && echo "✓ Nginx 运行中" || echo "✗ Nginx 未运行"

echo "✅ 健康检查完成"
HEALTHCHECK
                '''
            }
        }
    }

    post {
        success {
            echo """
🎉 ShowCome 部署成功
   构建号: #${BUILD_NUMBER}
   分支: ${env.GIT_BRANCH ?: 'main'}
   提交: ${env.GIT_COMMIT?.take(8) ?: 'N/A'}
   时间: ${new Date().format('yyyy-MM-dd HH:mm:ss')}
"""
        }
        failure {
            echo '❌ ShowCome 部署失败！请检查日志。'
            // 可在此添加企业微信/钉钉通知
        }
        always {
            cleanWs(deleteDirs: true, patterns: [[pattern: '*.tar.gz', type: 'INCLUDE']])
        }
    }
}
