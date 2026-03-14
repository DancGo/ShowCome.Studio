#!/bin/bash
set -e
# 从 Jenkins 参数中获取端口，若缺失则默认为 3366
TARGET_PORT=3366
APP_DIR="/www/wwwroot/showcome_studio"
ARCHIVE_PATTERN="showcomefu-bt-*.tar.gz"

echo "==== 1. 开始部署应用 (目标端口: $TARGET_PORT) ===="
cd $APP_DIR

# 找到刚上传的压缩包并解压
ARCHIVE_FILE=$(ls -t $ARCHIVE_PATTERN | head -1)
if [ -f "$ARCHIVE_FILE" ]; then
    echo "解压制品: $ARCHIVE_FILE"
    tar -xzf $ARCHIVE_FILE --overwrite
    rm -f $ARCHIVE_PATTERN
else
    echo "错误：未找到上传的压缩包！"
    exit 1
fi

echo "==== 2. 更新或注入端口变量 ===="
# 如果 .env 已存在，则更新 PORT；若不存在则创建
if [ -f ".env" ]; then
    # 使用 sed 替换已有的 PORT 配置，或者追加
    if grep -q "PORT=" .env; then
        sed -i "s/^PORT=.*/PORT=$TARGET_PORT/" .env
    else
        echo "PORT=$TARGET_PORT" >> .env
    fi
else
    echo "PORT=$TARGET_PORT" > .env
    echo "NODE_ENV=production" >> .env
fi

echo "==== 3. 安装服务器端依赖 ===="
export PATH=$PATH:/www/server/nodejs/v20.20.1/bin
npm ci --omit=dev --silent || npm install --omit=dev --silent

echo "==== 4. 数据库自动迁移 ===="
export NODE_ENV=production
if [ -f "installed.lock" ]; then
    echo "检测到系统已初始化，执行增量迁移..."
    /www/server/nodejs/v20/bin/node migrate.js
fi

echo "==== 5. 纠正文件所有者权限 ===="
chown -R www:www $APP_DIR

echo "==== 6. 重启 PM2 后端 API ===="
# 主动将 PORT 暴露为环境变量，确保 --update-env 能够捕获到最新的值
export PORT=$TARGET_PORT
# 使用变量启动/重载，确保端口生效
pm2 reload showcome_api --update-env || pm2 start server.js --name showcome_api --env PORT=$TARGET_PORT --time
pm2 save

echo "==== 部署全部完成 ===="