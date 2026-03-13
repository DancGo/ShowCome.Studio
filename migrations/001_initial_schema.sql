-- =============================================================================
--  Migration 001: 初始表结构
--  创建核心业务表（从 schema.sql 提取）
-- =============================================================================

CREATE TABLE IF NOT EXISTS `cms_data` (
  `key`        VARCHAR(100)  NOT NULL COMMENT 'CMS数据键，如 works/products/site',
  `value`      LONGTEXT      NOT NULL COMMENT 'JSON 格式的内容数据',
  `updated_at` DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                             ON UPDATE CURRENT_TIMESTAMP,
  `updated_by` VARCHAR(50)   DEFAULT 'admin',
  PRIMARY KEY (`key`),
  FULLTEXT KEY `ft_value` (`value`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `admins` (
  `id`           INT           NOT NULL AUTO_INCREMENT,
  `username`     VARCHAR(50)   NOT NULL,
  `password`     VARCHAR(255)  NOT NULL COMMENT 'bcrypt hash',
  `display_name` VARCHAR(100)  DEFAULT NULL,
  `role`         ENUM('admin','editor','viewer') NOT NULL DEFAULT 'editor',
  `email`        VARCHAR(200)  DEFAULT NULL,
  `active`       TINYINT(1)    NOT NULL DEFAULT 1,
  `last_login`   DATETIME      DEFAULT NULL,
  `last_ip`      VARCHAR(50)   DEFAULT NULL,
  `created_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_username` (`username`),
  KEY `idx_active` (`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `orders` (
  `id`           VARCHAR(30)   NOT NULL,
  `nickname`     VARCHAR(100)  DEFAULT NULL,
  `contact`      VARCHAR(200)  NOT NULL,
  `type`         VARCHAR(100)  DEFAULT NULL,
  `budget`       VARCHAR(50)   DEFAULT NULL,
  `species`      VARCHAR(100)  DEFAULT NULL,
  `color_scheme` VARCHAR(200)  DEFAULT NULL,
  `ref_url`      VARCHAR(500)  DEFAULT NULL,
  `note`         TEXT          DEFAULT NULL,
  `status`       ENUM('new','contacted','designing','making','done','cancelled')
                               NOT NULL DEFAULT 'new',
  `admin_note`   TEXT          DEFAULT NULL,
  `source_ip`    VARCHAR(50)   DEFAULT NULL,
  `created_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_status` (`status`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `media` (
  `id`           BIGINT        NOT NULL AUTO_INCREMENT,
  `name`         VARCHAR(255)  NOT NULL,
  `type`         ENUM('image','video','audio','model','document','other')
                               NOT NULL DEFAULT 'image',
  `url`          VARCHAR(1000) NOT NULL,
  `thumb_url`    VARCHAR(1000) DEFAULT NULL,
  `size_bytes`   BIGINT        DEFAULT NULL,
  `mime_type`    VARCHAR(100)  DEFAULT NULL,
  `width`        INT           DEFAULT NULL,
  `height`       INT           DEFAULT NULL,
  `duration`     FLOAT         DEFAULT NULL,
  `tags`         VARCHAR(500)  DEFAULT NULL,
  `alt_text`     VARCHAR(300)  DEFAULT NULL,
  `uploaded_by`  VARCHAR(50)   DEFAULT NULL,
  `storage`      ENUM('local','oss','cos','r2','s3','url') DEFAULT 'url',
  `storage_key`  VARCHAR(500)  DEFAULT NULL,
  `created_at`   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_type` (`type`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `activity_log` (
  `id`         BIGINT       NOT NULL AUTO_INCREMENT,
  `user`       VARCHAR(50)  DEFAULT NULL,
  `action`     VARCHAR(200) NOT NULL,
  `detail`     TEXT         DEFAULT NULL,
  `ip`         VARCHAR(50)  DEFAULT NULL,
  `user_agent` VARCHAR(500) DEFAULT NULL,
  `created_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_user`    (`user`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `token_blacklist` (
  `jti`        VARCHAR(100) NOT NULL,
  `expires_at` DATETIME     NOT NULL,
  PRIMARY KEY (`jti`),
  KEY `idx_expires` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT IGNORE INTO `cms_data` (`key`, `value`, `updated_by`) VALUES
('site', '{"name":"兽可梦 ShowCome","tagline":"让每一只兽娘都独一无二","logo":"🦊","icp":"","online":true,"shopEnabled":true,"customEnabled":true}', 'system'),
('theme', '{"primary":"#0a0a0f","secondary":"#111118","accent":"#7c3aed","accent2":"#06d6a0","accent3":"#f72585","text":"#e8e8f0","noiseEnabled":true,"glowEnabled":true}', 'system'),
('seo', '{"title":"兽可梦 ShowCome | 专业兽装定制工作室","description":"专业毛绒兽装定制工作室，提供头装、全身套装、局部配件定制服务","keywords":"兽装定制,毛绒服装,兽化,fursuit,兽装工作室","ogImage":""}', 'system');
