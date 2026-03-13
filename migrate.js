#!/usr/bin/env node
// =============================================================================
//  migrate.js — 数据库迁移运行器
//  用法：
//    node migrate.js              # 执行所有未应用的迁移
//    node migrate.js --status     # 查看迁移状态
//    node migrate.js --target 003 # 迁移到指定版本
//  支持外部传入连接配置（供 setup 初始化调用）
// =============================================================================
'use strict';

const fs   = require('fs');
const path = require('path');

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');

async function ensureMigrationsTable(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS migrations_history (
      version    VARCHAR(100) NOT NULL,
      name       VARCHAR(255) NOT NULL,
      applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (version)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  `);
}

async function getAppliedMigrations(pool) {
  const [rows] = await pool.query(
    'SELECT version, name, applied_at FROM migrations_history ORDER BY version'
  );
  return new Map(rows.map(r => [r.version, r]));
}

function getPendingMigrations(appliedMap) {
  const files = fs.readdirSync(MIGRATIONS_DIR)
    .filter(f => /^\d{3}_.*\.sql$/.test(f))
    .sort();

  return files
    .map(f => ({ version: f.slice(0, 3), name: f, file: path.join(MIGRATIONS_DIR, f) }))
    .filter(m => !appliedMap.has(m.version));
}

function splitStatements(sql) {
  return sql
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split(/;\s*\n/)
    .map(s => s.trim())
    .filter(s => s && !s.startsWith('--'));
}

async function runMigrations(pool, targetVersion) {
  await ensureMigrationsTable(pool);
  const applied = await getAppliedMigrations(pool);
  let pending = getPendingMigrations(applied);

  if (targetVersion) {
    pending = pending.filter(m => m.version <= targetVersion);
  }

  if (!pending.length) {
    console.log('✅ 数据库已是最新版本，无需迁移');
    return { applied: 0, total: applied.size };
  }

  console.log(`📦 发现 ${pending.length} 个待执行迁移：`);
  let count = 0;

  for (const migration of pending) {
    console.log(`  ⏳ 执行 ${migration.name} ...`);
    const sql = fs.readFileSync(migration.file, 'utf8');
    const statements = splitStatements(sql);

    const conn = await pool.getConnection();
    try {
      await conn.beginTransaction();
      for (const stmt of statements) {
        await conn.query(stmt);
      }
      await conn.query(
        'INSERT INTO migrations_history (version, name) VALUES (?, ?)',
        [migration.version, migration.name]
      );
      await conn.commit();
      console.log(`  ✅ ${migration.name} 完成`);
      count++;
    } catch (err) {
      await conn.rollback();
      console.error(`  ❌ ${migration.name} 失败: ${err.message}`);
      throw err;
    } finally {
      conn.release();
    }
  }

  console.log(`\n🎉 成功执行 ${count} 个迁移`);
  return { applied: count, total: applied.size + count };
}

async function showStatus(pool) {
  await ensureMigrationsTable(pool);
  const applied = await getAppliedMigrations(pool);

  const files = fs.readdirSync(MIGRATIONS_DIR)
    .filter(f => /^\d{3}_.*\.sql$/.test(f))
    .sort();

  console.log('\n📋 数据库迁移状态：');
  console.log('─'.repeat(60));

  for (const f of files) {
    const version = f.slice(0, 3);
    const info = applied.get(version);
    const status = info ? `✅ 已应用 (${info.applied_at.toISOString().slice(0, 19)})` : '⏳ 待执行';
    console.log(`  ${version} | ${status} | ${f}`);
  }

  console.log('─'.repeat(60));
  console.log(`  共 ${files.length} 个迁移，已应用 ${applied.size} 个\n`);
}

// 供外部模块调用
module.exports = { runMigrations, showStatus, ensureMigrationsTable, getAppliedMigrations, getPendingMigrations };

// CLI 入口
if (require.main === module) {
  (async () => {
    require('dotenv').config();
    const mysql = require('mysql2/promise');

    const pool = mysql.createPool({
      host:     process.env.DB_HOST || '127.0.0.1',
      port:     parseInt(process.env.DB_PORT || '3306'),
      database: process.env.DB_NAME,
      user:     process.env.DB_USER,
      password: process.env.DB_PASS,
      charset:  'utf8mb4',
    });

    try {
      const args = process.argv.slice(2);

      if (args.includes('--status')) {
        await showStatus(pool);
      } else {
        const targetIdx = args.indexOf('--target');
        const target = targetIdx >= 0 ? args[targetIdx + 1] : null;
        await runMigrations(pool, target);
      }
    } catch (err) {
      console.error('❌ 迁移失败:', err.message);
      process.exit(1);
    } finally {
      await pool.end();
    }
  })();
}
