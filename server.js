// =============================================================================
//  兽可梦 ShowCome — Node.js API 服务
//  /opt/showcomefu-api/server.js
//  依赖：express mysql2 bcryptjs jsonwebtoken cors helmet express-rate-limit dotenv
// =============================================================================
'use strict';

require('dotenv').config();
const express     = require('express');
const mysql       = require('mysql2/promise');
const bcrypt      = require('bcryptjs');
const jwt         = require('jsonwebtoken');
const cors        = require('cors');
const helmet      = require('helmet');
const rateLimit   = require('express-rate-limit');

const app  = express();
const PORT = process.env.PORT || 3000;

// ── Middleware ────────────────────────────────────────────────────────────────
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors({
  origin: process.env.FRONTEND_URL || '*',
  methods: ['GET','POST','PUT','PATCH','DELETE','OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
}));
app.use(express.json({ limit: '5mb' }));
app.use(express.urlencoded({ extended: false }));

// 信任 Nginx 代理的真实 IP
app.set('trust proxy', 1);

// ── 连接池 ────────────────────────────────────────────────────────────────────
const pool = mysql.createPool({
  host:             process.env.DB_HOST     || '127.0.0.1',
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

// ── 工具函数 ──────────────────────────────────────────────────────────────────
const asyncHandler = fn => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

async function log(user, action, detail, ip) {
  try {
    await pool.query(
      'INSERT INTO activity_log (user,action,detail,ip) VALUES (?,?,?,?)',
      [user, action, detail ? JSON.stringify(detail) : null, ip]
    );
  } catch { /* 日志失败不影响主流程 */ }
}

// ── 限流配置 ──────────────────────────────────────────────────────────────────
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 分钟
  max: 10,
  message: { error: '登录尝试次数过多，请 15 分钟后重试' },
  standardHeaders: true,
  legacyHeaders: false,
});

const apiLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 分钟
  max: 60,
  message: { error: '请求过于频繁，请稍后重试' },
});

app.use('/api/', apiLimiter);

// ── JWT 认证中间件 ─────────────────────────────────────────────────────────────
function authRequired(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith('Bearer ')) {
    return res.status(401).json({ error: '未提供认证令牌' });
  }
  const token = auth.split(' ')[1];
  try {
    req.user = jwt.verify(token, process.env.JWT_SECRET);
    next();
  } catch (e) {
    const msg = e.name === 'TokenExpiredError' ? 'Token 已过期，请重新登录' : 'Token 无效';
    return res.status(401).json({ error: msg });
  }
}

function adminOnly(req, res, next) {
  if (req.user?.role !== 'admin') {
    return res.status(403).json({ error: '需要管理员权限' });
  }
  next();
}

function notViewer(req, res, next) {
  if (req.user?.role === 'viewer') {
    return res.status(403).json({ error: '只读账号不允许此操作' });
  }
  next();
}

// ══════════════════════════════════════════════════════════════════════════════
//  路由：健康检查
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/health', asyncHandler(async (req, res) => {
  await pool.query('SELECT 1');
  res.json({ status: 'ok', time: new Date().toISOString(), env: process.env.NODE_ENV });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  路由：认证
// ══════════════════════════════════════════════════════════════════════════════
// POST /api/auth/login
app.post('/api/auth/login', authLimiter, asyncHandler(async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ error: '用户名和密码必填' });
  }

  const [rows] = await pool.query(
    'SELECT * FROM admins WHERE username=? AND active=1', [username]
  );
  const admin = rows[0];

  if (!admin || !(await bcrypt.compare(password, admin.password))) {
    await log(username, '登录失败', { reason: '账号或密码错误' }, req.ip);
    return res.status(401).json({ error: '账号或密码错误' });
  }

  await pool.query('UPDATE admins SET last_login=NOW(), last_ip=? WHERE id=?', [req.ip, admin.id]);
  await log(admin.username, '登录成功', null, req.ip);

  const payload = { id: admin.id, username: admin.username, role: admin.role };
  const token = jwt.sign(payload, process.env.JWT_SECRET, {
    expiresIn: process.env.JWT_EXPIRES || '12h',
  });

  res.json({
    token,
    user: { username: admin.username, role: admin.role, displayName: admin.display_name },
  });
}));

// POST /api/auth/logout
app.post('/api/auth/logout', authRequired, asyncHandler(async (req, res) => {
  await log(req.user.username, '登出', null, req.ip);
  res.json({ ok: true });
}));

// GET /api/auth/me
app.get('/api/auth/me', authRequired, asyncHandler(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT id,username,display_name,role,email,last_login FROM admins WHERE id=?',
    [req.user.id]
  );
  if (!rows[0]) return res.status(404).json({ error: '账号不存在' });
  res.json(rows[0]);
}));

// ══════════════════════════════════════════════════════════════════════════════
//  路由：CMS 内容（键值存储）
// ══════════════════════════════════════════════════════════════════════════════
// GET /api/cms/:key  — 公开（前台读取）
app.get('/api/cms/:key', asyncHandler(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT `value`, updated_at FROM cms_data WHERE `key`=?', [req.params.key]
  );
  if (!rows[0]) return res.status(404).json({ error: '内容不存在' });

  try {
    res.json(JSON.parse(rows[0].value));
  } catch {
    res.json({ raw: rows[0].value });
  }
}));

// GET /api/cms  — 列出所有键（需登录）
app.get('/api/cms', authRequired, asyncHandler(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT `key`, updated_at, updated_by FROM cms_data ORDER BY `key`'
  );
  res.json(rows);
}));

// PUT /api/cms/:key  — 写入（需登录，非只读）
app.put('/api/cms/:key', authRequired, notViewer, asyncHandler(async (req, res) => {
  const value = JSON.stringify(req.body);
  await pool.query(
    `INSERT INTO cms_data (\`key\`,\`value\`,updated_by)
     VALUES (?,?,?)
     ON DUPLICATE KEY UPDATE \`value\`=?, updated_by=?, updated_at=NOW()`,
    [req.params.key, value, req.user.username, value, req.user.username]
  );
  await log(req.user.username, `更新CMS内容`, { key: req.params.key }, req.ip);
  res.json({ ok: true, key: req.params.key });
}));

// DELETE /api/cms/:key  — 删除（仅管理员）
app.delete('/api/cms/:key', authRequired, adminOnly, asyncHandler(async (req, res) => {
  await pool.query('DELETE FROM cms_data WHERE `key`=?', [req.params.key]);
  await log(req.user.username, `删除CMS内容`, { key: req.params.key }, req.ip);
  res.json({ ok: true });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  路由：定制订单
// ══════════════════════════════════════════════════════════════════════════════
// POST /api/orders  — 前台提交
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

// GET /api/orders  — 后台查询
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

// PATCH /api/orders/:id/status
app.patch('/api/orders/:id/status', authRequired, notViewer, asyncHandler(async (req, res) => {
  const { status, adminNote } = req.body;
  const allowed = ['new','contacted','designing','making','done','cancelled'];
  if (!allowed.includes(status)) return res.status(400).json({ error: '无效状态' });

  await pool.query(
    'UPDATE orders SET status=?, admin_note=COALESCE(?,admin_note), updated_at=NOW() WHERE id=?',
    [status, adminNote || null, req.params.id]
  );
  await log(req.user.username, `更新订单状态`, { id: req.params.id, status }, req.ip);
  res.json({ ok: true });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  路由：媒体文件
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/media', authRequired, asyncHandler(async (req, res) => {
  const { type, q } = req.query;
  const conditions = [];
  const params = [];

  if (type)  { conditions.push('type=?'); params.push(type); }
  if (q)     { conditions.push('name LIKE ?'); params.push(`%${q}%`); }

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
  await pool.query('DELETE FROM media WHERE id=?', [req.params.id]);
  res.json({ ok: true });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  路由：管理员账号（仅超级管理员）
// ══════════════════════════════════════════════════════════════════════════════
app.get('/api/admins', authRequired, adminOnly, asyncHandler(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT id,username,display_name,role,email,active,last_login,created_at FROM admins'
  );
  res.json(rows);
}));

app.post('/api/admins', authRequired, adminOnly, asyncHandler(async (req, res) => {
  const { username, password, role, displayName, email } = req.body;
  if (!username || !password) return res.status(400).json({ error: '用户名密码必填' });
  if (password.length < 8) return res.status(400).json({ error: '密码至少 8 位' });

  const hash = await bcrypt.hash(password, 12);
  await pool.query(
    'INSERT INTO admins (username,password,display_name,role,email) VALUES (?,?,?,?,?)',
    [username, hash, displayName, role||'editor', email]
  );
  await log(req.user.username, '创建管理员', { username, role }, req.ip);
  res.json({ ok: true });
}));

app.patch('/api/admins/:id', authRequired, adminOnly, asyncHandler(async (req, res) => {
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
  await log(req.user.username, '更新管理员', { id: req.params.id }, req.ip);
  res.json({ ok: true });
}));

// ══════════════════════════════════════════════════════════════════════════════
//  路由：操作日志
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

  // MySQL 唯一键冲突
  if (err.code === 'ER_DUP_ENTRY') {
    return res.status(409).json({ error: '数据已存在，请检查唯一字段' });
  }

  res.status(500).json({
    error: process.env.NODE_ENV === 'production' ? '服务器内部错误' : err.message
  });
});

// ── 启动 ──────────────────────────────────────────────────────────────────────
app.listen(PORT, '127.0.0.1', () => {
  console.log(`[${new Date().toISOString()}] ShowCome API 启动于 127.0.0.1:${PORT}`);
  console.log(`  NODE_ENV: ${process.env.NODE_ENV}`);
  console.log(`  DB:       ${process.env.DB_HOST}/${process.env.DB_NAME}`);
});

module.exports = app;
