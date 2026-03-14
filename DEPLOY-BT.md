# 兽可梦 ShowCome · 宝塔面板部署手册

> **部署架构**：Gitee + Jenkins 自动化 CI/CD → 云服务器（安装了宝塔面板）
> **适用场景**：服务器已安装宝塔面板（BT Panel），希望通过宝塔的图形化界面管理 Nginx、MySQL 和网站进程，同时结合 Jenkins 实现代码的自动化打包、传输与更新。

---

## 架构概览

```text
开发者 → git push → Gitee 仓库
                        │
                    WebHook 触发
                        │
                        ▼
                    Jenkins 服务器
                    ├─ 检出代码
                    ├─ npm ci 工具安装及依赖（自动化）
                    ├─ 打包为制品 (tar.gz)
                    └─ SCP 上传 & SSH 远程执行部署脚本
                        │
                        ▼
                云服务器（宝塔面板）
                ├─ /www/wwwroot/showcome_studio/  ← 后端源码 + 前端静态文件 (存放目录)
                ├─ 宝塔 Node.js 版本管理器 (内置 PM2) ← 运行后端 API 服务 (端口: 3000)
                ├─ 宝塔 Nginx ← 静态文件托管 & 反向代理
                └─ 宝塔 MySQL 8.x ← 业务数据库
```

---

## 一、服务器端准备（宝塔面板基础环境）

### 1.1 安装宝塔基础软件

登录宝塔面板，进入「软件商店」，安装以下必须软件：
1. **Nginx** (建议 1.22 或以上版本)
2. **MySQL** 8.0 或以上版本（项目要求 MySQL 8+ 特性）
3. **Node.js 版本管理器** (并在其中安装 **Node v20.x**)
4. **PM2 管理器** (可选，通常 Node.js 版本管理器中已自带 PM2，或者在终端通过 `npm install -g pm2` 安装)

### 1.2 创建数据库

1. 进入宝塔左侧「数据库」->「添加数据库」。
2. **数据库名**：`showcomefu`
3. **用户名**：`showcome` (或自定义)
4. **密码**：(生成一个强密码)
5. **访问权限**：本地访问 (127.0.0.1)
6. 记录下这些信息，稍后在 Web 初始化向导(`/setup`)中使用。

### 1.3 规划目录与 SSH 密钥

我们将项目统一放置在 `/www/wwwroot/showcome_studio`，并在 `/www/wwwroot/showcome_backups` 保存自动备份。

为了让 Jenkins 可以无密码传输文件和执行命令，请将 Jenkins 服务器的 `~/.ssh/id_rsa.pub` (或对应的公钥) 添加到宝塔服务器的 `~/.ssh/authorized_keys` 中。

---

## 二、Jenkins 任务配置 (构建一个自由风格的软件项目)

相较于纯代码的 Pipeline，本教程将采用图形化界面的方式，利用 Jenkins 的经典 Web 界面和插件进行打包、传输与命令执行。

### 2.1 准备工作与插件安装
1. **安装插件**：在 Jenkins 管理面板的“插件管理”中搜索并安装 **`Publish Over SSH`** 插件。
2. **配置 SSH Server**：
   - 前往 `Manage Jenkins` -> `System` (系统管理 -> 系统配置)。
   - 找到 **Publish over SSH** 模块，点击 `Add` 新增一个 SSH Server。
   - **Name**: `BT-Server` (自定义名称)
   - **Hostname**: 宝塔服务器公网 IP
   - **Username**: 宝塔服务器 SSH 账号 (如 `root`)
   - **Remote Directory**: `/www/wwwroot/` (这是一个基础路径，上传文件时会基于此路径)
   - 点击 `Advanced` (高级)，勾选 `Use password authentication, or use a different key`，在 `Password` 中输入 SSH 密码（或填入秘钥信息）。
   - 点击 `Test Configuration`，显示 Success 说明连接成功。保存。

### 2.2 创建与配置任务
1. 在 Jenkins 首页点击 **“新建任务 (New Item)”**。
2. 输入任务名称，例如 `showcome_bt_deploy`，选择 **“构建一个自由风格的软件项目 (Freestyle project)”**，点击确定。
3. **参数化构建过程** (关键：设置端口变量)：
   - 勾选 **“参数化构建过程 (This project is parameterized)”**。
   - 点击 **“添加参数”** -> **“字符参数 (String Parameter)”**。
   - **名称 (Name)**: `SERVER_PORT`
   - **默认值 (Default Value)**: `3000`
   - **描述 (Description)**: 运行服务的端口号，可在部署前修改。
4. **源码管理**：填写项目的 Gitee / GitHub 仓库地址与权限凭证，指定分支（如 `*/main`）。
5. **构建触发器** (可选)：您可在此配置 WebHook 来实现 Push 自动触发。

### 2.3 构建 (Build Steps)
点击 **“增加构建步骤 (Add build step)”**，选择 **“执行 shell (Execute shell)”**。在命令框中填入以下用于安装依赖与打包制品的脚本：

```bash
echo "1. 安装 Node.js 依赖..."
# 确保 Jenkins 服务器上已安装 Node
npm ci --omit=dev --silent || npm install --omit=dev --silent

echo "2. 清理工作区的老旧压缩包..."
rm -f showcomefu-bt-*.tar.gz

echo "3. 打包为压缩文件..."
DEPLOY_ARCHIVE="showcomefu-bt-${BUILD_NUMBER}.tar.gz"

# 先将文件打包到 /tmp 目录，避免“文件在读取时发生变化”的 tar 报错
tar -czf "/tmp/$DEPLOY_ARCHIVE" \
    --exclude='node_modules' \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='installed.lock' \
    --exclude='*.tar.gz' \
    --exclude='.gitignore' \
    .

# 将打包好的文件移回工作区根目录以便后续 SSH 上传
mv "/tmp/$DEPLOY_ARCHIVE" ./

echo "打包完成: $DEPLOY_ARCHIVE"
```

*注意：不将 `node_modules` 排除进包内能大大加快上传速度。安装依赖会在下一步服务器端进行。如果您的宝塔服务器网速很慢，也可以选择不排除 `node_modules`，直接带着它全体打包上传（视您的机器硬件状况决定）。*

### 2.4 构建后操作 (Post-build Actions)
点击 **“增加构建后操作步骤 (Add post-build action)”**，选择 **“Send build artifacts over SSH”**。

在弹出面板的 **SSH Server** 下拉菜单选择之前配置的 `BT-Server`，然后填写 **Transfers** 信息：

#### Transfer Set 配置：
- **Source files**（源文件）: `showcomefu-bt-*.tar.gz` 
  *(说明：只上传刚才命名的 .tar.gz 文件)*
  
- **Remove prefix**（移除前缀）: 留空即可 
  *(无需移除前缀，因为就在根目录打包)*
  
- **Remote directory**（远程目录）: `showcome_studio/` 
  *(说明：结合前面系统配置的基础路径 `/www/wwwroot/`，文件会被上传到宝塔的 `/www/wwwroot/showcome_studio/` 目录)*
  
- **Exec command**（执行命令）:
  在此处填入上传后要在宝塔服务器上 **远程执行的命令**。为了方便迭代和版本追踪，我们已经将部署逻辑提取为了项目根目录下的 `start.sh` 脚本，它默认会随着上面的打包命令一起被上传。因此在 Jenkins 中的 Exec command 只需要写以下短短几行代码：提取脚本 -> 运行即可！

```bash
#!/bin/bash
set -e
# 将 Jenkins 的环境变量传导下去
export SERVER_PORT=$SERVER_PORT
APP_DIR="/www/wwwroot/showcome_studio"

cd $APP_DIR
# 1. 找到刚上传的最新压缩包
ARCHIVE_FILE=$(ls -t showcomefu-bt-*.tar.gz | head -1)

if [ -f "$ARCHIVE_FILE" ]; then
    echo "发现制品: $ARCHIVE_FILE"
    # 2. 先从包里独自抽出 start.sh 文件（因打包时使用的是 '.'，所以路径带有 ./）
    tar -xzf $ARCHIVE_FILE ./start.sh --overwrite || tar -xzf $ARCHIVE_FILE start.sh --overwrite
    
    # 3. 赋予执行权限并执行它（由 start.sh 接管后续的解压覆盖与重启任务）
    chmod +x start.sh
    bash start.sh
    
    # 4. 执行完毕后清理服务端的旧包（保留自己或干脆删除节省空间）
    # rm -f showcomefu-bt-*.tar.gz
else
    echo "错误：未找到最新压缩包！"
    exit 1
fi
```

*(说明：这样能让部署逻辑受代码变更影响。日后如果在需要修改安装 Node 的路径或方式，只用改您工程里的 `start.sh` 并且 push 上去即可生效，不用每次都去 Jenkins 界面内编辑 Exec command。)*

---

## 三、宝塔面板 Nginx 配置 (手动操作)

服务器上的前端静态文件和后端 API 是分开响应的，但它们挂载在同一个域名下。因此需要在宝塔中创建网站并手动修改配置文件：

### 3.1 创建站点
1. 进入宝塔左侧「网站」->「添加站点」。
2. **域名**：填写您的正式域名（如 `showcomefu.com` 和 `www.showcomefu.com`）。
3. **备注**：ShowCome 兽装定制
4. **根目录**：手动选择或填写为您刚才在流水线中配置的部署目录：`/www/wwwroot/showcome_studio`
5. **FTP / 数据库**：均选择「不创建」。(数据库刚才已单独创建)
6. **PHP 版本**：选择「纯静态」 (我们使用的是 Node.js，不需要 PHP)。

### 3.2 配置 SSL
1. 在刚刚立好的站点列表中，点击「未部署」的 SSL 选项。
2. 选择「Let's Encrypt」申请免费证书，或者在「其他证书」中填入您已有的证书和密钥。
3. 开启「强制 HTTPS」。

### 3.3 手动修改 Nginx 配置文件

这是**核心步骤**。点击该站点的「设置」->「配置文件」，将原有的部分默认配置替换或新增以下配置（注意替换或覆盖，不要出现语法冲突）：

```nginx
server
{
    listen 80;
    listen 443 ssl http2;
    server_name showcomefu.com www.showcomefu.com;
    
    # 网站根目录（静态文件位置）
    index index.html index.htm;
    root /www/wwwroot/showcome_studio;

    # SSL 配置 (宝塔会自动生成以下两行，保留您原本生成的即可，不要复制这部分)
    # ssl_certificate    /www/server/panel/vhost/cert/...
    # ssl_certificate_key /www/server/panel/vhost/cert/...

    # ==== 【ShowCome 专属 Nginx 路由转发规则】 ====

    # 1. 静态根目录访问 (前台)
    location / {
        try_files $uri $uri/ /index.html;
    }

    # 2. 系统首次初始化引导页
    location = /setup {
        try_files /setup.html =404;
    }

    # 3. 后台管理系统页
    location ^~ /admin {
        try_files $uri $uri/ /admin.html;
    }

    # 4. 后端 API 反向代理转发 (将请求转发给本地 PM2 监听的端口，需与 Jenkins 设置的 SERVER_PORT 一致)
    location /api/ {
        proxy_pass http://127.0.0.1:3000/api/; # <--- 若修改了端口，请同步修改此处的 3000
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # 允许 websocket (若未来有需)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 超时设置
        proxy_read_timeout 60s;
        proxy_connect_timeout 15s;
    }

    # 5. 静态资源缓存控制增强
    location ~* \.(js|css|png|jpg|jpeg|gif|webp|svg|ico|woff|woff2|ttf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # 6. 安全策略：禁止访问关键配置与隐藏文件
    location ~ \.(env|sh|sql|log|lock|git)$ { 
        deny all; 
        return 404; 
    }
    location ~ /\. { 
        deny all; 
        return 404; 
    }

    access_log  /www/wwwlogs/showcomefu.com.log;
    error_log  /www/wwwlogs/showcomefu.com.error.log;
}
```

修改完成后，点击「保存」。如果提示配置错误，请检查是否删除了必要的花括号或 `ssl_certificate` 行。如果没有报错，Nginx 会立刻生效。

---

## 四、Node 环境与 PM2 管理 (宝塔项目设置)

通过上面的部署，文件已经推送到 `/www/wwwroot/showcome_studio`。接下来我们需要让 Node 跑起来。

> 由于我们在 Jenkins 的步骤五中执行了命令，其实 PM2 已经被拉起了，但为了让宝塔面板可以图形化监控它，我们可以绑定一下：

1. 进入宝塔左侧「网站」 -> 点击上方 Tab 切换到 **「Node项目」**。
2. 点击 **「添加 Node 项目」**。
3. **项目目录**：`/www/wwwroot/showcome_studio/`
4. **启动文件**：`server.js`
5. **项目名称**：`showcome_api` (需与 Jenkins 脚本中 pm2 命名的名字一致)
6. **项目端口**：`3000`
7. **运行用户**：`www` 或者 `root` (如果宝塔权限不够导致写入日志被拒可换成 root 或改用户组)。
8. 勾选 **“开机自动启动”**，保存并启动。

启动后，您可以在此处实时查看 Node 项目的内存占用、CPU，或直接查看项目控制台日志。

---

## 五、首次部署初始化

当 Jenkins 初次部署完毕，并在宝塔中启动了 Nginx 和 PM2 (Node 项目) 之后。请在浏览器中访问初始化界面：

1. 在浏览器打开：`https://您的域名/setup`
2. 根据页面向导，开始配置：
   - 填入在宝塔中创建好的 **数据库信息** (`127.0.0.1`, 端口 `3306`, 库名, 账户, 密码)。
   - 设定您的管理初始账号和密码。
   - 配置 OSS 对象存储参数等。
3. 点击 **开始初始化**，系统会自动构建 `.env` 文件，执行完整建表步骤，并且创建 `installed.lock` 锁定系统。
4. 后台管理请前往：`https://您的域名/admin`。在日后的部署中，Jenkins 会通过 Webhook 自动更替文件、执行 Node 中的 `migrate.js` 迁移数据库。
