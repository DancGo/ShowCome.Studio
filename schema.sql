-- =============================================================================
--  兽可梦 ShowCome — 数据库初始化 SQL
--  适用：MySQL 8.0+ / MariaDB 10.6+
--  执行：mysql -u showcome -p showcomefu < schema.sql
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;
SET time_zone = '+08:00';

-- -----------------------------------------------------------------------------
-- 1. CMS 内容键值表（灵活存储所有 JSON 配置）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `cms_data` (
  `key`        VARCHAR(100)  NOT NULL COMMENT 'CMS数据键，如 works/products/site',
  `value`      LONGTEXT      NOT NULL COMMENT 'JSON 格式的内容数据',
  `updated_at` DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                             ON UPDATE CURRENT_TIMESTAMP COMMENT '最后更新时间',
  `updated_by` VARCHAR(50)   DEFAULT 'admin' COMMENT '最后操作人',
  PRIMARY KEY (`key`),
  FULLTEXT KEY `ft_value` (`value`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='CMS 内容键值存储';

-- -----------------------------------------------------------------------------
-- 2. 管理员账号表
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `admins` (
  `id`           INT           NOT NULL AUTO_INCREMENT,
  `username`     VARCHAR(50)   NOT NULL COMMENT '登录用户名',
  `password`     VARCHAR(255)  NOT NULL COMMENT 'bcrypt 哈希密码',
  `display_name` VARCHAR(100)  DEFAULT NULL COMMENT '显示名称',
  `role`         ENUM('admin','editor','viewer') NOT NULL DEFAULT 'editor',
  `email`        VARCHAR(200)  DEFAULT NULL,
  `active`       TINYINT(1)    NOT NULL DEFAULT 1 COMMENT '1=启用 0=禁用',
  `last_login`   DATETIME      DEFAULT NULL,
  `last_ip`      VARCHAR(50)   DEFAULT NULL,
  `created_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_username` (`username`),
  KEY `idx_active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='管理员账号（密码为 bcrypt 哈希）';

-- 默认管理员（密码占位，需通过 init-admin.sh 设置实际哈希）
-- 密码原文: showcome2024（仅用于初始化，首次登录后立即修改）
INSERT IGNORE INTO `admins` (`username`, `password`, `display_name`, `role`)
VALUES ('admin', 'BCRYPT_PLACEHOLDER', '超级管理员', 'admin');

-- -----------------------------------------------------------------------------
-- 3. 定制订单表
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `orders` (
  `id`           VARCHAR(30)   NOT NULL COMMENT '订单ID，格式 O{timestamp}',
  `nickname`     VARCHAR(100)  DEFAULT NULL COMMENT '称呼/昵称',
  `contact`      VARCHAR(200)  NOT NULL COMMENT '联系方式（微信/邮箱等）',
  `type`         VARCHAR(100)  DEFAULT NULL COMMENT '定制类型：全身/部分套装等',
  `budget`       VARCHAR(50)   DEFAULT NULL COMMENT '预算区间',
  `species`      VARCHAR(100)  DEFAULT NULL COMMENT '兽种/角色',
  `color_scheme` VARCHAR(200)  DEFAULT NULL COMMENT '配色方案',
  `ref_url`      VARCHAR(500)  DEFAULT NULL COMMENT '参考图链接',
  `note`         TEXT          DEFAULT NULL COMMENT '备注说明',
  `status`       ENUM('new','contacted','designing','making','done','cancelled')
                               NOT NULL DEFAULT 'new' COMMENT '订单状态',
  `admin_note`   TEXT          DEFAULT NULL COMMENT '内部备注（仅管理员可见）',
  `source_ip`    VARCHAR(50)   DEFAULT NULL COMMENT '提交来源 IP',
  `created_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_status` (`status`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='定制订单记录';

-- -----------------------------------------------------------------------------
-- 4. 媒体文件表
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `media` (
  `id`           BIGINT        NOT NULL AUTO_INCREMENT,
  `name`         VARCHAR(255)  NOT NULL COMMENT '文件名',
  `type`         ENUM('image','video','audio','model','document','other')
                               NOT NULL DEFAULT 'image',
  `url`          VARCHAR(1000) NOT NULL COMMENT '访问 URL（CDN/OSS）',
  `thumb_url`    VARCHAR(1000) DEFAULT NULL COMMENT '缩略图 URL',
  `size_bytes`   BIGINT        DEFAULT NULL COMMENT '文件大小（字节）',
  `mime_type`    VARCHAR(100)  DEFAULT NULL COMMENT 'MIME 类型',
  `width`        INT           DEFAULT NULL COMMENT '图片宽度（像素）',
  `height`       INT           DEFAULT NULL COMMENT '图片高度（像素）',
  `duration`     FLOAT         DEFAULT NULL COMMENT '音视频时长（秒）',
  `tags`         VARCHAR(500)  DEFAULT NULL COMMENT '标签，逗号分隔',
  `alt_text`     VARCHAR(300)  DEFAULT NULL COMMENT '图片 alt 文本（SEO）',
  `uploaded_by`  VARCHAR(50)   DEFAULT NULL COMMENT '上传者用户名',
  `storage`      ENUM('local','oss','cos','r2','s3','url')
                               DEFAULT 'url' COMMENT '存储方式',
  `storage_key`  VARCHAR(500)  DEFAULT NULL COMMENT 'OSS/S3 对象键',
  `created_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_type` (`type`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='媒体文件库';

-- -----------------------------------------------------------------------------
-- 5. 操作日志表
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `activity_log` (
  `id`         BIGINT       NOT NULL AUTO_INCREMENT,
  `user`       VARCHAR(50)  DEFAULT NULL COMMENT '操作用户名',
  `action`     VARCHAR(200) NOT NULL COMMENT '操作描述',
  `detail`     TEXT         DEFAULT NULL COMMENT '详细信息（JSON）',
  `ip`         VARCHAR(50)  DEFAULT NULL COMMENT '来源 IP',
  `user_agent` VARCHAR(500) DEFAULT NULL COMMENT '浏览器 UA',
  `created_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_user`    (`user`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='管理操作日志';

-- 自动清理 90 天前的日志（MySQL 8.0 Event）
CREATE EVENT IF NOT EXISTS `cleanup_activity_log`
  ON SCHEDULE EVERY 1 DAY
  STARTS CURRENT_TIMESTAMP
  DO DELETE FROM `activity_log` WHERE `created_at` < NOW() - INTERVAL 90 DAY;

-- -----------------------------------------------------------------------------
-- 6. 会话 Token 黑名单（登出时加入）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `token_blacklist` (
  `jti`        VARCHAR(100) NOT NULL COMMENT 'JWT ID',
  `expires_at` DATETIME     NOT NULL COMMENT 'Token 过期时间',
  PRIMARY KEY (`jti`),
  KEY `idx_expires` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='JWT Token 注销黑名单';

-- 自动清理过期 token
CREATE EVENT IF NOT EXISTS `cleanup_token_blacklist`
  ON SCHEDULE EVERY 1 HOUR
  STARTS CURRENT_TIMESTAMP
  DO DELETE FROM `token_blacklist` WHERE `expires_at` < NOW();

-- -----------------------------------------------------------------------------
-- 7. 初始化 CMS 默认内容（可选，从 localStorage 导入的初始数据）
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO `cms_data` (`key`, `value`, `updated_by`) VALUES
('site', JSON_OBJECT(
  'name',        '兽可梦 ShowCome',
  'tagline',     '让每一只兽娘都独一无二',
  'logo',        '🦊',
  'icp',         '',
  'online',      TRUE,
  'shopEnabled', TRUE,
  'customEnabled', TRUE
), 'system'),

('theme', JSON_OBJECT(
  'primary',   '#0a0a0f',
  'secondary', '#111118',
  'accent',    '#7c3aed',
  'accent2',   '#06d6a0',
  'accent3',   '#f72585',
  'text',      '#e8e8f0',
  'noiseEnabled', TRUE,
  'glowEnabled',  TRUE
), 'system'),

('seo', JSON_OBJECT(
  'title',       '兽可梦 ShowCome | 专业兽装定制工作室',
  'description', '专业毛绒兽装定制工作室，提供头装、全身套装、局部配件定制服务',
  'keywords',    '兽装定制,毛绒服装,兽化,fursuit,兽装工作室',
  'ogImage',     ''
), 'system');

SET FOREIGN_KEY_CHECKS = 1;

-- =============================================================================
-- 验证：执行后检查
-- =============================================================================
-- SELECT table_name, table_rows, table_comment
-- FROM information_schema.tables
-- WHERE table_schema = 'showcomefu'
-- ORDER BY table_name;
