/// 数据库迁移。每个版本一个 SQL 列表，按序号递增执行。
///
/// 约定：时间戳存 ISO8601 文本；id 为 UUID 文本；布尔存 0/1；
/// `hlc` 字段在 M1 留空，M4 起写入混合逻辑时钟。
library;

import 'sync_v2_migration.dart';
import 'sync_checkpoint_migration.dart';

/// v1：便签、事项、标签、提醒、留痕。对应产品设计 V2.2 第 9 章。
const List<String> _v1 = [
  '''
  CREATE TABLE notes (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('text','meeting')),
    title TEXT,
    raw_content TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL CHECK (status IN ('active','closed')),
    color TEXT,
    pinned INTEGER NOT NULL DEFAULT 0,
    window_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    closed_at TEXT,
    deleted_at TEXT,
    hlc TEXT
  )''',
  '''
  CREATE TABLE items (
    id TEXT PRIMARY KEY,
    note_id TEXT REFERENCES notes(id),
    line_index INTEGER,
    title TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('todo','done','canceled')),
    priority TEXT NOT NULL DEFAULT 'p4'
      CHECK (priority IN ('p0','p1','p2','p3','p4')),
    source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','ai')),
    due_at TEXT,
    completed_at TEXT,
    source_ref_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    hlc TEXT
  )''',
  '''
  CREATE TABLE tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('project','type','custom')),
    builtin INTEGER NOT NULL DEFAULT 0,
    color TEXT,
    sort INTEGER NOT NULL DEFAULT 0
  )''',
  'CREATE UNIQUE INDEX idx_tags_kind_name ON tags(kind, name)',
  '''
  CREATE TABLE item_tags (
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (item_id, tag_id)
  )''',
  '''
  CREATE TABLE reminders (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    mode TEXT NOT NULL
      CHECK (mode IN ('exact','relative','smart','overdue','digest')),
    trigger_at TEXT,
    offset_minutes INTEGER,
    is_strong INTEGER NOT NULL DEFAULT 0,
    snooze_count INTEGER NOT NULL DEFAULT 0,
    last_fired_at TEXT,
    feedback TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    hlc TEXT
  )''',
  '''
  CREATE TABLE activities (
    id TEXT PRIMARY KEY,
    object_type TEXT NOT NULL,
    object_id TEXT NOT NULL,
    action TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    created_at TEXT NOT NULL
  )''',
  'CREATE INDEX idx_items_note ON items(note_id)',
  'CREATE INDEX idx_items_due ON items(due_at)',
  'CREATE INDEX idx_items_status ON items(status)',
  'CREATE INDEX idx_notes_status ON notes(status)',
  'CREATE INDEX idx_reminders_trigger ON reminders(trigger_at)',
  'CREATE INDEX idx_activities_object ON activities(object_type, object_id)',
];

/// v2：全文搜索。用 FTS5 trigram 分词以支持中文子串检索。
const List<String> _v2 = [
  '''
  CREATE VIRTUAL TABLE search_index USING fts5(
    object_type UNINDEXED,
    object_id UNINDEXED,
    text,
    tokenize = 'trigram'
  )''',
];

/// v3：附件（图片）。原文件仅本机，同步策略见同步方案。
const List<String> _v3 = [
  '''
  CREATE TABLE attachments (
    id TEXT PRIMARY KEY,
    note_id TEXT REFERENCES notes(id) ON DELETE CASCADE,
    item_id TEXT REFERENCES items(id) ON DELETE CASCADE,
    media TEXT NOT NULL DEFAULT 'image',
    file_name TEXT,
    mime TEXT,
    byte_size INTEGER NOT NULL DEFAULT 0,
    sha256 TEXT,
    sync TEXT NOT NULL DEFAULT 'local_only'
      CHECK (sync IN ('local_only','trusted_devices','wifi_only')),
    created_at TEXT NOT NULL,
    deleted_at TEXT,
    hlc TEXT
  )''',
  'CREATE INDEX idx_attachments_note ON attachments(note_id)',
];

/// v4：同步。设备成员、每台设备的操作日志水位、私密配置。M4 启用。
const List<String> _v4 = [
  '''
  CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    exchange_public_key TEXT NOT NULL,
    syncthing_device_id TEXT,
    is_self INTEGER NOT NULL DEFAULT 0,
    revoked_at TEXT,
    added_at TEXT NOT NULL
  )''',
  '''
  CREATE TABLE sync_state (
    device_id TEXT PRIMARY KEY,
    applied_seq INTEGER NOT NULL DEFAULT 0,
    last_synced_at TEXT
  )''',
  '''
  CREATE TABLE secrets (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('aiApiKey','providerAuth')),
    provider TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    hlc TEXT
  )''',
];

// 本机平台通知状态不随事项删除，确保重启后仍能撤销旧通知。
const List<String> _v5 = [
  '''
  CREATE TABLE notification_plans (
    notification_id INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_key TEXT NOT NULL UNIQUE,
    item_id TEXT NOT NULL,
    fire_at TEXT NOT NULL,
    state TEXT NOT NULL
      CHECK (state IN ('pending','scheduled','cancel_pending','retired'))
  )''',
  'CREATE INDEX idx_notification_plans_state ON notification_plans(state)',
];

/// v6：本机同步状态与持久操作；私钥/Epoch密钥仍只存系统安全存储。
const List<String> _v6 = [
  '''
  CREATE TABLE sync_local (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    device_id TEXT,
    enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0,1)),
    hlc_millis INTEGER NOT NULL DEFAULT 0 CHECK (hlc_millis >= 0),
    hlc_counter INTEGER NOT NULL DEFAULT 0 CHECK (hlc_counter >= 0),
    requires_new_identity INTEGER NOT NULL DEFAULT 0
      CHECK (requires_new_identity IN (0,1)),
    CHECK (enabled = 0 OR (device_id IS NOT NULL AND device_id <> '')),
    CHECK (requires_new_identity = 0 OR enabled = 0)
  )''',
  'INSERT INTO sync_local(id) VALUES (1)',
  '''
  CREATE TABLE sync_operations (
    op_id TEXT PRIMARY KEY NOT NULL,
    device_id TEXT NOT NULL,
    hlc_millis INTEGER NOT NULL CHECK (hlc_millis >= 0),
    hlc_counter INTEGER NOT NULL CHECK (hlc_counter >= 0),
    object_type TEXT NOT NULL CHECK (object_type IN ('note','item','tag','item_tag')),
    object_id TEXT NOT NULL,
    field TEXT NOT NULL,
    value_json TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('local','remote')),
    publication_seq INTEGER,
    UNIQUE (device_id,hlc_millis,hlc_counter)
  )''',
  'CREATE INDEX idx_sync_pending ON sync_operations(source,publication_seq,hlc_millis,hlc_counter)',
  'CREATE INDEX idx_sync_field ON sync_operations(object_type,object_id,field,hlc_millis DESC,hlc_counter DESC,device_id DESC)',
  '''
  CREATE TABLE sync_publications (
    seq INTEGER PRIMARY KEY CHECK (seq > 0),
    file_name TEXT NOT NULL UNIQUE,
    key_epoch INTEGER NOT NULL CHECK (key_epoch > 0),
    segment_bytes BLOB NOT NULL,
    sealed INTEGER NOT NULL CHECK (sealed IN (0,1)),
    published INTEGER NOT NULL DEFAULT 0 CHECK (published IN (0,1))
  )''',
];

/// 版本号 → 该版本要执行的语句。
const Map<int, List<String>> migrations = {
  1: _v1,
  2: _v2,
  3: _v3,
  4: _v4,
  5: _v5,
  6: _v6,
  7: [], // 日期数据迁移由migrateUtcTimes在同一事务执行。
  8: ['ALTER TABLE tags ADD COLUMN logical_name TEXT'], // 本机派生显示名的原业务名。
  9: [
    'ALTER TABLE sync_local ADD COLUMN pending_count INTEGER NOT NULL DEFAULT 0 CHECK (pending_count>=0)',
    '''CREATE TABLE sync_received_segments (
      device_id TEXT NOT NULL,
      seq INTEGER NOT NULL CHECK (seq>0),
      key_epoch INTEGER NOT NULL CHECK (key_epoch>0),
      created_at TEXT NOT NULL,
      op_count INTEGER NOT NULL CHECK (op_count BETWEEN 1 AND 500),
      sealed INTEGER NOT NULL CHECK (sealed IN (0,1)),
      segment_hash TEXT NOT NULL CHECK (length(segment_hash)=64),
      op_ids_json TEXT NOT NULL DEFAULT '[]',
      PRIMARY KEY(device_id,seq)
    )''',
  ],
  10: ['ALTER TABLE sync_local ADD COLUMN baseline_ready INTEGER NOT NULL DEFAULT 0 CHECK (baseline_ready IN (0,1))'],
  11: [], // 在迁移事务内复用SearchService回填本地全文索引。
  12: syncV2Migration,
  13: syncCheckpointMigration,
};

/// 当前目标 schema 版本。
const int latestSchemaVersion = 13;
