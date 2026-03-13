# 兽可梦 ShowCome · 生产部署手册

> **部署架构**：Gitee + Jenkins 自动化 CI/CD → CentOS 云服务器  
> **首次部署**：通过 Web 向导完成初始化配置  
> **数据库升级**：每次部署自动执行迁移脚本

---

## 架构概览

```
开发者 → git push → Gitee 仓库
                        │
                    WebHook 触发
                        │
                        ▼
                    Jenkins 服务器
                    ├─ 拉取代码
                    ├─ npm install
                    ├─ 打包制品
                    ├─ SCP 上传
                    └─ SSH 远程部署
                        │
                        ▼
                CentOS 生产服务器
                ├─ /var/www/showcomefu/     ← 静态文件 (Nginx)
                ├─ /opt/showcomefu/        ← API 服务 (PM2 + Node.js)
                ├─ MySQL 8                 ← 数据持久化
                └─ 阿里云 OSS              ← 媒体文件存储
```

### 技术栈

| 组件 | 技术 |
|------|------|
| 前端 | 纯 HTML + CSS + JavaScript（Three.js / GSAP） |
| 后端 | Node.js 20+ / Express |
| 数据库 | MySQL 8.0+ |
| 对象存储 | 阿里云 OSS |
| Web 服务器 | Nginx |
| 进程管理 | PM2 |
| CI/CD | Gitee + Jenkins |
| 操作系统 | CentOS 7/8/9 |

---

## 一、服务器环境初始化（首次）

### 1.1 服务器推荐配置

| 项目 | 推荐 |
|------|------|
| CPU | 2 核+ |
| 内存 | 2 GB+ |
| 硬盘 | 40 GB SSD |
| 带宽 | 3-5 Mbps |
| 系统 | CentOS 7/8/9 或 Rocky Linux |

### 1.2 一键初始化

将仓库中的 `deploy/centos-init.sh` 上传到服务器执行：

```bash
# 上传脚本
scp deploy/centos-init.sh root@YOUR_SERVER_IP:/tmp/

# SSH 到服务器执行
ssh root@YOUR_SERVER_IP
bash /tmp/centos-init.sh --domain showcomefu.com --email admin@showcomefu.com --with-mysql
```

此脚本将自动完成：
- 系统更新 & 基础工具安装
- 防火墙配置（开放 22/80/443）
- Node.js 20 + PM2 安装
- Nginx 安装 & 站点配置
- MySQL 8 安装（`--with-mysql`）
- SSL 证书申请（Let's Encrypt）
- 日志轮转配置

### 1.3 MySQL 安全初始化

```bash
mysql_secure_installation
# 按提示设置 root 密码、删除匿名用户、禁止远程 root 登录

# 创建应用数据库用户
mysql -u root -p
CREATE USER 'showcome'@'localhost' IDENTIFIED BY '你的强密码';
GRANT ALL PRIVILEGES ON showcomefu.* TO 'showcome'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

---

## 二、Jenkins 配置

### 2.1 安装 Jenkins（如未安装）

```bash
# CentOS
sudo yum install -y java-17-openjdk
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo yum install -y jenkins
sudo systemctl enable jenkins && sudo systemctl start jenkins
```

### 2.2 安装必要插件

在 Jenkins 管理面板安装：
- **Gitee Plugin** — Gitee WebHook 集成
- **Generic Webhook Trigger Plugin** — 通用 WebHook 触发
- **SSH Agent Plugin** — SSH 密钥管理
- **NodeJS Plugin** — Node.js 环境（或服务器已全局安装则不需要）

### 2.3 配置 Jenkins 凭据

在 `Jenkins → 凭据 → 系统 → 全局凭据` 中添加：

| 凭据 ID | 类型 | 说明 |
|---------|------|------|
| `showcomefu-ssh-user` | Secret text | 服务器 SSH 用户名（如 `root`） |
| `showcomefu-ssh-host` | Secret text | 服务器 IP 地址 |
| `showcomefu-ssh-key` | SSH Username with private key | SSH 私钥 |

### 2.4 创建流水线任务

1. **新建任务** → 输入名称 `showcomefu-deploy` → 选择「流水线」
2. **构建触发器**：
   - 勾选 `Generic Webhook Trigger`
   - Token 填写：`showcomefu-deploy`
3. **流水线定义**：
   - 选择「Pipeline script from SCM」
   - SCM：Git
   - Repository URL：`https://gitee.com/你的用户名/ShowCome.Studio.git`
   - 凭据：添加 Gitee 账号凭据
   - 分支：`*/main`
   - Script Path：`Jenkinsfile`

### 2.5 配置 Gitee WebHook

在 Gitee 仓库 → 管理 → WebHooks 中添加：

```
URL: http://你的Jenkins地址/generic-webhook-trigger/invoke?token=showcomefu-deploy
触发事件: Push
```

### 2.6 SSH 密钥配对

```bash
# 在 Jenkins 服务器生成密钥
ssh-keygen -t ed25519 -C "jenkins-deploy" -f ~/.ssh/showcomefu_deploy

# 将公钥添加到生产服务器
ssh-copy-id -i ~/.ssh/showcomefu_deploy.pub root@YOUR_SERVER_IP

# 将私钥内容添加到 Jenkins 凭据 showcomefu-ssh-key
cat ~/.ssh/showcomefu_deploy
```

---

## 三、首次部署

### 3.1 触发首次构建

方式 A：在 Jenkins 中手动点击「立即构建」

方式 B：推送代码到 Gitee main 分支自动触发

```bash
git push origin main
```

### 3.2 Web 初始化向导

首次部署完成后，API 服务启动在「未初始化」模式：

1. 浏览器访问 `http://你的域名/setup`（或 `http://IP:端口/setup`）
2. **第 1 步 — 数据库配置**：填写 MySQL 连接信息，点击「测试连接」
3. **第 2 步 — 管理员账号**：设置超级管理员用户名和密码
4. **第 3 步 — OSS 配置**：填写阿里云 OSS 配置（可跳过，稍后在后台配置）
5. **第 4 步 — 确认初始化**：检查配置后点击「开始初始化」

初始化完成后系统自动：
- 创建 `.env` 配置文件
- 执行所有数据库迁移脚本（建表）
- 创建管理员账号
- 生成 `installed.lock` 锁文件

> ⚠️ `installed.lock` 文件存在时不会再显示初始化向导。如需重新初始化，需手动删除该文件和 `.env`。

### 3.3 登录管理后台

初始化完成后访问 `/admin`，使用刚才设置的管理员账号登录。

---

## 四、数据库迁移机制

### 4.1 工作原理

```
migrations/
├── 001_initial_schema.sql     ← 初始表结构
├── 002_add_system_config.sql  ← 系统配置表
├── 003_xxx_feature.sql        ← 后续迭代新增
└── ...
```

- 迁移文件命名：`{三位序号}_{描述}.sql`
- 每个迁移文件只执行一次，记录在 `migrations_history` 表
- 每次 Jenkins 部署时自动执行 `node migrate.js`
- 已执行的迁移不会重复运行

### 4.2 添加新迁移

当需要修改表结构时：

1. 在 `migrations/` 目录创建新文件，序号递增：
```sql
-- migrations/003_add_coupon_table.sql
CREATE TABLE IF NOT EXISTS `coupons` (
  `id`   INT NOT NULL AUTO_INCREMENT,
  `code` VARCHAR(50) NOT NULL,
  ...
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

2. 提交并推送到 Gitee：
```bash
git add migrations/003_add_coupon_table.sql
git commit -m "feat: 添加优惠券表"
git push origin main
```

3. Jenkins 自动部署时会执行新迁移

### 4.3 手动执行迁移

```bash
# 在服务器上
cd /opt/showcomefu

# 查看迁移状态
node migrate.js --status

# 执行待执行的迁移
node migrate.js

# 迁移到指定版本
node migrate.js --target 003
```

### 4.4 管理后台迁移

登录管理后台后，也可通过 API 查看和执行迁移：

```bash
# 查看迁移状态
GET /api/migrations

# 执行迁移
POST /api/migrations/run
```

---

## 五、阿里云 OSS 配置

### 5.1 创建 OSS Bucket

1. 登录 [阿里云 OSS 控制台](https://oss.console.aliyun.com/)
2. 创建 Bucket：
   - 名称：`showcomefu`（自定义）
   - 地域：选择离服务器近的区域
   - 存储类型：标准存储
   - 读写权限：**公共读**（媒体文件需公开访问）
3. 跨域设置（CORS）：
   - 来源：`*`（或限制为你的域名）
   - 允许方法：`GET, POST, PUT`
   - 允许头：`*`

### 5.2 创建 AccessKey

1. 阿里云控制台 → RAM 访问控制 → 用户 → 创建用户
2. 勾选「OpenAPI 调用访问」
3. 授予 `AliyunOSSFullAccess` 权限
4. 记录 AccessKey ID 和 AccessKey Secret

### 5.3 配置方式

**方式 A：在初始化向导中配置**（推荐首次部署）

**方式 B：修改 `.env` 文件**

```bash
# 在服务器上
cd /opt/showcomefu
vi .env

# 添加/修改以下配置
OSS_REGION=oss-cn-haikou
OSS_BUCKET=showcomefu
OSS_ACCESS_KEY_ID=你的AK
OSS_ACCESS_KEY_SECRET=你的SK
OSS_ENDPOINT=https://oss-cn-haikou.aliyuncs.com
OSS_CDN_DOMAIN=cdn.showcomefu.com

# 重启服务
pm2 reload showcomefu-api
```

### 5.4 前端上传流程

```
前端 → POST /api/oss/sign（获取签名）→ 直传 OSS → 回调存入 media 表
```

- `/api/oss/sign`：生成 OSS PostObject 签名，前端凭签名直传 OSS
- `/api/oss/status`：查看 OSS 配置状态

---

## 六、CI/CD 流水线详解

### 6.1 Jenkinsfile 流程

```
检出代码 → 代码检查 → 安装依赖 → 打包制品 → 上传到服务器 → 部署&迁移 → 健康检查
```

| 阶段 | 说明 |
|------|------|
| 检出代码 | 从 Gitee 拉取最新 main 分支 |
| 代码检查 | 验证关键文件完整性 |
| 安装依赖 | `npm ci --omit=dev` |
| 打包制品 | 排除 node_modules/.git/.env 后打包为 tar.gz |
| 上传到服务器 | SCP 传输到 `/tmp/` |
| 部署&迁移 | 解压、安装依赖、执行迁移、更新静态文件、重启 PM2 |
| 健康检查 | 验证 API 和 Nginx 运行状态 |

### 6.2 部署安全

- `.env` 和 `installed.lock` 不在 Git 仓库中，部署不会覆盖
- 每次部署自动备份到 `/opt/showcomefu-backups/`
- 保留最近 10 个备份

### 6.3 回滚

```bash
# 查看可用备份
ls -lt /opt/showcomefu-backups/

# 回滚到最新备份
sudo bash /opt/showcomefu/deploy/rollback.sh

# 回滚到指定版本
sudo bash /opt/showcomefu/deploy/rollback.sh backup-20260313_120000.tar.gz
```

---

## 七、日常运维

### 7.1 常用命令

```bash
# API 服务
pm2 status                         # 查看进程状态
pm2 logs showcomefu-api            # 查看日志
pm2 reload showcomefu-api          # 零停机重载
pm2 restart showcomefu-api         # 重启
pm2 monit                          # 实时监控

# Nginx
nginx -t                           # 检查配置
systemctl reload nginx             # 重载
tail -f /var/log/nginx/showcomefu_access.log

# MySQL
mysql -u showcome -p showcomefu    # 进入数据库
mysqldump -u showcome -p showcomefu > backup.sql  # 导出

# 迁移
cd /opt/showcomefu
node migrate.js --status           # 查看迁移状态
node migrate.js                    # 执行迁移
```

### 7.2 SSL 证书续期

```bash
# 测试续期
certbot renew --dry-run

# 手动续期
certbot renew
systemctl reload nginx
```

### 7.3 服务器监控

```bash
htop                              # CPU/内存
df -h                             # 磁盘
free -h                           # 内存
systemctl status nginx mysql      # 服务状态
pm2 monit                         # API 监控
```

---

## 八、项目目录结构

```
ShowCome.Studio/
├── index.html              # 前台展示页
├── admin.html              # 后台管理页
├── setup.html              # 首次初始化向导
├── server.js               # Node.js API 服务
├── package.json            # Node.js 依赖声明
├── migrate.js              # 数据库迁移运行器
├── init-admin.js           # 管理员密码初始化工具
├── .env.example            # 环境变量模板
├── .gitignore
├── Jenkinsfile             # Jenkins CI/CD 流水线
├── migrations/             # 数据库迁移文件
│   ├── 001_initial_schema.sql
│   └── 002_add_system_config.sql
├── deploy/                 # 部署脚本
│   ├── centos-init.sh      # CentOS 服务器初始化
│   ├── deploy.sh           # 部署执行脚本
│   └── rollback.sh         # 版本回滚脚本
├── schema.sql              # 完整数据库 Schema（参考用）
├── setup.sh                # 旧版 Ubuntu 部署脚本（保留兼容）
└── DEPLOY.md               # 本文档
```

### 服务器目录

```
/opt/showcomefu/             # API 源码 + Node 依赖
    ├── .env                 # 运行时配置（不在 Git 中）
    ├── installed.lock       # 安装锁文件（不在 Git 中）
    └── node_modules/

/opt/showcomefu-backups/     # 部署备份

/var/www/showcomefu/         # Nginx 静态文件
    ├── index.html
    ├── admin.html
    └── setup.html
```

---

## 九、故障排查

```bash
# API 502 Bad Gateway
pm2 status                          # 检查进程是否运行
pm2 logs showcomefu-api --lines 50  # 查看错误日志
curl http://127.0.0.1:3000/api/health  # 直接访问 API

# Nginx 配置错误
nginx -t
journalctl -u nginx -n 50

# 数据库连接失败
systemctl status mysqld
mysql -u showcome -p showcomefu -e "SELECT 1"

# 首次部署 setup 页面不显示
pm2 logs showcomefu-api             # 检查 API 是否启动
cat /opt/showcomefu/installed.lock  # 是否已有锁文件

# 迁移失败
cd /opt/showcomefu && node migrate.js --status
mysql -u showcome -p showcomefu -e "SELECT * FROM migrations_history"

# OSS 上传失败
curl http://127.0.0.1:3000/api/oss/status  # 检查 OSS 配置
```

---

## 十、安全建议

1. **SSH 密钥登录**：禁用密码登录，仅使用密钥
2. **防火墙**：仅开放 22/80/443 端口
3. **HTTPS**：始终使用 SSL 证书
4. **数据库**：MySQL 仅监听 127.0.0.1，禁止远程直连
5. **`.env` 权限**：设为 600，仅 root 可读
6. **定期备份**：配置 crontab 每日备份数据库
7. **OSS 权限**：使用 RAM 子账号，仅授予必要的 OSS 权限

```bash
# 配置每日数据库备份
(crontab -l 2>/dev/null; echo "0 3 * * * mysqldump -u showcome -p'密码' showcomefu | gzip > /opt/showcomefu-backups/db_\$(date +\%Y\%m\%d).sql.gz") | crontab -
```
