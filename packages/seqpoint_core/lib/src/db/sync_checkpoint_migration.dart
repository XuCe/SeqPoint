const syncCheckpointMigration = <String>[
  '''CREATE TABLE sync_checkpoints (
    author TEXT PRIMARY KEY NOT NULL,
    covered_seq INTEGER NOT NULL CHECK(covered_seq>0),
    anchor TEXT NOT NULL CHECK(length(anchor)=64),
    writer TEXT NOT NULL,
    manifest_hash TEXT NOT NULL CHECK(length(manifest_hash)=64),
    manifest_bytes BLOB NOT NULL,
    key_epoch INTEGER NOT NULL CHECK(key_epoch>0),
    local_floor INTEGER NOT NULL DEFAULT 0 CHECK(local_floor>=0 AND local_floor<=covered_seq)
  )''',
  '''CREATE TABLE sync_checkpoint_staging (
    manifest_hash TEXT NOT NULL,
    op_id TEXT NOT NULL,
    publication_seq INTEGER NOT NULL CHECK(publication_seq>0),
    operation_json TEXT NOT NULL,
    PRIMARY KEY(manifest_hash,op_id)
  )''',
  'CREATE INDEX idx_sync_author ON sync_operations(device_id,publication_seq,object_type,object_id,field)',
];
