// =============================================================================
//  兽可梦 ShowCome — Node.js API 服务（生产版）
//  特性：首次部署初始化向导 / 阿里云 OSS 集成 / 数据库迁移 / JWT 认证
// =============================================================================
'use strict';

const fs        = require('fs');
const path      = require('path');
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const rateLimit = require('express-rate-limit');

const app  = express();
let PORT = process.env.PORT || 3000;

const CONFIG_FILE  = path.join(__dirname, '.env');
const LOCK_FILE    = path.join(__dirname, 'installed.lock');
const SETUP_HTML   = path.join(__dirname, 'setup.html');

// ── 应用状态 ──
let isInstalled = fs.existsSync(LOCK_FILE);
let pool = null;

// ── 基础中间件（始终启用） ──
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors({
  origin: process.env.FRONTEND_URL || '*',
  methods: ['GET','POST','PUT','PATCH','DELETE','OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
}));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: false }));
app.set('trust proxy', 1);

// ── 工具函数 ──
const asyncHandler = fn => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function loadEnvFile() {
  if (!fs.existsSync(CONFIG_FILE)) return;
  const content = fs.readFileSync(CONFIG_FILE, 'utf8');
  content.split('\n').forEach(line => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) return;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx < 0) return;
    const key = trimmed.slice(0, eqIdx).trim();
    const val = trimmed.slice(eqIdx + 1).trim();
    if (!process.env[key]) process.env[key] = val;
  });
}

function initDbPool() {
  const mysql = require('mysql2/promise');
  pool = mysql.createPool({
    host:             process.env.DB_HOST || '127.0.0.1',
    port:             parseInt(process.env.DB_PORT || '3306'),
    database:         process.env.DB_NAME,
    user:             process.env.DB_USER,
    password:         process.env.DB_PASS,
    waitForConnections: true,
    connectionLimit:  15,
    queueLimit:       0,
    charset:          'utf8mb4',
    timezone:         '+08:00',
  });
  return pool;
}

function getOssClient() {
  const OSS = require('ali-oss');
  return new OSS({
    region:          process.env.OSS_REGION,
    accessKeyId:     process.env.OSS_ACCESS_KEY_ID,
    accessKeySecret: process.env.OSS_ACCESS_KEY_SECRET,
    bucket:          process.env.OSS_BUCKET,
    endpoint:        process.env.OSS_ENDPOINT || undefined,
    secure:          true,
  });
}

async function logAction(user, action, detail, ip) {
  if (!pool) return;
  try {
    await pool.query(
      'INSERT INTO activity_log (user,action,detail,ip) VALUES (?,?,?,?)',
      [user, action, detail ? JSON.stringify(detail) : null, ip]
    );
  } catch { /* 日志失败不影响主流程 */ }
}

// ── 静态文件服务（开发模式或不经过 Nginx 时使用） ──
app.use(express.static(__dirname, {
  index: 'index.html',
  extensions: ['html'],
  setHeaders: (res, filePath) => {
    if (filePath.endsWith('.html')) res.setHeader('Cache-Control', 'no-cache');
  }
}));

// ══════════════════════════════════════════════════════════════════════════════
//  安装检测中间件：未安装时仅放行 /api/setup/* 和静态资源
// ══════════════════════════════════════════════════════════════════════════════
app.use((req, res, next) => {
  if (isInstalled) return next();

  if (req.path.startsWith('/api/setup')) return next();

  if (req.path === '/setup' || req.path === '/setup.html') {
    return res.sendFile(SETUP_HTML);
  }

  if (req.path === '/admin' || req.path === '/admin.html') {
    return res.redirect('/setup');
  }

  if (req.path.startsWith('/api/')) {
    return res.status(503).json({ error: '系统尚未初始化，请先访问 /setup 完成配置' });
  }

  next();
});

// ══════════════════════════════════════════════════════════════════════════════
//  Setup API — 首次初始化
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/setup/status', (req, res) => {
  res.json({ installed: isInstalled });
});

app.post('/api/setup/test-db', asyncHandler(async (req, res) => {
  if (isInstalled) return res.status(403).json({ error: '系统已初始化' });

  const { host, port, name, user, password } = req.body;
  const mysql = require('mysql2/promise');

  let conn;
  try {
    conn = await mysql.createConnection({
      host, port: parseInt(port || '3306'), user, password,
      charset: 'utf8mb4', connectTimeout: 5000,
    });

    const [dbs] = await conn.query('SHOW DATABASES LIKE ?', [name]);
    const dbExists = dbs.length > 0;

    if (!dbExists) {
      await conn.query(`CREATE DATABASE \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`);
    }

    res.json({ ok: true, dbExists, message: dbExists ? '数据库连接成功' : '数据库连接成功，已自动创建数据库' });
  } catch (err) {
    res.status(400).json({ ok: false, error: `数据库连接失败: ${err.message}` });
  } finally {
    if (conn) await conn.end();
  }
}));

app.post('/api/setup/test-oss', asyncHandler(async (req, res) => {
  if (isInstalled) return res.status(403).json({ error: '系统已初始化' });

  const { region, bucket, accessKeyId, accessKeySecret, endpoint } = req.body;
  const OSS = require('ali-oss');

  try {
    const client = new OSS({
      region, accessKeyId, accessKeySecret, bucket,
      endpoint: endpoint || undefined, secure: true,
    });
    const result = await client.getBucketInfo(bucket);
    res.json({ ok: true, message: 'OSS 连接成功', location: result.bucket?.Location });
  } catch (err) {
    res.status(400).json({ ok: false, error: `OSS 连接失败: ${err.message}` });
  }
}));

app.post('/api/setup/init', asyncHandler(async (req, res) => {
  if (isInstalled) return res.status(403).json({ error: '系统已初始化，请勿重复操作' });

  const { db, admin, oss } = req.body;
  if (!db?.host || !db?.name || !db?.user || !db?.password) {
    return res.status(400).json({ error: '数据库配置不完整' });
  }
  if (!admin?.username || !admin?.password || admin.password.length < 8) {
    return res.status(400).json({ error: '管理员用户名必填，密码至少 8 位' });
  }

  const mysql  = require('mysql2/promise');
  const bcrypt = require('bcryptjs');
  const crypto = require('crypto');

  // 1) 生成 JWT 密钥
  const jwtSecret = crypto.randomBytes(48).toString('hex');

  // 2) 写入 .env
  const envContent = [
    `PORT=${PORT}`,
    `DB_HOST=${db.host}`,
    `DB_PORT=${db.port || 3306}`,
    `DB_NAME=${db.name}`,
    `DB_USER=${db.user}`,
    `DB_PASS=${db.password}`,
    `JWT_SECRET=${jwtSecret}`,
    `JWT_EXPIRES=12h`,
    `FRONTEND_URL=*`,
    `NODE_ENV=production`,
    '',
    `OSS_REGION=${oss?.region || ''}`,
    `OSS_BUCKET=${oss?.bucket || ''}`,
    `OSS_ACCESS_KEY_ID=${oss?.accessKeyId || ''}`,
    `OSS_ACCESS_KEY_SECRET=${oss?.accessKeySecret || ''}`,
    `OSS_ENDPOINT=${oss?.endpoint || ''}`,
    `OSS_CDN_DOMAIN=${oss?.cdnDomain || ''}`,
  ].join('\n');

  fs.writeFileSync(CONFIG_FILE, envContent, 'utf8');
  fs.chmodSync(CONFIG_FILE, '600');

  // 重新加载环境变量
  process.env.DB_HOST     = db.host;
  process.env.DB_PORT     = String(db.port || 3306);
  process.env.DB_NAME     = db.name;
  process.env.DB_USER     = db.user;
  process.env.DB_PASS     = db.password;
  process.env.JWT_SECRET  = jwtSecret;
  process.env.JWT_EXPIRES = '12h';
  process.env.NODE_ENV    = 'production';
  if (oss?.region)          process.env.OSS_REGION            = oss.region;
  if (oss?.bucket)          process.env.OSS_BUCKET            = oss.bucket;
  if (oss?.accessKeyId)     process.env.OSS_ACCESS_KEY_ID     = oss.accessKeyId;
  if (oss?.accessKeySecret) process.env.OSS_ACCESS_KEY_SECRET = oss.accessKeySecret;
  if (oss?.endpoint)        process.env.OSS_ENDPOINT          = oss.endpoint;
  if (oss?.cdnDomain)       process.env.OSS_CDN_DOMAIN        = oss.cdnDomain;

  // 3) 初始化数据库连接并运行迁移
  try {
    initDbPool();
    const { runMigrations } = require('./migrate');
    const migrationResult = await runMigrations(pool);

    // 4) 创建管理员账号
    const hash = await bcrypt.hash(admin.password, 12);
    await pool.query(
      `INSERT INTO admins (username, password, display_name, role)
       VALUES (?, ?, ?, 'admin')
       ON DUPLICATE KEY UPDATE password=?, display_name=?, updated_at=NOW()`,
      [admin.username, hash, admin.displayName || '超级管理员', hash, admin.displayName || '超级管理员']
    );

    // 5) 写入锁文件
    fs.writeFileSync(LOCK_FILE, JSON.stringify({
      installedAt: new Date().toISOString(),
      version: '1.1.0',
      migrationsApplied: migrationResult.total,
    }), 'utf8');

    isInstalled = true;

    await logAction('system', '系统初始化完成', {
      admin: admin.username,
      dbHost: db.host,
      ossEnabled: !!(oss?.bucket),
    }, req.ip);

    res.json({
      ok: true,
      message: '系统初始化成功！请刷新页面后登录管理后台。',
      migrations: migrationResult,
    });

  } catch (err) {
    // 初始化失败，清理锁文件
    if (fs.existsSync(LOCK_FILE)) fs.unlinkSync(LOCK_FILE);
    isInstalled = false;
    throw err;
  }
}));

// ══════════════════════════════════════════════════════════════════════════════
//  以下路由仅在 isInstalled=true 时生效（由上方中间件守护）
// ══════════════════════════════════════════════════════════════════════════════

// ── 限流配置 ──
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  message: { error: '登录尝试次数过多，请 15 分钟后重试' },
  standardHeaders: true,
  legacyHeaders: false,
});

const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 60,
  message: { error: '请求过于频繁，请稍后重试' },
});

app.use('/api/', apiLimiter);

// ── JWT 认证中间件 ──
function authRequired(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: '未提供认证令牌' });
  }
  try {
    const jwt = require('jsonwebtoken');
    req.user = jwt.verify(auth.split(' ')[1], process.env.JWT_SECRET);
    next();
  } catch (e) {
    const msg = e.name === 'TokenExpiredError' ? 'Token 已过期，请重新登录' : 'Token 无效';
    return res.status(401).json({ error: msg });
  }
}

function adminOnly(req, res, next) {
  if (req.user?.role !== 'admin') return res.status(403).json({ error: '需要管理员权限' });
  next();
}

function notViewer(req, res, next) {
  if (req.user?.role === 'viewer') return res.status(403).json({ error: '只读账号不允许此操作' });
  next();
}

// ══════════════════════════════════════════════════════════════════════════════
//  健康检查 & 版本信息
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/health', asyncHandler(async (req, res) => {
  if (!pool) return res.json({ status: 'not_installed' });
  await pool.query('SELECT 1');
  res.json({ status: 'ok', time: new Date().toISOString(), env: process.env.NODE_ENV });
}));

app.get('/api/version', (req, res) => {
  const lockData = fs.existsSync(LOCK_FILE) ? JSON.parse(fs.readFileSync(LOCK_FILE, 'utf8')) : {};
  res.json({ version: '1.1.0', installed: isInstalled, ...lockData });
});

// ══════════════════════════════════════════════════════════════════════════════
//  认证
// ══════════════════════════════════════════════════════════════════════════════
app.post('/api/auth/login', authLimiter, asyncHandler(async (req, res) => {
  const bcrypt = require('bcryptjs');
  const jwt    = require('jsonwebtoken');
  const { username, password } = req.body;
  if (!username || !password) return res.status(400).json({ error: '用户名和密码必填' });

  const [rows] = await pool.query('SELECT * FROM admins WHERE username=? AND active=1', [username]);
  const admin = rows[0];

  if (!admin || !(await bcrypt.compare(password, admin.password))) {
    await logAction(username, '登录失败', { reason: '账号或密码错误' }, req.ip);
    return res.status(401).json({ error: '账号或密码错误' });
  }

  await pool.query('UPDATE admins SET last_login=NOW(), last_ip=? WHERE id=?', [req.ip, admin.id]);
  await logAction(admin.username, '登录成功', null, req.ip);

  const payload = { id: admin.id, username: admin.username, role: admin.role };
  const token = jwt.sign(payload, process.env.JWT_SECRET, { expiresIn: process.env.JWT_EXPIRES || '12h' });

  res.json({
    token,
    user: { username: admin.username, role: admin.role, displayName: admin.display_name },
  });
}));

app.post('/api/auth/logout', authRequired, asyncHandler(async (req, res) => {
  await logAction(req.user.username, '登出', null, req.ip);
  res.json({ ok: true });
}));

app.get('/api/auth/me', authRequired, asyncHandler(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT id,username,display_name,role,email,last_login FROM admins WHERE id=?',
    [req.user.id]
  );
  if (!rows[0]) return res.status(404).json({ error: '账号不存在' });
  res.json(rows[0]);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  CMS 内容
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/cms/:key', asyncHandler(async (req, res) => {
  const [rows] = await pool.query('SELECT `value`, updated_at FROM cms_data WHERE `key`=?', [req.params.key]);
  if (!rows[0]) return res.status(404).json({ error: '内容不存在' });
  try { res.json(JSON.parse(rows[0].value)); }
  catch { res.json({ raw: rows[0].value }); }
}));

app.get('/api/cms', authRequired, asyncHandler(async (req, res) => {
  const [rows] = await pool.query('SELECT `key`, updated_at, updated_by FROM cms_data ORDER BY `key`');
  res.json(rows);
}));

app.put('/api/cms/:key', authRequired, notViewer, asyncHandler(async (req, res) => {
  const value = JSON.stringify(req.body);
  await pool.query(
    `INSERT INTO cms_data (\`key\`,\`value\`,updated_by) VALUES (?,?,?)
     ON DUPLICATE KEY UPDATE \`value\`=?, updated_by=?, updated_at=NOW()`,
    [req.params.key, value, req.user.username, value, req.user.username]
  );
  await logAction(req.user.username, '更新CMS内容', { key: req.params.key }, req.ip);
  res.json({ ok: true, key: req.params.key });
}));

app.delete('/api/cms/:key', authRequired, adminOnly, asyncHandler(async (req, res) => {
  await pool.query('DELETE FROM cms_data WHERE `key`=?', [req.params.key]);
  await logAction(req.user.username, '删除CMS内容', { key: req.params.key }, req.ip);
  res.json({ ok: true });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  定制订单
// ══════════════════════════════════════════════════════════════════════════════
app.post('/api/orders', asyncHandler(async (req, res) => {
  const { nickname, contact, type, budget, species, colorScheme, refUrl, note } = req.body;
  if (!contact) return res.status(400).json({ error: '联系方式必填' });

  const id = 'O' + Date.now() + Math.floor(Math.random() * 1000);
  await pool.query(
    `INSERT INTO orders (id,nickname,contact,type,budget,species,color_scheme,ref_url,note,source_ip)
     VALUES (?,?,?,?,?,?,?,?,?,?)`,
    [id, nickname?.slice(0,100), contact.slice(0,200), type?.slice(0,100),
     budget?.slice(0,50), species?.slice(0,100), colorScheme?.slice(0,200),
     refUrl?.slice(0,500), note?.slice(0,2000), req.ip]
  );
  res.json({ ok: true, id });
}));

app.get('/api/orders', authRequired, asyncHandler(async (req, res) => {
  const { status, page = 1, limit = 50 } = req.query;
  const offset = (parseInt(page) - 1) * parseInt(limit);
  const conditions = [];
  const params = [];

  if (status) { conditions.push('status=?'); params.push(status); }

  const where = conditions.length ? 'WHERE ' + conditions.join(' AND ') : '';
  const [[{ total }]] = await pool.query(`SELECT COUNT(*) AS total FROM orders ${where}`, params);
  const [rows] = await pool.query(
    `SELECT * FROM orders ${where} ORDER BY created_at DESC LIMIT ? OFFSET ?`,
    [...params, parseInt(limit), offset]
  );
  res.json({ total, page: parseInt(page), data: rows });
}));

app.patch('/api/orders/:id/status', authRequired, notViewer, asyncHandler(async (req, res) => {
  const { status, adminNote } = req.body;
  const allowed = ['new','contacted','designing','making','done','cancelled'];
  if (!allowed.includes(status)) return res.status(400).json({ error: '无效状态' });

  await pool.query(
    'UPDATE orders SET status=?, admin_note=COALESCE(?,admin_note), updated_at=NOW() WHERE id=?',
    [status, adminNote || null, req.params.id]
  );
  await logAction(req.user.username, '更新订单状态', { id: req.params.id, status }, req.ip);
  res.json({ ok: true });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  媒体文件 & OSS 上传
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/media', authRequired, asyncHandler(async (req, res) => {
  const { type, q } = req.query;
  const conditions = [];
  const params = [];
  if (type) { conditions.push('type=?'); params.push(type); }
  if (q)    { conditions.push('name LIKE ?'); params.push(`%${q}%`); }
  const where = conditions.length ? 'WHERE ' + conditions.join(' AND ') : '';
  const [rows] = await pool.query(`SELECT * FROM media ${where} ORDER BY created_at DESC`, params);
  res.json(rows);
}));

app.post('/api/media', authRequired, notViewer, asyncHandler(async (req, res) => {
  const { name, type, url, thumbUrl, sizeBytes, mimeType, altText, tags, storage, storageKey } = req.body;
  if (!name || !url) return res.status(400).json({ error: 'name 和 url 必填' });

  const [r] = await pool.query(
    `INSERT INTO media (name,type,url,thumb_url,size_bytes,mime_type,alt_text,tags,storage,storage_key,uploaded_by)
     VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
    [name, type||'image', url, thumbUrl, sizeBytes, mimeType, altText, tags,
     storage||'url', storageKey, req.user.username]
  );
  res.json({ ok: true, id: r.insertId });
}));

app.delete('/api/media/:id', authRequired, notViewer, asyncHandler(async (req, res) => {
  const [rows] = await pool.query('SELECT storage_key, storage FROM media WHERE id=?', [req.params.id]);
  const item = rows[0];

  if (item?.storage === 'oss' && item?.storage_key && process.env.OSS_BUCKET) {
    try {
      const client = getOssClient();
      await client.delete(item.storage_key);
    } catch { /* OSS 删除失败不阻塞 */ }
  }

  await pool.query('DELETE FROM media WHERE id=?', [req.params.id]);
  res.json({ ok: true });
}));

// OSS 签名上传（前端直传 OSS）
app.post('/api/oss/sign', authRequired, notViewer, asyncHandler(async (req, res) => {
  if (!process.env.OSS_BUCKET) {
    return res.status(400).json({ error: 'OSS 未配置' });
  }

  const { filename, contentType } = req.body;
  const ext = path.extname(filename || '.jpg');
  const date = new Date();
  const dir = `media/${date.getFullYear()}/${String(date.getMonth()+1).padStart(2,'0')}`;
  const key = `${dir}/${Date.now()}_${Math.random().toString(36).slice(2,8)}${ext}`;

  const client = getOssClient();
  const policy = {
    expiration: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
    conditions: [
      { bucket: process.env.OSS_BUCKET },
      ['content-length-range', 0, 50 * 1024 * 1024],
      ['starts-with', '$key', dir],
    ],
  };
  const formData = client.calculatePostSignature(policy);

  const cdnDomain = process.env.OSS_CDN_DOMAIN;
  const host = cdnDomain
    ? `https://${cdnDomain}`
    : `https://${process.env.OSS_BUCKET}.${process.env.OSS_REGION}.aliyuncs.com`;

  res.json({
    host,
    key,
    policy: formData.policy,
    signature: formData.Signature,
    OSSAccessKeyId: process.env.OSS_ACCESS_KEY_ID,
    url: `${host}/${key}`,
  });
}));

// OSS 配置检查
app.get('/api/oss/status', authRequired, (req, res) => {
  res.json({
    enabled: !!(process.env.OSS_BUCKET && process.env.OSS_ACCESS_KEY_ID),
    region: process.env.OSS_REGION || '',
    bucket: process.env.OSS_BUCKET || '',
    cdnDomain: process.env.OSS_CDN_DOMAIN || '',
  });
});

// ══════════════════════════════════════════════════════════════════════════════
//  管理员账号（仅超级管理员）
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/admins', authRequired, adminOnly, asyncHandler(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT id,username,display_name,role,email,active,last_login,created_at FROM admins'
  );
  res.json(rows);
}));

app.post('/api/admins', authRequired, adminOnly, asyncHandler(async (req, res) => {
  const bcrypt = require('bcryptjs');
  const { username, password, role, displayName, email } = req.body;
  if (!username || !password) return res.status(400).json({ error: '用户名密码必填' });
  if (password.length < 8) return res.status(400).json({ error: '密码至少 8 位' });

  const hash = await bcrypt.hash(password, 12);
  await pool.query(
    'INSERT INTO admins (username,password,display_name,role,email) VALUES (?,?,?,?,?)',
    [username, hash, displayName, role||'editor', email]
  );
  await logAction(req.user.username, '创建管理员', { username, role }, req.ip);
  res.json({ ok: true });
}));

app.patch('/api/admins/:id', authRequired, adminOnly, asyncHandler(async (req, res) => {
  const bcrypt = require('bcryptjs');
  const { password, role, displayName, email, active } = req.body;
  const updates = [];
  const params = [];

  if (password)     { updates.push('password=?');     params.push(await bcrypt.hash(password, 12)); }
  if (role)         { updates.push('role=?');         params.push(role); }
  if (displayName)  { updates.push('display_name=?'); params.push(displayName); }
  if (email !== undefined) { updates.push('email=?'); params.push(email); }
  if (active !== undefined) { updates.push('active=?'); params.push(active ? 1 : 0); }

  if (!updates.length) return res.status(400).json({ error: '没有要更新的字段' });

  updates.push('updated_at=NOW()');
  params.push(req.params.id);
  await pool.query(`UPDATE admins SET ${updates.join(',')} WHERE id=?`, params);
  await logAction(req.user.username, '更新管理员', { id: req.params.id }, req.ip);
  res.json({ ok: true });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  数据库迁移管理（管理员 API）
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/migrations', authRequired, adminOnly, asyncHandler(async (req, res) => {
  const { getAppliedMigrations, getPendingMigrations, ensureMigrationsTable } = require('./migrate');
  await ensureMigrationsTable(pool);
  const applied = await getAppliedMigrations(pool);
  const pending = getPendingMigrations(applied);

  res.json({
    applied: Array.from(applied.values()),
    pending: pending.map(m => ({ version: m.version, name: m.name })),
  });
}));

app.post('/api/migrations/run', authRequired, adminOnly, asyncHandler(async (req, res) => {
  const { runMigrations } = require('./migrate');
  const result = await runMigrations(pool);
  await logAction(req.user.username, '执行数据库迁移', result, req.ip);
  res.json({ ok: true, ...result });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  操作日志
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/logs', authRequired, asyncHandler(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT id,user,action,detail,ip,created_at FROM activity_log ORDER BY created_at DESC LIMIT 100'
  );
  res.json(rows);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  全局错误处理
// ══════════════════════════════════════════════════════════════════════════════
app.use((req, res) => {
  res.status(404).json({ error: '接口不存在' });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error(`[${new Date().toISOString()}] ERROR`, err.message);
  if (err.code === 'ER_DUP_ENTRY') {
    return res.status(409).json({ error: '数据已存在，请检查唯一字段' });
  }
  res.status(500).json({
    error: process.env.NODE_ENV === 'production' ? '服务器内部错误' : err.message
  });
});

// ── 启动 ──
function boot() {
  loadEnvFile();

  // 必须在 loadEnvFile 加载完 .env 之后重新获取一次端口号
  PORT = process.env.PORT || PORT;

  if (isInstalled && process.env.DB_NAME) {
    initDbPool();
    console.log(`  DB: ${process.env.DB_HOST}/${process.env.DB_NAME}`);
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[${new Date().toISOString()}] ShowCome API 启动于 0.0.0.0:${PORT}`);
    console.log(`  已安装: ${isInstalled}`);
    console.log(`  环境: ${process.env.NODE_ENV || 'development'}`);
    if (!isInstalled) {
      console.log(`  ⚡ 请访问 http://localhost:${PORT}/setup 完成首次初始化`);
    }
  });
}

boot();
module.exports = app;
