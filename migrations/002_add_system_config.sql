-- =============================================================================
--  Migration 002: 增加系统配置表
--  存储 OSS 配置等敏感运行时配置（不放 .env）
-- =============================================================================

CREATE TABLE IF NOT EXISTS `system_config` (
  `key`        VARCHAR(100)  NOT NULL COMMENT '配置键',
  `value`      TEXT          NOT NULL COMMENT '配置值（敏感字段加密存储）',
  `encrypted`  TINYINT(1)    NOT NULL DEFAULT 0 COMMENT '是否加密',
  `updated_at` DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                             ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='系统运行时配置';

CREATE TABLE IF NOT EXISTS `migrations_history` (
  `version`    VARCHAR(100)  NOT NULL COMMENT '迁移版本号',
  `name`       VARCHAR(255)  NOT NULL COMMENT '迁移文件名',
  `applied_at` DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='数据库迁移历史';
