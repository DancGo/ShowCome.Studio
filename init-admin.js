#!/usr/bin/env node
// =============================================================================
//  init-admin.js — 初始化管理员 bcrypt 密码
//  用法：node init-admin.js [新密码]
//  如不传参数，将交互式询问
//  依赖：bcryptjs（npm install bcryptjs）
// =============================================================================
'use strict';

const bcrypt = require('bcryptjs');
const mysql  = require('mysql2/promise');
const fs     = require('fs');
const path   = require('path');
const readline = require('readline');

// 读取 .env
const envPath = path.join(__dirname, '.env');
if (!fs.existsSync(envPath)) {
  console.error('❌ 未找到 .env 文件，请先运行 setup.sh 或手动创建 .env');
  process.exit(1);
}

const env = {};
fs.readFileSync(envPath, 'utf8').split('\n').forEach(line => {
  const [k, ...v] = line.split('=');
  if (k && v.length) env[k.trim()] = v.join('=').trim();
});

async function prompt(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(resolve => rl.question(question, ans => { rl.close(); resolve(ans); }));
}

async function main() {
  let newPass = process.argv[2] || '';

  if (!newPass) {
    newPass = await prompt('请输入新的管理员密码（最少 8 位）: ');
  }

  if (newPass.length < 8) {
    console.error('❌ 密码至少 8 位');
    process.exit(1);
  }

  console.log('⏳ 生成 bcrypt 哈希（cost=12）...');
  const hash = await bcrypt.hash(newPass, 12);

  const pool = mysql.createPool({
    host:     env.DB_HOST || '127.0.0.1',
    port:     parseInt(env.DB_PORT || '3306'),
    database: env.DB_NAME,
    user:     env.DB_USER,
    password: env.DB_PASS,
    charset:  'utf8mb4',
  });

  try {
    const [result] = await pool.query(
      "UPDATE admins SET password=?, updated_at=NOW() WHERE username='admin'",
      [hash]
    );

    if (result.affectedRows === 0) {
      // 不存在则插入
      await pool.query(
        "INSERT INTO admins (username, password, display_name, role) VALUES ('admin', ?, '超级管理员', 'admin')",
        [hash]
      );
      console.log('✅ 管理员账号已创建，密码设置成功');
    } else {
      console.log('✅ admin 账号密码已更新');
    }

    // 记录操作日志
    await pool.query(
      "INSERT INTO activity_log (user, action, detail) VALUES ('system', '初始化管理员密码', ?)",
      [JSON.stringify({ username: 'admin', time: new Date().toISOString() })]
    );

  } finally {
    await pool.end();
  }

  console.log('\n🎉 完成！现在可以使用以下凭证登录后台：');
  console.log(`   用户名：admin`);
  console.log(`   密  码：${newPass}`);
  console.log('\n⚠️  请妥善保管密码，不要在聊天或邮件中明文传输。');
}

main().catch(err => {
  console.error('❌ 错误：', err.message);
  process.exit(1);
});
