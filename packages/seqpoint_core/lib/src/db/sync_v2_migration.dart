/// Add media facts without rewriting existing operation identities or clocks.
const syncV2Migration = <String>[
  'ALTER TABLE sync_local ADD COLUMN media_enabled INTEGER NOT NULL DEFAULT 0 CHECK(media_enabled IN (0,1))',
  'ALTER TABLE attachments ADD COLUMN content_owner TEXT',
  'ALTER TABLE attachments ADD COLUMN manifest_hash TEXT',
  'ALTER TABLE sync_operations RENAME TO sync_operations_v11',
  '''CREATE TABLE sync_operations (
    op_id TEXT PRIMARY KEY NOT NULL,
    device_id TEXT NOT NULL,
    hlc_millis INTEGER NOT NULL CHECK(hlc_millis>=0),
    hlc_counter INTEGER NOT NULL CHECK(hlc_counter>=0),
    object_type TEXT NOT NULL CHECK(object_type IN ('note','item','tag','item_tag','attachment')),
    object_id TEXT NOT NULL,
    field TEXT NOT NULL,
    value_json TEXT NOT NULL,
    source TEXT NOT NULL CHECK(source IN ('local','remote')),
    publication_seq INTEGER,
    UNIQUE(device_id,hlc_millis,hlc_counter)
  )''',
  'INSERT INTO sync_operations SELECT * FROM sync_operations_v11',
  'DROP TABLE sync_operations_v11',
  'CREATE INDEX idx_sync_pending ON sync_operations(source,publication_seq,hlc_millis,hlc_counter)',
  'CREATE INDEX idx_sync_field ON sync_operations(object_type,object_id,field,hlc_millis DESC,hlc_counter DESC,device_id DESC)',
];
