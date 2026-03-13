# 兽可梦 ShowCome · 完整生产部署手册

> 适用系统：Ubuntu 22.04 LTS / Debian 12  
> 架构：纯静态 HTML + Nginx + 可选 Node.js API 层  
> 预计耗时：30 ~ 60 分钟

---

## 一、架构说明

```
用户浏览器
    │
    ▼
[Cloudflare CDN] ← 可选，但强烈推荐
    │
    ▼
[Nginx]  :80 / :443
    ├─ /           → index.html    （前台展示）
    ├─ /admin      → admin.html    （后台管理，需 Basic Auth 双重保护）
    └─ /api        → Node.js :3000  （可选：持久化 API，替代 localStorage）
```

### 数据存储说明

| 存储层 | 用途 | 当前实现 | 推荐生产实现 |
|--------|------|----------|-------------|
| CMS 内容 | 站点配置、作品、商品等 | `localStorage` | SQLite / MySQL |
| 定制订单 | 用户提交表单 | `localStorage` | MySQL + 邮件通知 |
| 媒体文件 | 图片/视频资源 | URL 引用 | 对象存储 OSS/COS |
| 管理员账号 | 后台登录 | `localStorage` | bcrypt + JWT |

> **当前版本（localStorage 模式）** 可直接部署为纯静态站，无需数据库。  
> 数据保存在访问者浏览器中，适合单人管理场景。  
> 如需多人协作或数据持久化，参考第六章升级为 API 模式。

---

## 二、服务器环境初始化

### 2.1 购买服务器

推荐配置（个人工作室）：

- **CPU**：2 核
- **内存**：2 GB
- **硬盘**：40 GB SSD
- **带宽**：5 Mbps（按量计费）
- **系统**：Ubuntu 22.04 LTS 64位
- **供应商**：阿里云 / 腾讯云 / Vultr

### 2.2 首次登录与安全加固

```bash
# 以 root 登录后，立即执行
ssh root@YOUR_SERVER_IP

# ── 创建普通用户（避免 root 直接操作）──
adduser deploy
usermod -aG sudo deploy

# 切换到新用户
su - deploy

# ── 配置 SSH 密钥登录（在本地机器执行）──
# 生成密钥对（如果没有）
ssh-keygen -t ed25519 -C "showcomefu-server"

# 上传公钥到服务器
ssh-copy-id deploy@YOUR_SERVER_IP

# ── 禁用 root SSH 登录 ──
sudo nano /etc/ssh/sshd_config
# 修改以下两行：
#   PermitRootLogin no
#   PasswordAuthentication no
sudo systemctl restart sshd

# ── 配置防火墙 ──
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

### 2.3 系统更新与时区

```bash
# 更新系统
sudo apt update && sudo apt upgrade -y

# 设置时区（北京时间）
sudo timedatectl set-timezone Asia/Shanghai
timedatectl status

# 安装常用工具
sudo apt install -y curl wget git unzip vim htop net-tools
```

---

## 三、安装 Nginx

### 3.1 安装

```bash
sudo apt install -y nginx

# 启动并设置开机自启
sudo systemctl start nginx
sudo systemctl enable nginx
sudo systemctl status nginx

# 验证：访问 http://YOUR_SERVER_IP 应看到 Nginx 欢迎页
```

### 3.2 上传站点文件

**方法 A：直接 SCP 上传（推荐初次部署）**

```bash
# 在本地机器执行
scp index.html deploy@YOUR_SERVER_IP:/tmp/
scp admin.html deploy@YOUR_SERVER_IP:/tmp/

# 在服务器上移动文件
ssh deploy@YOUR_SERVER_IP
sudo mkdir -p /var/www/showcomefu
sudo mv /tmp/index.html /var/www/showcomefu/
sudo mv /tmp/admin.html /var/www/showcomefu/
sudo chown -R www-data:www-data /var/www/showcomefu
sudo chmod -R 755 /var/www/showcomefu
```

**方法 B：Git 部署（推荐持续维护）**

```bash
# 服务器上
sudo mkdir -p /var/www/showcomefu
sudo chown deploy:deploy /var/www/showcomefu
cd /var/www/showcomefu

# 如果文件在 Git 仓库
git init
git remote add origin https://github.com/YOUR_NAME/showcomefu.git
git pull origin main

# 后续更新只需
git pull origin main
sudo systemctl reload nginx
```

### 3.3 配置 Nginx 虚拟主机

```bash
# 删除默认站点
sudo rm /etc/nginx/sites-enabled/default

# 创建站点配置（替换 showcomefu.com 为你的域名）
sudo nano /etc/nginx/sites-available/showcomefu
```

粘贴以下配置（先用 HTTP，后续加 HTTPS）：

```nginx
# /etc/nginx/sites-available/showcomefu

# ── 访问频率限制（防 CC 攻击）──
limit_req_zone $binary_remote_addr zone=general:10m rate=20r/s;
limit_req_zone $binary_remote_addr zone=admin:10m rate=5r/s;

server {
    listen 80;
    listen [::]:80;

    server_name showcomefu.com www.showcomefu.com;

    # 站点根目录
    root /var/www/showcomefu;
    index index.html;

    # 字符集
    charset utf-8;

    # ── 访问日志 ──
    access_log /var/log/nginx/showcomefu_access.log;
    error_log  /var/log/nginx/showcomefu_error.log warn;

    # ── 安全响应头 ──
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # ── 前台主站 ──
    location / {
        limit_req zone=general burst=30 nodelay;
        try_files $uri $uri/ /index.html;

        # 静态资源缓存
        location ~* \.(js|css|png|jpg|jpeg|gif|webp|svg|ico|woff2)$ {
            expires 30d;
            add_header Cache-Control "public, immutable";
        }
    }

    # ── 后台管理（双重保护）──
    location /admin {
        # Nginx Basic Auth（第一层）
        auth_basic "ShowCome Admin";
        auth_basic_user_file /etc/nginx/.htpasswd;

        # 频率限制（防暴力破解）
        limit_req zone=admin burst=10 nodelay;

        # IP 白名单（可选，更安全）
        # allow 你的固定IP;
        # deny all;

        try_files $uri $uri/ /admin.html;
    }

    # ── 禁止访问隐藏文件 ──
    location ~ /\. {
        deny all;
        return 404;
    }

    # ── 可选：API 反向代理（第六章启用）──
    # location /api/ {
    #     proxy_pass http://127.0.0.1:3000/;
    #     proxy_http_version 1.1;
    #     proxy_set_header Host $host;
    #     proxy_set_header X-Real-IP $remote_addr;
    # }
}
```

```bash
# 启用站点配置
sudo ln -s /etc/nginx/sites-available/showcomefu /etc/nginx/sites-enabled/

# 测试配置语法
sudo nginx -t

# 重载 Nginx
sudo systemctl reload nginx
```

### 3.4 设置后台 Basic Auth

```bash
# 安装 htpasswd 工具
sudo apt install -y apache2-utils

# 创建密码文件（替换 admin 为你想要的用户名）
sudo htpasswd -c /etc/nginx/.htpasswd admin
# 输入两次密码后回车

# 查看文件（密码已加密，安全）
cat /etc/nginx/.htpasswd

# 后续添加更多用户
# sudo htpasswd /etc/nginx/.htpasswd editor2
```

> ⚠️ **双重验证**：访问 `/admin` 需先通过 Nginx 的 HTTP Basic Auth，  
> 再通过页面内的账号密码登录，两道防线确保后台安全。

---

## 四、配置 HTTPS（SSL 证书）

### 4.1 域名解析

在你的域名管理后台（阿里云/腾讯云/Cloudflare）添加：

| 记录类型 | 主机记录 | 记录值 |
|---------|---------|--------|
| A | @ | YOUR_SERVER_IP |
| A | www | YOUR_SERVER_IP |

等待 DNS 生效（通常 5-10 分钟）：

```bash
# 验证解析
ping showcomefu.com
nslookup showcomefu.com
```

### 4.2 申请免费 Let's Encrypt 证书

```bash
# 安装 Certbot
sudo apt install -y certbot python3-certbot-nginx

# 申请证书（自动修改 Nginx 配置）
sudo certbot --nginx -d showcomefu.com -d www.showcomefu.com

# 按提示输入邮箱，同意条款，选择是否强制 HTTPS（建议选 2：强制跳转）

# 验证证书
sudo certbot certificates

# 测试自动续期
sudo certbot renew --dry-run
```

### 4.3 Certbot 自动续期

```bash
# Certbot 已自动添加 systemd 定时任务，查看确认
sudo systemctl status certbot.timer
sudo systemctl list-timers | grep certbot

# 手动查看定时任务
cat /etc/cron.d/certbot
```

### 4.4 完整 HTTPS Nginx 配置（certbot 自动生成后的样子）

```nginx
server {
    listen 80;
    server_name showcomefu.com www.showcomefu.com;
    # 强制跳转 HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name showcomefu.com www.showcomefu.com;

    # SSL 证书（Certbot 自动填写）
    ssl_certificate /etc/letsencrypt/live/showcomefu.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/showcomefu.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # HSTS（浏览器强制 HTTPS，谨慎开启）
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root /var/www/showcomefu;
    index index.html;
    charset utf-8;

    access_log /var/log/nginx/showcomefu_access.log;
    error_log  /var/log/nginx/showcomefu_error.log warn;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    # Gzip 压缩
    gzip on;
    gzip_types text/html text/css application/javascript application/json;
    gzip_min_length 1000;

    location / {
        try_files $uri $uri/ /index.html;
        location ~* \.(js|css|png|jpg|jpeg|gif|webp|svg|ico|woff2)$ {
            expires 30d;
            add_header Cache-Control "public, immutable";
        }
    }

    location /admin {
        auth_basic "ShowCome Admin";
        auth_basic_user_file /etc/nginx/.htpasswd;
        try_files $uri $uri/ /admin.html;
    }

    location ~ /\. { deny all; }
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## 五、进程管理与监控

### 5.1 Nginx 日志监控

```bash
# 实时查看访问日志
sudo tail -f /var/log/nginx/showcomefu_access.log

# 查看错误日志
sudo tail -f /var/log/nginx/showcomefu_error.log

# 统计今日访问量
sudo awk '{print $1}' /var/log/nginx/showcomefu_access.log | sort | uniq -c | sort -rn | head -20

# 日志轮转（Nginx 默认已配置，查看确认）
cat /etc/logrotate.d/nginx
```

### 5.2 系统资源监控

```bash
# 安装 htop
sudo apt install -y htop

# 查看磁盘使用
df -h

# 查看内存
free -h

# 查看 Nginx 进程状态
sudo systemctl status nginx

# 设置 Nginx 崩溃自动重启
sudo systemctl edit nginx
# 添加以下内容：
# [Service]
# Restart=always
# RestartSec=5s
```

### 5.3 设置简单备份

```bash
# 创建备份脚本
sudo nano /usr/local/bin/backup-showcomefu.sh
```

```bash
#!/bin/bash
# /usr/local/bin/backup-showcomefu.sh

BACKUP_DIR="/home/deploy/backups"
DATE=$(date +%Y%m%d_%H%M%S)
SITE_DIR="/var/www/showcomefu"

mkdir -p "$BACKUP_DIR"

# 备份站点文件
tar -czf "$BACKUP_DIR/site_$DATE.tar.gz" -C "$SITE_DIR" .

# 保留最近 30 个备份
ls -t "$BACKUP_DIR"/site_*.tar.gz | tail -n +31 | xargs -r rm

echo "[$DATE] 备份完成: site_$DATE.tar.gz"
```

```bash
sudo chmod +x /usr/local/bin/backup-showcomefu.sh

# 添加定时备份（每天凌晨 3 点）
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/backup-showcomefu.sh >> /home/deploy/backups/backup.log 2>&1") | crontab -

# 验证
crontab -l
```

---

## 六、可选：Node.js API 层（数据持久化）

> 如果需要多设备管理、数据持久化、邮件通知，需部署此层。  
> localStorage 模式无需此章节。

### 6.1 安装 Node.js 20

```bash
# 使用 NodeSource 官方源
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# 验证
node --version   # v20.x.x
npm --version    # 10.x.x
```

### 6.2 安装 MySQL 8

```bash
sudo apt install -y mysql-server

# 安全初始化
sudo mysql_secure_installation
# ↑ 设置 root 密码，删除匿名用户，禁止远程 root 登录

# 登录 MySQL
sudo mysql -u root -p

# 创建数据库和用户
CREATE DATABASE showcomefu CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'showcome'@'localhost' IDENTIFIED BY 'STRONG_PASSWORD_HERE';
GRANT ALL PRIVILEGES ON showcomefu.* TO 'showcome'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

### 6.3 数据库表结构初始化

```sql
-- 连接数据库
USE showcomefu;

-- CMS 内容键值存储（灵活，适合 JSON 内容）
CREATE TABLE cms_data (
    `key`       VARCHAR(100) NOT NULL PRIMARY KEY,
    `value`     LONGTEXT NOT NULL,
    updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    updated_by  VARCHAR(50) DEFAULT 'admin'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 管理员账号
CREATE TABLE admins (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(50) UNIQUE NOT NULL,
    password    VARCHAR(255) NOT NULL COMMENT 'bcrypt hash',
    role        ENUM('admin','editor','viewer') DEFAULT 'editor',
    last_login  DATETIME,
    active      TINYINT(1) DEFAULT 1,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 定制订单
CREATE TABLE orders (
    id          VARCHAR(30) PRIMARY KEY,
    nickname    VARCHAR(100),
    contact     VARCHAR(200),
    type        VARCHAR(100),
    budget      VARCHAR(50),
    species     VARCHAR(100),
    ref_url     VARCHAR(500),
    note        TEXT,
    status      ENUM('new','contacted','designing','making','done','cancelled') DEFAULT 'new',
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 媒体文件记录
CREATE TABLE media (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    type        ENUM('image','video','audio','model','other') NOT NULL,
    url         VARCHAR(1000) NOT NULL,
    thumb_url   VARCHAR(1000),
    size_bytes  BIGINT,
    mime_type   VARCHAR(100),
    uploaded_by VARCHAR(50),
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 操作日志
CREATE TABLE activity_log (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    user        VARCHAR(50),
    action      VARCHAR(200),
    detail      TEXT,
    ip          VARCHAR(50),
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 插入默认管理员（密码需用 bcrypt 哈希，见 API 代码）
-- 临时明文，上线后立即通过 API 修改
INSERT INTO admins (username, password, role) 
VALUES ('admin', '$2b$12$PLACEHOLDER_CHANGE_ON_FIRST_LOGIN', 'admin');
```

### 6.4 搭建 Node.js API 服务

```bash
# 创建 API 项目目录
mkdir -p /opt/showcomefu-api
cd /opt/showcomefu-api

# 初始化项目
npm init -y

# 安装依赖
npm install express mysql2 bcryptjs jsonwebtoken cors helmet express-rate-limit dotenv

# 创建环境变量文件
nano .env
```

`.env` 文件内容：

```env
PORT=3000
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=showcomefu
DB_USER=showcome
DB_PASS=STRONG_PASSWORD_HERE
JWT_SECRET=CHANGE_THIS_TO_RANDOM_64_CHAR_STRING
JWT_EXPIRES=24h
ADMIN_DEFAULT_PASS=showcome2024
NODE_ENV=production
```

`server.js` 核心代码：

```javascript
// /opt/showcomefu-api/server.js
require('dotenv').config();
const express = require('express');
const mysql   = require('mysql2/promise');
const bcrypt  = require('bcryptjs');
const jwt     = require('jsonwebtoken');
const cors    = require('cors');
const helmet  = require('helmet');
const rateLimit = require('express-rate-limit');

const app = express();
const PORT = process.env.PORT || 3000;

// ── Middleware ──
app.use(helmet());
app.use(cors({ origin: process.env.FRONTEND_URL || '*' }));
app.use(express.json({ limit: '2mb' }));

// ── DB Pool ──
const pool = mysql.createPool({
    host: process.env.DB_HOST,
    port: process.env.DB_PORT,
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASS,
    waitForConnections: true,
    connectionLimit: 10,
    charset: 'utf8mb4',
});

// ── Auth Middleware ──
const authLimiter = rateLimit({ windowMs: 15*60*1000, max: 10 });

function authRequired(req, res, next) {
    const token = req.headers.authorization?.split(' ')[1];
    if (!token) return res.status(401).json({ error: '未授权' });
    try {
        req.user = jwt.verify(token, process.env.JWT_SECRET);
        next();
    } catch {
        res.status(401).json({ error: 'Token 无效或已过期' });
    }
}

// ── Routes: Auth ──
app.post('/api/auth/login', authLimiter, async (req, res) => {
    const { username, password } = req.body;
    const [rows] = await pool.query(
        'SELECT * FROM admins WHERE username=? AND active=1', [username]
    );
    const admin = rows[0];
    if (!admin || !await bcrypt.compare(password, admin.password)) {
        return res.status(401).json({ error: '账号或密码错误' });
    }
    await pool.query('UPDATE admins SET last_login=NOW() WHERE id=?', [admin.id]);
    const token = jwt.sign(
        { id: admin.id, username: admin.username, role: admin.role },
        process.env.JWT_SECRET,
        { expiresIn: process.env.JWT_EXPIRES }
    );
    res.json({ token, user: { username: admin.username, role: admin.role } });
});

// ── Routes: CMS 内容 ──
app.get('/api/cms/:key', async (req, res) => {
    const [rows] = await pool.query('SELECT value FROM cms_data WHERE `key`=?', [req.params.key]);
    if (!rows[0]) return res.status(404).json({ error: '未找到' });
    res.json(JSON.parse(rows[0].value));
});

app.put('/api/cms/:key', authRequired, async (req, res) => {
    const value = JSON.stringify(req.body);
    await pool.query(
        'INSERT INTO cms_data (`key`,`value`,updated_by) VALUES (?,?,?) ON DUPLICATE KEY UPDATE `value`=?,updated_by=?,updated_at=NOW()',
        [req.params.key, value, req.user.username, value, req.user.username]
    );
    res.json({ ok: true });
});

// ── Routes: 订单 ──
app.post('/api/orders', async (req, res) => {
    const { nickname, contact, type, budget, species, refUrl, note } = req.body;
    if (!contact) return res.status(400).json({ error: '联系方式必填' });
    const id = 'O' + Date.now();
    await pool.query(
        'INSERT INTO orders (id,nickname,contact,type,budget,species,ref_url,note) VALUES (?,?,?,?,?,?,?,?)',
        [id, nickname, contact, type, budget, species, refUrl, note]
    );
    res.json({ ok: true, id });
});

app.get('/api/orders', authRequired, async (req, res) => {
    const [rows] = await pool.query('SELECT * FROM orders ORDER BY created_at DESC LIMIT 200');
    res.json(rows);
});

app.patch('/api/orders/:id/status', authRequired, async (req, res) => {
    await pool.query('UPDATE orders SET status=? WHERE id=?', [req.body.status, req.params.id]);
    res.json({ ok: true });
});

// ── Routes: 媒体 ──
app.get('/api/media', authRequired, async (req, res) => {
    const [rows] = await pool.query('SELECT * FROM media ORDER BY created_at DESC');
    res.json(rows);
});

app.post('/api/media', authRequired, async (req, res) => {
    const { name, type, url, thumbUrl, sizeBytes, mimeType } = req.body;
    const [r] = await pool.query(
        'INSERT INTO media (name,type,url,thumb_url,size_bytes,mime_type,uploaded_by) VALUES (?,?,?,?,?,?,?)',
        [name, type, url, thumbUrl, sizeBytes, mimeType, req.user.username]
    );
    res.json({ ok: true, id: r.insertId });
});

// ── 健康检查 ──
app.get('/api/health', async (req, res) => {
    try {
        await pool.query('SELECT 1');
        res.json({ status: 'ok', time: new Date().toISOString() });
    } catch {
        res.status(500).json({ status: 'db_error' });
    }
});

app.listen(PORT, '127.0.0.1', () => {
    console.log(`ShowCome API running on port ${PORT}`);
});
```

### 6.5 使用 PM2 管理 Node 进程

```bash
# 全局安装 PM2
sudo npm install -g pm2

# 启动 API 服务
cd /opt/showcomefu-api
pm2 start server.js --name "showcomefu-api"

# 设置开机自启
pm2 startup systemd
# ↑ 复制并执行输出的命令

pm2 save

# 常用命令
pm2 status                          # 查看进程状态
pm2 logs showcomefu-api             # 查看日志
pm2 restart showcomefu-api          # 重启
pm2 reload showcomefu-api           # 零停机重载
pm2 stop showcomefu-api             # 停止
pm2 monit                           # 实时监控面板
```

### 6.6 初始化默认管理员密码

```bash
# 生成 bcrypt 哈希（在服务器执行）
node -e "
const bcrypt = require('bcryptjs');
bcrypt.hash('showcome2024', 12).then(h => {
  console.log(h);
  process.exit(0);
});
"
# 复制输出的哈希值

# 更新数据库
sudo mysql -u showcome -p showcomefu
UPDATE admins SET password='[上面的哈希值]' WHERE username='admin';
EXIT;
```

---

## 七、Nginx 开启 API 反向代理

取消第三章配置中 API 代理的注释：

```bash
sudo nano /etc/nginx/sites-available/showcomefu
```

```nginx
# 取消注释这段
location /api/ {
    proxy_pass http://127.0.0.1:3000/api/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_cache_bypass $http_upgrade;
    proxy_read_timeout 60s;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx

# 测试 API
curl https://showcomefu.com/api/health
```

---

## 八、CDN 加速（推荐 Cloudflare）

### 8.1 接入 Cloudflare

1. 注册 [cloudflare.com](https://cloudflare.com) 免费账号
2. 添加站点，输入你的域名
3. 将域名的 NS（名称服务器）改为 Cloudflare 提供的 NS
4. 等待生效（最长 24 小时，通常 5 分钟）

### 8.2 Cloudflare 推荐配置

```
SSL/TLS 模式：Full (Strict)    ← 需要服务器已有 SSL 证书
最低 TLS 版本：TLS 1.2
自动 HTTPS 重写：开启
HTTP/3 (QUIC)：开启
Brotli 压缩：开启

缓存规则：
  /admin*  → 不缓存（Bypass Cache）
  /api/*   → 不缓存（Bypass Cache）
  /*       → 缓存 1 天

防火墙规则：
  CF.Bot Score < 30  → Block（防爬虫）
```

---

## 九、更新部署流程

### 日常更新（修改了 HTML 文件后）

```bash
# 方法 A：SCP 直接上传
scp index.html admin.html deploy@YOUR_SERVER_IP:/tmp/
ssh deploy@YOUR_SERVER_IP "
  sudo cp /tmp/index.html /var/www/showcomefu/
  sudo cp /tmp/admin.html /var/www/showcomefu/
  sudo chown www-data:www-data /var/www/showcomefu/*.html
  echo '部署完成'
"

# 方法 B：Git 拉取
ssh deploy@YOUR_SERVER_IP "
  cd /var/www/showcomefu
  git pull origin main
  sudo systemctl reload nginx
"
```

### 回滚（出现问题时）

```bash
# 查看备份列表
ls -lt ~/backups/site_*.tar.gz

# 回滚到指定版本
sudo tar -xzf ~/backups/site_20240101_030000.tar.gz -C /var/www/showcomefu/
sudo systemctl reload nginx
```

---

## 十、常见问题排查

```bash
# ── 502 Bad Gateway ──
pm2 status                          # 检查 Node 进程是否运行
pm2 logs showcomefu-api --lines 50  # 查看错误日志
sudo tail -f /var/log/nginx/showcomefu_error.log

# ── 403 Forbidden ──
ls -la /var/www/showcomefu/         # 检查文件权限
sudo chown -R www-data:www-data /var/www/showcomefu
sudo chmod -R 755 /var/www/showcomefu

# ── 证书过期 ──
sudo certbot renew                  # 手动续期
sudo certbot certificates           # 查看证书有效期

# ── Nginx 配置错误 ──
sudo nginx -t                       # 检查配置语法
sudo journalctl -u nginx -n 50      # 查看 systemd 日志

# ── MySQL 连接失败 ──
sudo systemctl status mysql
sudo tail -f /var/log/mysql/error.log
mysql -u showcome -p showcomefu -e "SELECT 1"

# ── 防火墙拦截 ──
sudo ufw status verbose
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# ── 磁盘满了 ──
df -h                               # 查看磁盘使用
du -sh /var/log/nginx/*             # 查看日志占用
sudo truncate -s 0 /var/log/nginx/showcomefu_access.log  # 清空日志
```

---

## 十一、部署检查清单

完成部署后，逐项核对：

- [ ] 访问 `https://showcomefu.com` 前台正常显示
- [ ] HTTPS 证书有效，无浏览器警告
- [ ] `http://` 自动跳转到 `https://`
- [ ] 访问 `https://showcomefu.com/admin` 弹出 Basic Auth 对话框
- [ ] 输入 Basic Auth 后，能看到 CMS 登录页
- [ ] CMS 账号 `admin` / `showcome2024` 可以登录
- [ ] 登录后能看到仪表盘，数据正常
- [ ] 保存设置后点击"预览前台"，内容同步更新
- [ ] `sudo certbot renew --dry-run` 输出 success
- [ ] `pm2 status` 显示 API 进程 online（如启用了 API）
- [ ] 定时备份脚本正常执行
- [ ] `ufw status` 只开放 22、80、443 端口

---

## 附录：服务器命令速查

```bash
# Nginx
sudo systemctl start|stop|reload|restart nginx
sudo nginx -t                  # 测试配置
sudo tail -f /var/log/nginx/showcomefu_error.log

# MySQL
sudo systemctl start|stop|status mysql
sudo mysql -u showcome -p showcomefu

# PM2 (Node.js)
pm2 start|stop|restart|reload|status|logs

# 系统
htop                           # 资源监控
df -h                          # 磁盘空间
free -h                        # 内存
sudo ufw status                # 防火墙状态
sudo journalctl -u nginx -f    # 实时系统日志
```
