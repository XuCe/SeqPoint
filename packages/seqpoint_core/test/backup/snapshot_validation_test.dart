import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  for (final schema in ['trigger', 'view']) {
    test('拒绝格式未定义的$schema，避免装配时执行外部逻辑', () {
      final dir = Directory.systemTemp.createTempSync('seqpoint-schema-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/source.db');
      final source = SeqDatabase.open(file.path)..migrate();
      source.raw.execute(schema == 'trigger'
        ? 'CREATE TRIGGER erase_notes AFTER INSERT ON tags '
          'BEGIN DELETE FROM notes; END'
        : 'CREATE VIEW extra_view AS SELECT * FROM notes');
      source.close();
      final before = file.readAsBytesSync();
      expect(() => SnapshotService.validate(file), throwsStateError);
      expect(file.readAsBytesSync(), before);
    });
  }

  for (final column in ['extension TEXT', "extension TEXT NOT NULL DEFAULT 'safe'"]) {
    test('允许不会阻止既有写入的额外列$column且源字节不变', () {
      final dir = Directory.systemTemp.createTempSync('seqpoint-column-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/source.db');
      final source = SeqDatabase.open(file.path)..migrate();
      source.raw.execute('ALTER TABLE notes ADD COLUMN $column');
      source.close();
      final before = file.readAsBytesSync();
      expect(SnapshotService.validate(file), latestSchemaVersion);
      expect(file.readAsBytesSync(), before);
    });
  }

  for (var version = 1; version <= latestSchemaVersion; version++) {
    test('支持v$version快照，校验不修改源文件，恢复副本可迁移', () async {
      final dir = Directory.systemTemp.createTempSync('seqpoint-legacy-');
      final owner = SeqDatabase.inMemory()..migrate();
      addTearDown(() { owner.close(); dir.deleteSync(recursive: true); });
      final file = File('${dir.path}/source.db');
      final source = SeqDatabase.open(file.path);
      for (var v = 1; v <= version; v++) {
        for (final sql in migrations[v]!) { source.raw.execute(sql); }
      }
      source.raw.execute('PRAGMA user_version = $version');
      source.close();
      final before = file.readAsBytesSync();
      expect(SnapshotService.validate(file), version);
      final target = '${dir.path}/restored.db';
      await SnapshotService(owner).restore(file, targetPath: target);
      final restored = SeqDatabase.open(target)..migrate();
      try {
        expect(restored.schemaVersion, latestSchemaVersion);
      } finally { restored.close(); }
      expect(file.readAsBytesSync(), before);
    });
  }

  for (final damage in ['table', 'column', 'future', 'corrupt',
      'plan_unique', 'tag_unique', 'extra_required', 'foreign_key',
      'partial_unique', 'extra_unique', 'null_required']) {
    test('恢复拒绝$damage快照且不覆盖现有文件', () async {
      final dir = Directory.systemTemp.createTempSync('seqpoint-validate-');
      final db = SeqDatabase.inMemory()..migrate();
      addTearDown(() { db.close(); dir.deleteSync(recursive: true); });
      final file = File('${dir.path}/candidate.db');
      final source = SeqDatabase.open(file.path)..migrate();
      if (damage == 'table') source.raw.execute('DROP TABLE notes');
      if (damage == 'column') {
        source.raw.execute('ALTER TABLE notes DROP COLUMN raw_content');
      }
      if (damage == 'future') {
        source.raw.execute('PRAGMA user_version = ${latestSchemaVersion + 1}');
      }
      if (damage == 'plan_unique' || damage == 'partial_unique') {
        final sql = source.raw.select('SELECT sql FROM sqlite_master WHERE name = ?',
            ['notification_plans']).single['sql'] as String;
        source.raw.execute('DROP TABLE notification_plans');
        source.raw.execute(sql.replaceFirst(' UNIQUE', ''));
        if (damage == 'partial_unique') {
          source.raw.execute('CREATE UNIQUE INDEX partial_plan '
              "ON notification_plans(plan_key) WHERE state = 'pending'");
        }
      }
      if (damage == 'tag_unique') source.raw.execute('DROP INDEX idx_tags_kind_name');
      if (damage == 'extra_required') {
        source.raw.execute('ALTER TABLE notes ADD COLUMN required_extension TEXT NOT NULL');
      }
      if (damage == 'null_required') {
        source.raw.execute('ALTER TABLE notes ADD COLUMN required_extension TEXT NOT NULL DEFAULT NULL');
      }
      if (damage == 'extra_unique') {
        source.raw.execute('CREATE UNIQUE INDEX extra_note ON notes(raw_content)');
      }
      if (damage == 'foreign_key') {
        final sql = source.raw.select('SELECT sql FROM sqlite_master WHERE name = ?',
            ['items']).single['sql'] as String;
        source.raw.execute('DROP TABLE items');
        final changed = sql.replaceFirst('REFERENCES notes(id)', '');
        expect(changed, isNot(sql));
        source.raw.execute(changed);
      }
      source.close();
      if (damage == 'corrupt') file.writeAsBytesSync([1, 2, 3]);
      final before = file.readAsBytesSync();
      final target = File('${dir.path}/current.db')..writeAsStringSync('protected');
      await expectLater(SnapshotService(db).restore(file,
        targetPath: target.path), throwsA(anything));
      expect(target.readAsStringSync(), 'protected');
      expect(file.readAsBytesSync(), before);
    });
  }
}
